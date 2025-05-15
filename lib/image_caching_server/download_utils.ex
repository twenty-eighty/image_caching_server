defmodule ImageCachingServer.DownloadUtils do
  @moduledoc """
  Utilities for downloading images from various sources.
  Implements multiple strategies to handle different server requirements.
  """

  require Logger

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
      {:error, "HTTP status: 404"} ->
        # Don't fall back to curl for 404 errors - the resource doesn't exist
        Logger.info("Image not found (404) for URL: #{url}")
        {:error, "Image not found (404)"}
      {:error, "HTTP status: 403"} ->
        # Access forbidden - curl won't help here
        Logger.info("Access forbidden (403) for URL: #{url}")
        {:error, "Access forbidden (403)"}
      {:error, "HTTP status: 401"} ->
        # Authentication required - curl won't help without credentials
        Logger.info("Authentication required (401) for URL: #{url}")
        {:error, "Authentication required (401)"}
      {:error, "HTTP status: 410"} ->
        # Resource gone permanently - curl won't help
        Logger.info("Resource permanently removed (410) for URL: #{url}")
        {:error, "Resource permanently removed (410)"}
      {:error, "HTTP status: 400"} ->
        # Bad request - client error, curl won't help
        Logger.info("Bad request (400) for URL: #{url}")
        {:error, "Bad request (400)"}
      {:error, "HTTP status: 405"} ->
        # Method not allowed - client error, curl won't help
        Logger.info("Method not allowed (405) for URL: #{url}")
        {:error, "Method not allowed (405)"}
      {:error, "HTTP status: 429"} ->
        # Rate limiting - retry with curl would likely also be rate limited
        Logger.info("Rate limited (429) for URL: #{url}")
        {:error, "Rate limited (429) - too many requests"}
      {:error, "HTTP status: 451"} ->
        # Unavailable for legal reasons - won't be accessible with curl either
        Logger.info("Content unavailable for legal reasons (451) for URL: #{url}")
        {:error, "Content unavailable for legal reasons (451)"}
      error ->
        Logger.debug("Req download attempt result: #{inspect(error)}")
        if error != {:error, "Req library not available"} do
          Logger.info("Req client failed, falling back to curl: #{url}")
        end

        # Fallback to curl which has 100% success rate but slower
        case download_with_curl(url) do
          {:ok, body} when is_binary(body) and byte_size(body) > 100 ->
            Logger.info("Downloaded image using curl client: #{url}")
            {:ok, body, :curl}
          {:ok, body} ->
            Logger.warning("Downloaded file too small (#{byte_size(body)} bytes): #{url}", [])
            {:error, "Downloaded file too small: #{byte_size(body)} bytes"}
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
          result = System.cmd(curl_path, [
            "--silent",
            "--location",
            "--max-time", "30",
            "--output", output_path,
            "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36",
            url
          ])

          case result do
            {_, 0} ->
              if File.exists?(output_path) do
                data = File.read!(output_path)
                File.rm!(output_path)

                if byte_size(data) > 100 do
                  Logger.debug("curl download successful: #{byte_size(data)} bytes")
                  {:ok, data}
                else
                  Logger.warning("curl downloaded file too small: #{byte_size(data)} bytes", [])
                  {:error, "Downloaded file too small: #{byte_size(data)} bytes"}
                end
              else
                Logger.warning("curl did not create output file at #{output_path}", [])
                {:error, "File not downloaded"}
              end
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
        case Req.get(url,
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
          ]
        ) do
          {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 100 ->
            Logger.debug("Req download successful: #{byte_size(body)} bytes")
            {:ok, body}
          {:ok, %{status: 200, body: body}} ->
            Logger.warning("Req downloaded file too small: #{byte_size(body)} bytes", [])
            {:error, "Downloaded file too small: #{byte_size(body)} bytes"}
          {:ok, %{status: status}} ->
            Logger.warning("Req HTTP error status: #{status}", [])
            {:error, "HTTP status: #{status}"}
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
end
