defmodule ImageCachingServer.ImageCache do
  use GenServer
  require Logger

  @cache_dir System.get_env("CACHE_DIR", "priv/cache")
  @cache_name :image_cache
  @max_cache_size String.to_integer(System.get_env("MAX_CACHE_SIZE_MB", "1024")) * 1024 * 1024
  @eviction_threshold @max_cache_size * 0.9
  # Increase timeout to 30 seconds for large image processing
  @genserver_timeout 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    # Ensure cache directory exists
    File.mkdir_p!(@cache_dir)
    Logger.info("Cache directory initialized at #{@cache_dir}")
    Logger.info("Max cache size: #{@max_cache_size / 1024 / 1024}MB, Eviction threshold: #{@eviction_threshold / 1024 / 1024}MB")

    # Start ConCache with TTL of 1 hour
    {:ok, _pid} = ConCache.start_link(
      name: @cache_name,
      ttl_check_interval: :timer.minutes(1),
      global_ttl: :timer.hours(1),
      touch_on_read: true
    )

    # Start size tracking cache (no TTL)
    {:ok, _pid} = ConCache.start_link(
      name: :size_cache,
      ttl_check_interval: false
    )

    # Initialize total size counter
    ConCache.put(:size_cache, :total_size, 0)

    # Calculate initial cache size
    rebuild_cache_state()

    {:ok, %{}}
  end

  defp rebuild_cache_state do
    Logger.info("Calculating cache size from #{@cache_dir}")

    # Reset total size
    ConCache.put(:size_cache, :total_size, 0)

    # Find all files in cache directory
    case File.ls(@cache_dir) do
      {:ok, files} ->
        original_files = Enum.filter(files, &(!String.starts_with?(&1, "scaled_")))
        scaled_files = Enum.filter(files, &(String.starts_with?(&1, "scaled_")))

        total_size = Enum.reduce(files, 0, fn file, acc ->
          path = Path.join(@cache_dir, file)
          case File.stat(path) do
            {:ok, %{size: size}} ->
              # Track individual file sizes
              ConCache.put(:size_cache, "size_#{file}", size)
              acc + size
            _ -> acc
          end
        end)

        # Update total size
        ConCache.put(:size_cache, :total_size, total_size)

        Logger.info("Cache contains #{length(original_files)} original and #{length(scaled_files)} scaled images")
        Logger.info("Total cache size: #{total_size / 1024 / 1024}MB")

      {:error, reason} ->
        Logger.error("Failed to read cache directory: #{inspect(reason)}")
    end
  end

  defp ensure_cache_size(new_file_size) do
    current_size = ConCache.get(:size_cache, :total_size) || 0
    projected_size = current_size + new_file_size

    if projected_size > @eviction_threshold do
      Logger.info("Cache size (#{projected_size / 1024 / 1024}MB) would exceed threshold, running LRU eviction")
      evict_lru_files(projected_size - @eviction_threshold)
    end
  end

  defp evict_lru_files(size_to_free) do
    # Get all files with their last access times
    case File.ls(@cache_dir) do
      {:ok, files} ->
        files
        |> Enum.map(fn file ->
          path = Path.join(@cache_dir, file)
          case File.stat(path) do
            {:ok, %{atime: atime, size: size}} -> {file, path, atime, size}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, atime, _} -> atime end)  # Sort by access time (oldest first)
        |> evict_files(size_to_free)

      {:error, reason} ->
        Logger.error("Failed to list cache directory for eviction: #{inspect(reason)}")
    end
  end

  defp evict_files([], _), do: :ok
  defp evict_files(_, size_to_free) when size_to_free <= 0, do: :ok
  defp evict_files([{file, path, _atime, size} | rest], size_to_free) do
    Logger.info("Evicting #{file} (#{size / 1024 / 1024}MB) from cache")

    # Remove file and update size tracking
    File.rm(path)
    ConCache.delete(:size_cache, "size_#{file}")
    current_size = ConCache.get(:size_cache, :total_size) || 0
    ConCache.put(:size_cache, :total_size, current_size - size)

    evict_files(rest, size_to_free - size)
  end

  def get_image(url, width) do
    case GenServer.call(__MODULE__, {:get_image, url, width}, @genserver_timeout) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_call({:get_image, url, width}, _from, state) do
    # First check if we have the scaled version
    scaled_key = "#{url}_#{width}"
    scaled_hash = :crypto.hash(:md5, scaled_key) |> Base.encode16()
    # Check for both WebP and GIF versions of scaled image
    scaled_webp = Path.join(@cache_dir, "scaled_#{scaled_hash}.webp")
    scaled_gif = Path.join(@cache_dir, "scaled_#{scaled_hash}.gif")

    cond do
      File.exists?(scaled_webp) ->
        Logger.info("Cache hit for scaled WebP image width=#{width}")
        {:reply, {:ok, scaled_webp}, state}
      File.exists?(scaled_gif) ->
        Logger.info("Cache hit for scaled GIF image width=#{width}")
        {:reply, {:ok, scaled_gif}, state}
      true ->
        # No scaled version, check/get original
        case get_or_download_image(url) do
          {:ok, original_path} ->
            # Get original image dimensions
            case get_image_dimensions(original_path) do
              {:ok, original_width, _height} ->
                if width > original_width do
                  Logger.info("Requested width #{width} exceeds original width #{original_width}, using original")
                  {:reply, {:ok, original_path}, state}
                else
                  # Determine output path based on whether input is GIF
                  image = Mogrify.open(original_path)
                  is_gif = String.downcase(image.format || "") == "gif"
                  scaled_path = if is_gif, do: scaled_gif, else: scaled_webp

                  case scale_image(original_path, scaled_path, width) do
                    {:ok, path} -> {:reply, {:ok, path}, state}
                    {:error, reason} -> {:reply, {:error, reason}, state}
                  end
                end
              {:error, reason} ->
                {:reply, {:error, "Failed to get image dimensions: #{reason}"}, state}
            end
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp get_or_download_image(url) do
    hash = :crypto.hash(:md5, url) |> Base.encode16()
    # We'll determine the extension after downloading for new files
    temp_path = Path.join(@cache_dir, "#{hash}.tmp")

    # Try to find existing file with any extension
    case find_original_file(hash) do
      {:ok, path} ->
        Logger.info("Cache hit for original image")
        {:ok, path}
      :not_found ->
        Logger.info("Cache miss for #{url}")
        download_image(url, temp_path, hash)
    end
  end

  defp find_original_file(hash) do
    # Check for any existing file with this hash (regardless of extension)
    case File.ls(@cache_dir) do
      {:ok, files} ->
        case Enum.find(files, fn file ->
          String.starts_with?(file, hash) and not String.starts_with?(file, "scaled_")
        end) do
          nil -> :not_found
          file -> {:ok, Path.join(@cache_dir, file)}
        end
      _ -> :not_found
    end
  end

  defp download_image(url, temp_path, hash) do
    Logger.info("Downloading image from #{url}")
    case HTTPoison.get(url, [], [follow_redirect: true]) do
      {:ok, %{status_code: 200, body: image_data}} ->
        ensure_cache_size(byte_size(image_data))

        # First save to temporary file
        case File.write(temp_path, image_data) do
          :ok ->
            # Get the original format and save with correct extension
            case get_image_format(temp_path) do
              {:ok, format} ->
                final_path = Path.join(@cache_dir, "#{hash}.#{format}")
                case File.rename(temp_path, final_path) do
                  :ok ->
                    # Track file size
                    {:ok, %{size: size}} = File.stat(final_path)
                    ConCache.put(:size_cache, "size_#{Path.basename(final_path)}", size)
                    current_size = ConCache.get(:size_cache, :total_size) || 0
                    ConCache.put(:size_cache, :total_size, current_size + size)

                    Logger.info("Successfully downloaded and cached image at #{final_path} (#{size / 1024 / 1024}MB)")
                    {:ok, final_path}
                  {:error, reason} ->
                    File.rm(temp_path)
                    Logger.error("Failed to rename temporary file: #{inspect(reason)}")
                    {:error, "Failed to rename temporary file: #{inspect(reason)}"}
                end
              {:error, reason} ->
                File.rm(temp_path)
                Logger.error("Failed to determine image format: #{inspect(reason)}")
                {:error, "Failed to determine image format: #{inspect(reason)}"}
            end
          {:error, reason} ->
            Logger.error("Failed to save temporary image: #{inspect(reason)}")
            {:error, "Failed to save temporary image: #{inspect(reason)}"}
        end

      {:ok, %{status_code: status_code}} ->
        Logger.error("Failed to download image, status code: #{status_code}")
        {:error, "Failed to download image, status code: #{status_code}"}

      {:error, %{reason: reason}} ->
        Logger.error("Failed to download image: #{inspect(reason)}")
        {:error, "Failed to download image: #{inspect(reason)}"}
    end
  end

  defp get_image_format(path) do
    try do
      # First try with Mogrify
      case Mogrify.open(path) do
        %{format: format} when is_binary(format) and format != "" ->
          {:ok, String.downcase(format)}
        _ ->
          # Fallback to using file command
          case System.cmd("file", ["--mime-type", "-b", path]) do
            {mime, 0} ->
              format = case String.trim(mime) do
                "image/jpeg" -> "jpg"
                "image/png" -> "png"
                "image/gif" -> "gif"
                "image/webp" -> "webp"
                mime ->
                  Logger.warning("Unexpected MIME type: #{mime}, defaulting to jpg")
                  "jpg"
              end
              {:ok, format}
            {error, _} ->
              Logger.error("Failed to determine format using file command: #{error}")
              {:error, "Could not determine format"}
          end
      end
    rescue
      e ->
        Logger.error("Error in get_image_format: #{inspect(e)}")
        {:error, "Failed to determine image format: #{inspect(e)}"}
    end
  end

  defp scale_image(input_path, output_path, width) do
    Logger.info("Scaling image #{input_path} to width #{width}")
    try do
      # Get original file size to estimate scaled size
      {:ok, %{size: original_size}} = File.stat(input_path)
      # Estimate scaled size (conservative estimate)
      estimated_size = original_size
      ensure_cache_size(estimated_size)

      # Determine if input is GIF
      image = Mogrify.open(input_path)
      is_gif = String.downcase(image.format || "") == "gif"

      # If GIF, ensure output path has .gif extension, otherwise use WebP
      output_path = if is_gif do
        String.replace(output_path, ~r/\.webp$/, ".gif")
      else
        String.replace(output_path, ~r/\.[^.]+$/, ".webp")
      end

      image
      |> Mogrify.resize("#{width}x")
      |> Mogrify.format(if(is_gif, do: "gif", else: "webp"))
      # Add WebP optimization options for non-GIFs using ImageMagick parameters
      |> then(fn img ->
        if is_gif do
          img
        else
          img
          |> Mogrify.quality("85")
          |> Mogrify.custom("define", "webp:lossless=false")
          |> Mogrify.custom("define", "webp:auto-filter=true")
        end
      end)
      |> Mogrify.save(path: output_path)

      if File.exists?(output_path) do
        # Track file size
        {:ok, %{size: actual_size}} = File.stat(output_path)
        ConCache.put(:size_cache, "size_scaled_#{Path.basename(output_path)}", actual_size)
        current_size = ConCache.get(:size_cache, :total_size) || 0
        ConCache.put(:size_cache, :total_size, current_size + actual_size)

        Logger.info("Successfully scaled and cached image at #{output_path} (#{actual_size / 1024 / 1024}MB)")
        {:ok, output_path}
      else
        {:error, "Failed to save scaled image"}
      end
    rescue
      e ->
        Logger.error("Error scaling image: #{inspect(e)}")
        {:error, "Error scaling image: #{inspect(e)}"}
    end
  end

  defp get_image_dimensions(path) do
    try do
      image = Mogrify.open(path)
      {:ok, image.width, image.height}
    rescue
      e ->
        Logger.error("Error getting image dimensions: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end
end
