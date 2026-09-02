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

  defp max_concurrent_ops do
    env_int("MAX_CONCURRENT_IMAGE_OPS", 1)
  end

  defp max_image_width, do: env_int("MAX_IMAGE_WIDTH", 8192)
  defp max_image_height, do: env_int("MAX_IMAGE_HEIGHT", 8192)
  defp max_image_pixels, do: env_int("MAX_IMAGE_PIXELS", 16_777_216)
  defp convert_timeout_sec, do: env_int("CONVERT_TIMEOUT_SEC", 15)
  defp identify_timeout_sec, do: env_int("IDENTIFY_TIMEOUT_SEC", 5)

  defp magick_memory_limit, do: System.get_env("MAGICK_MEMORY_LIMIT", "64MB")
  defp magick_map_limit, do: System.get_env("MAGICK_MAP_LIMIT", "64MB")
  defp magick_area_limit, do: System.get_env("MAGICK_AREA_LIMIT", "16MP")
  defp magick_disk_limit, do: System.get_env("MAGICK_DISK_LIMIT", "256MB")

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  @genserver_timeout 60_000

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
    Logger.info(
      "Image decode limits: #{max_image_width()}x#{max_image_height()} / #{max_image_pixels()}px, " <>
        "convert timeout #{convert_timeout_sec()}s, concurrent ops #{max_concurrent_ops()}, " <>
        "magick memory=#{magick_memory_limit()} area=#{magick_area_limit()}"
    )

    # Initialize total size counter
    ConCache.put(:size_cache, :total_size, 0)

    # Calculate initial cache size
    rebuild_cache_state()

    {:ok, %{in_flight: %{}, active_count: 0, pending: []}}
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

  def handle_call({:get_image, url, width}, from, state) do
    case find_scaled_image(url, width) do
      {:ok, scaled_path} ->
        {:reply, {:ok, scaled_path}, state}

      :not_found ->
        key = {url, width}

        case Map.get(state.in_flight, key) do
          %{waiters: waiters} ->
            updated =
              put_in(state.in_flight, [key, :waiters], [from | waiters])

            {:noreply, %{state | in_flight: updated}}

          nil ->
            enqueue_or_start(key, url, width, from, state)
        end
    end
  end

  defp enqueue_or_start(key, url, width, from, state) do
    if state.active_count >= max_concurrent_ops() do
      {:noreply, %{state | pending: state.pending ++ [{key, url, width, from}]}}
    else
      start_async_processing(key, url, width, from, state)
    end
  end

  defp start_async_processing(key, url, width, from, state) do
    task =
      Task.Supervisor.async_nolink(ImageCachingServer.ImageTaskSupervisor, fn ->
        do_process_image(url, width)
      end)

    monitor_ref = Process.monitor(task.pid)

    in_flight_entry = %{
      task_ref: task.ref,
      monitor_ref: monitor_ref,
      waiters: [from]
    }

    {:noreply,
     %{
       state
       | in_flight: Map.put(state.in_flight, key, in_flight_entry),
         active_count: state.active_count + 1
     }}
  end

  defp do_process_image(url, width) do
    estimated_space_needed = 2 * 1024 * 1024
    current_size = ConCache.get(:size_cache, :total_size) || 0
    projected_size = current_size + estimated_space_needed

    if projected_size > eviction_threshold() do
      Logger.info("Preemptive cache eviction before processing image request")
      evict_lru_files(projected_size - eviction_threshold())
    end

    case get_or_download_image(url) do
      {:ok, original_path} ->
        process_original_image(original_path, width, url)

      {:error, _reason} = error ->
        error
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case find_in_flight_by_task_ref(state, ref) do
      {key, %{waiters: waiters, monitor_ref: monitor_ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        reply_to_waiters(waiters, result)
        {:noreply, complete_processing(state, key)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _monitor_ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case find_in_flight_by_monitor_ref(state, monitor_ref) do
      {key, %{waiters: waiters}} ->
        reply_to_waiters(waiters, {:error, "Image processing crashed: #{inspect(reason)}"})
        {:noreply, complete_processing(state, key)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, :normal}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp reply_to_waiters(waiters, result) do
    Enum.each(waiters, &GenServer.reply(&1, result))
  end

  defp complete_processing(state, key) do
    state
    |> Map.update!(:in_flight, &Map.delete(&1, key))
    |> Map.update!(:active_count, &max(&1 - 1, 0))
    |> start_next_pending()
  end

  defp start_next_pending(%{pending: []} = state), do: state

  defp start_next_pending(%{pending: [{key, url, width, from} | rest]} = state) do
    if state.active_count >= max_concurrent_ops() do
      %{state | pending: [{key, url, width, from} | rest]}
    else
      {:noreply, new_state} = start_async_processing(key, url, width, from, %{state | pending: rest})
      new_state
    end
  end

  defp find_in_flight_by_task_ref(state, ref) do
    Enum.find(state.in_flight, fn {_key, entry} -> entry.task_ref == ref end)
  end

  defp find_in_flight_by_monitor_ref(state, ref) do
    Enum.find(state.in_flight, fn {_key, entry} -> entry.monitor_ref == ref end)
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

  # Process the original image for scaling or direct use
  defp process_original_image(original_path, width, url) do
    case identify_image(original_path) do
      {:ok, info} ->
        cond do
          gif?(info.format) ->
            Logger.info("Skipping scale for GIF, serving original to preserve animation")
            {:ok, original_path}

          not safe_to_decode?(info) ->
            Logger.warning(
              "Image exceeds decode limits (#{info.width}x#{info.height} #{info.format}), serving original"
            )
            {:ok, original_path}

          width >= info.width ->
            Logger.info("Requested width #{width} exceeds original width #{info.width}, using original")
            {:ok, original_path}

          true ->
            scale_image_for_response(original_path, width, url)
        end

      {:error, reason} ->
        Logger.warning("Failed to identify image (#{reason}), serving original to avoid decode")
        {:ok, original_path}
    end
  end

  defp gif?(format) when is_binary(format), do: String.starts_with?(format, "gif")
  defp gif?(_), do: false

  defp safe_to_decode?(%{width: w, height: h}) when is_integer(w) and is_integer(h) do
    w > 0 and h > 0 and w <= max_image_width() and h <= max_image_height() and w * h <= max_image_pixels()
  end

  # Scale the image and prepare the response
  defp scale_image_for_response(original_path, width, url) do
    scaled_key = "#{url}_#{width}"
    scaled_hash = HashUtils.hash_string(scaled_key)
    scaled_path = Path.join(@cache_dir, "scaled_#{scaled_hash}.webp")

    scale_image(original_path, scaled_path, width)
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
    case identify_image(path) do
      {:ok, %{format: format}} ->
        {:ok, normalize_ext(format)}

      {:error, identify_reason} ->
        Logger.warning("identify failed for format detection (#{identify_reason}), falling back to file")

        case System.cmd("file", ["--mime-type", "-b", path], stderr_to_stdout: true) do
          {mime, 0} ->
            {:ok, mime_to_ext(String.trim(mime))}

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

  defp normalize_ext("jpg"), do: "jpeg"
  defp normalize_ext("jpeg"), do: "jpeg"
  defp normalize_ext(format) when is_binary(format), do: format

  defp mime_to_ext("image/jpeg"), do: "jpeg"
  defp mime_to_ext("image/png"), do: "png"
  defp mime_to_ext("image/gif"), do: "gif"
  defp mime_to_ext("image/webp"), do: "webp"
  defp mime_to_ext(mime) do
    Logger.warning("Unexpected MIME type: #{mime}, defaulting to jpeg")
    "jpeg"
  end

  defp scale_image(input_path, output_path, width) do
    Logger.info("Scaling image #{input_path} to width #{width}")

    args = [
      "-limit", "memory", magick_memory_limit(),
      "-limit", "map", magick_map_limit(),
      "-limit", "area", magick_area_limit(),
      "-limit", "disk", magick_disk_limit(),
      "#{input_path}[0]",
      "-resize", "#{width}x>",
      "-strip",
      "-quality", "85",
      "-define", "webp:lossless=false",
      "-define", "webp:auto-filter=true",
      output_path
    ]

    case run_magick("convert", args, convert_timeout_sec()) do
      {:ok, _} ->
        track_scaled_file(output_path)

      {:error, reason} ->
        File.rm(output_path)
        Logger.error("Error scaling image: #{reason}")
        {:error, "Error scaling image: #{reason}"}
    end
  rescue
    e ->
      File.rm(output_path)
      Logger.error("Error scaling image: #{inspect(e)}")
      {:error, "Error scaling image: #{inspect(e)}"}
  end

  defp track_scaled_file(output_path) do
    if File.exists?(output_path) do
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

  # Ping the first frame only so animated/huge files are not decoded.
  defp identify_image(path) do
    case run_magick("identify", ["-ping", "-format", "%w %h %m", "#{path}[0]"], identify_timeout_sec()) do
      {:ok, output} ->
        case parse_identify_output(output) do
          {:ok, info} -> {:ok, info}
          :error -> {:error, "unexpected identify output: #{inspect(String.trim(output))}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_identify_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case Regex.run(~r/^(\d+)\s+(\d+)\s+(\S+)$/, String.trim(line)) do
        [_, w, h, format] ->
          {:ok,
           %{
             width: String.to_integer(w),
             height: String.to_integer(h),
             format: String.downcase(format)
           }}

        _ ->
          nil
      end
    end)
  end

  defp run_magick(command, args, timeout_sec) do
    executable = System.find_executable(command)

    if is_nil(executable) do
      {:error, "#{command} executable not found"}
    else
      {cmd, cmd_args} =
        case System.find_executable("timeout") do
          nil -> {executable, args}
          timeout_bin -> {timeout_bin, [Integer.to_string(timeout_sec), executable | args]}
        end

      case System.cmd(cmd, cmd_args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {_output, 124} ->
          {:error, "#{command} timed out after #{timeout_sec}s"}

        {output, code} ->
          {:error, "#{command} exited #{code}: #{String.slice(output, 0, 400)}"}
      end
    end
  end
end
