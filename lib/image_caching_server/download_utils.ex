defmodule ImageCachingServer.DownloadUtils do
  @moduledoc """
  Utilities for downloading images from various sources.
  Implements multiple strategies to handle different server requirements.
  """

  require Logger

  @download_timeout_ms 15_000

  defp max_download_bytes do
    case Integer.parse(System.get_env("MAX_DOWNLOAD_MB", "10")) do
      {n, _} when n > 0 -> n * 1024 * 1024
      _ -> 10 * 1024 * 1024
    end
  end

  @doc """
  Improved download image function that tries multiple methods in order of reliability.
  Based on systematic testing across problematic URLs.
  Returns {:ok, binary_data, client} or {:error, reason} where client indicates
  which downloader was used successfully.
  """
  def download_image_v2(url) do
    # For debugging - log the URL
    Logger.debug("download_image_v2 attempting to download: #{url}")

    # First try Req (native Elixir client, fastest and reliable)
    case download_with_req_optimized(url) do
      {:ok, body} when is_binary(body) and byte_size(body) > 100 ->
        Logger.info("Downloaded image using Req client: #{url}")
        {:ok, body, :req}
      {:error, {:http_error, status, description}} ->
        # Pass HTTP error codes to the caller in structured format
        Logger.info("HTTP error (#{status}): #{description} for URL: #{url}")
        {:error, {:http_error, status, description}}
      {:error, :too_large} ->
        Logger.warning("Download exceeded #{max_download_bytes()} byte limit: #{url}")
        {:error, "Failed to download image: file too large"}
      {:error, :not_image} ->
        Logger.warning("URL did not return an image: #{url}")
        {:error, "Failed to download image: response was not an image"}
      {:error, reason} ->
        Logger.debug("Req download attempt result: #{inspect(reason)}")
        if reason != "Req library not available" do
          Logger.info("Req client failed, falling back to curl: #{url}")
        end

        # Fallback to curl which has 100% success rate but slower
        case download_with_curl(url) do
          {:ok, body} when is_binary(body) and byte_size(body) > 100 ->
            Logger.info("Downloaded image using curl client: #{url}")
            {:ok, body, :curl}
          {:ok, body} ->
            Logger.warning("Downloaded file too small (#{byte_size(body)} bytes): #{url}", [])
            {:error, {:file_error, :too_small, byte_size(body)}}
          {:error, :too_large} ->
            Logger.warning("Curl download exceeded #{max_download_bytes()} byte limit: #{url}")
            {:error, "Failed to download image: file too large"}
          {:error, :not_image} ->
            Logger.warning("Curl download was not an image: #{url}")
            {:error, "Failed to download image: response was not an image"}
          error ->
            Logger.warning("Curl download failed: #{inspect(error)}", [])
            error
        end
    end
  end

  # Use system curl command which often handles TLS issues better
  defp download_with_curl(url) do
    Logger.debug("Attempting curl download: #{url}")
    temp_dir = System.tmp_dir!()
    output_path = Path.join(temp_dir, "curl_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.tmp")

    # Make sure curl is available
    case System.find_executable("curl") do
      nil ->
        Logger.error("curl executable not found in PATH", [])
        {:error, "curl executable not found in PATH"}
      curl_path ->
        try do
          Logger.debug("Using curl at path: #{curl_path}")

          # Set a reasonable timeout and follow redirects
          max_bytes = max_download_bytes()

          result = System.cmd(curl_path, [
            "--silent",
            "--location",
            "--max-time", Integer.to_string(div(@download_timeout_ms, 1000)),
            "--max-filesize", Integer.to_string(max_bytes),
            "--output", output_path,
            "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36",
            url
          ])

          case result do
            {_, 0} ->
              if File.exists?(output_path) do
                case File.stat(output_path) do
                  {:ok, %{size: size}} when size > max_bytes ->
                    File.rm(output_path)
                    Logger.warning("curl download exceeded size limit (#{size} bytes)", [])
                    {:error, :too_large}

                  {:ok, %{size: size}} when size > 100 ->
                    data = File.read!(output_path)
                    File.rm!(output_path)

                    if image_payload?(data) do
                      Logger.debug("curl download successful: #{byte_size(data)} bytes")
                      {:ok, data}
                    else
                      Logger.warning("curl download was not an image", [])
                      {:error, :not_image}
                    end

                  {:ok, %{size: size}} ->
                    File.rm(output_path)
                    Logger.warning("curl downloaded file too small: #{size} bytes", [])
                    {:error, "Downloaded file too small: #{size} bytes"}

                  {:error, stat_reason} ->
                    File.rm(output_path)
                    {:error, "Failed to stat curl download: #{inspect(stat_reason)}"}
                end
              else
                Logger.warning("curl did not create output file at #{output_path}", [])
                {:error, "File not downloaded"}
              end
            {_error, 63} ->
              File.rm(output_path)
              Logger.warning("curl download exceeded --max-filesize", [])
              {:error, :too_large}
            {error, code} ->
              Logger.warning("curl failed with code #{code}: #{error}", [])
              File.rm(output_path)
              {:error, "Curl failed with code #{code}: #{error}"}
          end
        rescue
          e ->
            Logger.error("Exception in curl download: #{inspect(e)}", [])
            # Make sure we clean up the temp file
            File.rm(output_path)
            {:error, "Exception in curl download: #{inspect(e)}"}
        end
    end
  end

  @doc """
  RECOMMENDED NATIVE CLIENT: Based on our systematic tests, Req is the most reliable
  native Elixir HTTP client for these problematic URLs. It handles TLS handshake issues
  better than other clients, and is nearly as reliable as curl with better performance.
  """
  def download_with_req_optimized(url) do
    Logger.debug("Attempting Req download with optimized settings: #{url}")

    if Code.ensure_loaded?(Req) do
      try do
        # Use all the options that worked well in our tests
        case make_req_request(url) do
          {:ok, %{status: 200, body: :too_large}} ->
            {:error, :too_large}
          {:ok, %{status: 200, body: body, headers: headers}} when is_binary(body) ->
            cond do
              not image_content_type?(headers) -> {:error, :not_image}
              not image_payload?(body) -> {:error, :not_image}
              true -> handle_successful_req_response(body)
            end
          {:ok, %{status: status}} ->
            handle_req_error_status(status)
          {:error, error} ->
            Logger.warning("Req error: #{inspect(error)}", [])
            {:error, "Req error: #{inspect(error)}"}
        end
      rescue
        e ->
          Logger.error("Exception in Req download: #{inspect(e)}", [])
          {:error, "Exception in Req download: #{inspect(e)}"}
      end
    else
      Logger.warning("Req library not available", [])
      {:error, "Req library not available"}
    end
  end

  # Makes the actual HTTP request with Req
  defp make_req_request(url) do
    max_bytes = max_download_bytes()

    Req.get(url,
      receive_timeout: @download_timeout_ms,
      # Important options that help with TLS issues - using simpler config to avoid errors
      connect_options: [
        transport_opts: [
          verify: :verify_none  # Skip strict certificate verification
          # Don't specify cipher_suites or versions to use defaults
        ]
      ],
      max_redirects: 10,         # Handle more redirects than default
      retry: :transient,         # Auto-retry on network errors
      # Browser-like headers help with some servers that check for browser requests
      user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36",
      headers: [
        {"accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"},
        {"accept-language", "en-US,en;q=0.9"}
      ],
      into: fn {:data, chunk}, {req, resp} ->
        prev = if is_binary(resp.body), do: resp.body, else: ""
        new_size = byte_size(prev) + byte_size(chunk)

        if new_size > max_bytes do
          {:halt, {req, %{resp | body: :too_large}}}
        else
          {:cont, {req, %{resp | body: prev <> chunk}}}
        end
      end
    )
  end

  # Handle a successful (status 200) Req response
  defp handle_successful_req_response(body) when is_binary(body) and byte_size(body) > 100 do
    if byte_size(body) > max_download_bytes() do
      {:error, :too_large}
    else
      Logger.debug("Req download successful: #{byte_size(body)} bytes")
      {:ok, body}
    end
  end

  defp handle_successful_req_response(body) do
    Logger.warning("Req downloaded file too small: #{byte_size(body)} bytes", [])
    {:error, "Downloaded file too small: #{byte_size(body)} bytes"}
  end

  # Maps HTTP status codes to their description
  @http_status_descriptions %{
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    410 => "Gone",
    429 => "Too Many Requests",
    451 => "Unavailable For Legal Reasons"
  }

  # Handle HTTP error status codes
  defp handle_req_error_status(status) do
    description = Map.get(@http_status_descriptions, status, "HTTP Error")
    Logger.warning("Req HTTP error status: #{status}", [])
    {:error, {:http_error, status, description}}
  end

  defp image_content_type?(headers) do
    case content_type(headers) do
      nil -> true
      ct ->
        ct = String.downcase(ct)

        String.starts_with?(ct, "image/") or
          String.starts_with?(ct, "application/octet-stream") or
          String.starts_with?(ct, "binary/")
    end
  end

  defp content_type(headers) when is_map(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "content-type", do: header_value(value)

      _ ->
        nil
    end)
  end

  defp content_type(_), do: nil

  defp header_value(value) when is_binary(value), do: value
  defp header_value([value | _]) when is_binary(value), do: value
  defp header_value(_), do: nil

  defp image_payload?(<<0xFF, 0xD8, _::binary>>), do: true
  defp image_payload?(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: true
  defp image_payload?(<<"GIF87a", _::binary>>), do: true
  defp image_payload?(<<"GIF89a", _::binary>>), do: true
  defp image_payload?(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: true
  defp image_payload?(_), do: false
end
