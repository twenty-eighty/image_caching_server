defmodule ImageCachingServer.ImageCache do
  use GenServer, restart: :permanent
  require Logger
  alias ImageCachingServer.HashUtils

  @cache_dir System.get_env("CACHE_DIR", "priv/cache")

  # Read cache size at runtime, not compile time
  defp max_cache_size do
    String.to_integer(System.get_env("MAX_CACHE_SIZE_MB", "1024")) * 1024 * 1024
  end

  defp eviction_threshold do
    max_cache_size() * 0.9
  end
  # Increase timeout to 30 seconds for large image processing
  @genserver_timeout 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    Process.flag(:trap_exit, true)
    init_cache()
  end

  defp init_cache do
    # Ensure cache directory exists
    File.mkdir_p!(@cache_dir)
    Logger.info("Cache directory initialized at #{@cache_dir}")
    Logger.info("Max cache size: #{max_cache_size() / 1024 / 1024}MB, Eviction threshold: #{eviction_threshold() / 1024 / 1024}MB")

    # Initialize total size counter
    ConCache.put(:size_cache, :total_size, 0)

    # Calculate initial cache size
    rebuild_cache_state()

    {:ok, %{}}
  end


  def terminate(reason, _state) do
    Logger.warning("ImageCache terminating, reason: #{inspect(reason)}")
    :ok
  end

  defp rebuild_cache_state do
    Logger.info("Calculating cache size from #{@cache_dir}")

    # Reset total size
    ConCache.put(:size_cache, :total_size, 0)

    # Find all files in cache directory
    case File.ls(@cache_dir) do
      {:ok, files} ->
        Logger.info("Found #{length(files)} files in cache directory: #{inspect(files |> Enum.take(10))}")

        original_files = Enum.filter(files, &(!String.starts_with?(&1, "scaled_")))
        scaled_files = Enum.filter(files, &(String.starts_with?(&1, "scaled_")))

        Logger.info("Filtered: #{length(original_files)} original, #{length(scaled_files)} scaled")
        if length(original_files) > 0, do: Logger.info("Sample original files: #{inspect(Enum.take(original_files, 3))}")
        if length(scaled_files) > 0, do: Logger.info("Sample scaled files: #{inspect(Enum.take(scaled_files, 3))}")

        total_size = Enum.reduce(files, 0, fn file, acc ->
          path = Path.join(@cache_dir, file)
          case File.stat(path) do
            {:ok, %{size: size}} ->
              # Track individual file sizes
              ConCache.put(:size_cache, "size_#{file}", size)
              acc + size
            {:error, stat_reason} ->
              Logger.warning("Failed to stat file #{file}: #{inspect(stat_reason)}")
              acc
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

  @spec get_image(String.t(), pos_integer()) ::
    {:ok, String.t()} |
    {:error, String.t()} |
    {:error, {:http_error, integer(), String.t()}} |
    {:error, {:file_error, atom(), integer()}}
  def get_image(url, width) do
    case GenServer.call(__MODULE__, {:get_image, url, width}, @genserver_timeout) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} = error -> error
    end
  end

  def handle_call({:get_image, url, width}, _from, state) do
    # First run cache eviction if needed to make space upfront
    # We estimate the space needed for both original and scaled images
    estimated_space_needed = 2 * 1024 * 1024  # 2MB estimate per image
    current_size = ConCache.get(:size_cache, :total_size) || 0
    projected_size = current_size + estimated_space_needed

    if projected_size > eviction_threshold() do
      Logger.info("Preemptive cache eviction before processing image request")
      evict_lru_files(projected_size - eviction_threshold())
    end

    # Now check if we have the scaled version
    case find_scaled_image(url, width) do
      {:ok, scaled_path} ->
        {:reply, {:ok, scaled_path}, state}
      :not_found ->
        process_unscaled_image(url, width, state)
    end
  end

  # Find a scaled version of the image if it exists
  defp find_scaled_image(url, width) do
    scaled_key = "#{url}_#{width}"
    scaled_hash = HashUtils.hash_string(scaled_key)
    # Check for both WebP and GIF versions of scaled image
    scaled_webp = Path.join(@cache_dir, "scaled_#{scaled_hash}.webp")
    scaled_gif = Path.join(@cache_dir, "scaled_#{scaled_hash}.gif")

    cond do
      File.exists?(scaled_webp) ->
        Logger.info("Cache hit for scaled WebP image width=#{width}")
        {:ok, scaled_webp}
      File.exists?(scaled_gif) ->
        Logger.info("Cache hit for scaled GIF image width=#{width}")
        {:ok, scaled_gif}
      true ->
        :not_found
    end
  end

  # Process the request when no scaled image is found
  defp process_unscaled_image(url, width, state) do
    # No scaled version, check/get original
    case get_or_download_image(url) do
      {:ok, original_path} ->
        handle_original_image(original_path, width, state)
      # Pass through all error types, including HTTP errors
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  # Handle the original image for scaling or direct use
  defp handle_original_image(original_path, width, state) do
    # Get original image dimensions
    case get_image_dimensions(original_path) do
      {:ok, original_width, _height} ->
        if width > original_width do
          Logger.info("Requested width #{width} exceeds original width #{original_width}, using original")
          {:reply, {:ok, original_path}, state}
        else
          scale_image_for_response(original_path, width, state)
        end
      {:error, reason} ->
        {:reply, {:error, "Failed to get image dimensions: #{reason}"}, state}
    end
  end

  # Scale the image and prepare the response
  defp scale_image_for_response(original_path, width, state) do
    # Determine output path based on whether input is GIF
    image = Mogrify.open(original_path)
    is_gif = String.downcase(image.format || "") == "gif"

    # Generate appropriate scaled path
    scaled_key = "#{HashUtils.extract_hash_from_path(original_path)}_#{width}"
    scaled_hash = HashUtils.hash_string(scaled_key)
    scaled_path = if is_gif do
      Path.join(@cache_dir, "scaled_#{scaled_hash}.gif")
    else
      Path.join(@cache_dir, "scaled_#{scaled_hash}.webp")
    end

    case scale_image(original_path, scaled_path, width) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp get_or_download_image(url) do
    hash = HashUtils.hash_string(url)
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

    # Validate and parse URL
    with {:ok, valid_url} <- validate_url(url),
         {:ok, result} <- download_and_process_image(valid_url, temp_path, hash) do
      # Unwrap the actual result
      result
    else
      {:error, validation_reason} when is_binary(validation_reason) ->
        Logger.error("Invalid URL: #{inspect(validation_reason)}")
        {:error, validation_reason}
    end
  end

  # Download the image and process it if successful
  defp download_and_process_image(url, temp_path, hash) do
    case ImageCachingServer.DownloadUtils.download_image_v2(url) do
      {:ok, image_data, client} when is_binary(image_data) ->
        Logger.info("Downloaded image (#{byte_size(image_data)} bytes) using #{client} client")
        process_downloaded_image(image_data, temp_path, hash)

      # Use a single pattern to handle all error types
      {:error, _reason} = error ->
        cleanup_and_handle_error(error, temp_path)
    end
  end

  # Process an image that was successfully downloaded
  defp process_downloaded_image(image_data, temp_path, hash) do
    # Save the image to cache (eviction already done upfront)
    case save_image_to_cache(image_data, temp_path, hash) do
      {:ok, final_path} ->
        Logger.info("Successfully saved image to #{final_path}")
        {:ok, {:ok, final_path}}
      {:error, save_reason} ->
        File.rm(temp_path)
        Logger.error("Failed to save image: #{inspect(save_reason)}")
        {:ok, {:error, save_reason}}
    end
  end

  # Clean up and handle download errors
  defp cleanup_and_handle_error({:error, {:http_error, status, description}} = error, temp_path) do
    # Clean up temporary file if it exists
    File.rm(temp_path)
    Logger.error("Failed to download image: HTTP error #{status}: #{description}")
    {:ok, error}
  end

  defp cleanup_and_handle_error({:error, {:file_error, :too_small, size}} = error, temp_path) do
    # Clean up temporary file if it exists
    File.rm(temp_path)
    Logger.error("Failed to download image: file too small (#{size} bytes)")
    {:ok, error}
  end

  defp cleanup_and_handle_error({:error, download_reason} = error, temp_path) do
    # Clean up temporary file if it exists
    File.rm(temp_path)
    Logger.error("Failed to download image: #{inspect(download_reason)}")
    {:ok, error}
  end

    defp save_image_to_cache(image_data, temp_path, hash) do
    # First save to temporary file
    with :ok <- File.write(temp_path, image_data),
         {:ok, format} <- get_image_format(temp_path) do

      final_path = Path.join(@cache_dir, "#{hash}.#{format}")

      case File.rename(temp_path, final_path) do
        :ok ->
          # Track file size in cache
          update_cache_size_tracking(final_path)
          {:ok, final_path}

        {:error, reason} ->
          Logger.error("Failed to rename temporary file: #{inspect(reason)}")
          {:error, "Failed to rename temporary file: #{inspect(reason)}"}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to save or process image: #{inspect(reason)}")
        {:error, "Failed to save or process image: #{inspect(reason)}"}
    end
  end

  defp update_cache_size_tracking(file_path) do
    {:ok, %{size: size}} = File.stat(file_path)
    ConCache.put(:size_cache, "size_#{Path.basename(file_path)}", size)
    current_size = ConCache.get(:size_cache, :total_size) || 0
    ConCache.put(:size_cache, :total_size, current_size + size)

    Logger.info("Successfully cached image at #{file_path} (#{size / 1024 / 1024}MB)")
  end

  @spec validate_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp validate_url(url) when is_binary(url) and byte_size(url) > 0 do
    # Trim any whitespace from the URL first
    trimmed_url = String.trim(url)

    # Check if this is a URL to our own server and extract the original URL if it is
    case extract_url_from_own_server(trimmed_url) do
      {:own_server, nested_url} ->
        # Recursively validate the extracted URL
        validate_url(nested_url)

      :not_own_server ->
        # Continue with regular URL validation
        uri = URI.parse(trimmed_url)

        case uri do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
            # Ensure the URL is properly encoded
            encoded_url = trimmed_url
            |> String.replace(" ", "%20")
            |> URI.parse()
            |> URI.to_string()

            {:ok, encoded_url}

          %URI{scheme: nil} ->
            {:error, "Missing URL scheme (http/https)"}

          %URI{host: nil} ->
            {:error, "Missing host in URL"}

          %URI{scheme: scheme} when scheme not in ["http", "https"] ->
            {:error, "Invalid URL scheme: #{scheme}"}

          _ ->
            {:error, "Invalid URL format"}
        end
    end
  end

  defp validate_url("") do
    {:error, "Empty URL"}
  end

  defp validate_url(_) do
    {:error, "Invalid URL type"}
  end

  # Extract nested URL if the URL is from our own domain
  defp extract_url_from_own_server(url) do
    own_domains = [
      System.get_env("PHX_HOST", "image-caching-server.onrender.com"),
      "localhost",
      "127.0.0.1"
    ]

    uri = URI.parse(url)

    # Check if URI host matches any of our own domains
    if uri.host != nil && uri.scheme in ["http", "https"] && Enum.member?(own_domains, uri.host) do
      Logger.info("Detected URL to our own server: #{url}")

      # Extract the original url from the query parameters
      query_params = URI.decode_query(uri.query || "")
      case Map.get(query_params, "url") do
        nil ->
          Logger.warning("URL to our own server doesn't contain a url parameter: #{url}")
          # Just continue processing the original URL
          :not_own_server
        nested_url ->
          Logger.info("Extracted nested URL: #{nested_url}")
          {:own_server, nested_url}
      end
    else
      :not_own_server
    end
  end

  defp get_image_format(path) do
    try do
      # First try with Mogrify identify
      case Mogrify.identify(path) do
        %{format: format} when is_binary(format) and format != "" ->
          {:ok, String.downcase(format)}
        _ ->
          # Fallback to using file command if format is nil or empty
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
      # Determine file format and adjust output path
      {image, output_path} = prepare_image_for_scaling(input_path, output_path)

      # Perform the actual scaling
      scaled_image = perform_image_scaling(image, width)

      # Save the scaled image
      save_scaled_image(scaled_image, output_path)
    rescue
      e ->
        Logger.error("Error scaling image: #{inspect(e)}")
        {:error, "Error scaling image: #{inspect(e)}"}
    end
  end



  # Prepare the image and output path for scaling
  defp prepare_image_for_scaling(input_path, output_path) do
    image = Mogrify.open(input_path)
    is_gif = String.downcase(image.format || "") == "gif"

    # If GIF, ensure output path has .gif extension, otherwise use WebP
    adjusted_output_path = if is_gif do
      String.replace(output_path, ~r/\.webp$/, ".gif")
    else
      String.replace(output_path, ~r/\.[^.]+$/, ".webp")
    end

    {image, adjusted_output_path}
  end

  # Perform the actual image scaling
  defp perform_image_scaling(image, width) do
    is_gif = String.downcase(image.format || "") == "gif"

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
  end

  # Save the scaled image and update size tracking
  defp save_scaled_image(image, output_path) do
    Mogrify.save(image, path: output_path)

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

  # Handle normal port exits from ImageMagick operations
  def handle_info({:EXIT, port, :normal}, state) when is_port(port) do
    {:noreply, state}
  end

  # Catch-all handler for unexpected messages
  def handle_info(msg, state) do
    Logger.warning("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

end
