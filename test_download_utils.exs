#!/usr/bin/env elixir

# This script tests the optimized download_image_v2 function directly
# Run with: mix run test_download_utils.exs

defmodule DownloadUtilsTester do
  require Logger
  alias ImageCachingServer.DownloadUtils

  @test_urls [
    "https://picsum.photos/seed/The%20Business%20School%20and%20Bitcoin/800/400",
    "https://m.primal.net/IeiY.jpg",
    "https://cdn.nostr.build/i/p/fb4f2c4d4cf0255f39fb5ee98d5d14990e83804a44750b86e1e164a38934decc.jpg",
    "https://m.primal.net/NMdI.jpg",
    "https://m.primal.net/LKte.jpg",
    "https://imgproxy.f7z.io/x_gXik-JZQ7U2VoQpIXhicgj5X27mTrdxHziH6GZImw/w:2400/aHR0cHM6Ly9ibG9zc29tLnByaW1hbC5uZXQvZTZlNjcxOWJhODQwOGJjMjJkMzNmNDgzNDgyOWYzYzU2NGE3MjJlNjMwMWI2YWI3ZDNlMDRkNTZlMmZlMTQ2MC5qcGc"
  ]

  @output_dir "tmp/download_utils_test"

  def run do
    # Ensure output directory exists
    File.mkdir_p!(@output_dir)

    IO.puts("\n=== TESTING OPTIMIZED DOWNLOAD FUNCTION ===\n")

    # Test each URL
    results = Enum.map(@test_urls, &test_url/1)

    # Print summary
    success_count = Enum.count(results, fn r -> r.success end)

    IO.puts("\n=== SUMMARY ===")
    IO.puts("Successful downloads: #{success_count}/#{length(@test_urls)} (#{Float.round(success_count / length(@test_urls) * 100, 1)}%)")

    avg_time = case Enum.filter(results, & &1.success) do
      [] -> nil
      successful ->
        total_time = Enum.reduce(successful, 0, fn r, acc -> acc + r.time_ms end)
        total_time / length(successful)
    end

    if avg_time, do: IO.puts("Average download time: #{Float.round(avg_time, 2)}ms")

    # Check which client was used
    req_count = Enum.count(results, &(&1.success && &1.client == :req))
    curl_count = Enum.count(results, &(&1.success && &1.client == :curl))

    if success_count > 0 do
      IO.puts("\nClients used:")
      IO.puts("  Req: #{req_count}/#{success_count} (#{Float.round(req_count / success_count * 100, 1)}%)")
      IO.puts("  Curl: #{curl_count}/#{success_count} (#{Float.round(curl_count / success_count * 100, 1)}%)")

      avg_req_time = case Enum.filter(results, &(&1.success && &1.client == :req)) do
        [] -> nil
        req_results ->
          total_time = Enum.reduce(req_results, 0, fn r, acc -> acc + r.time_ms end)
          total_time / length(req_results)
      end

      avg_curl_time = case Enum.filter(results, &(&1.success && &1.client == :curl)) do
        [] -> nil
        curl_results ->
          total_time = Enum.reduce(curl_results, 0, fn r, acc -> acc + r.time_ms end)
          total_time / length(curl_results)
      end

      if avg_req_time, do: IO.puts("  Avg Req time: #{Float.round(avg_req_time, 2)}ms")
      if avg_curl_time, do: IO.puts("  Avg Curl time: #{Float.round(avg_curl_time, 2)}ms")
    end

    IO.puts("\nFiles saved to #{@output_dir}")
  end

  defp test_url(url) do
    IO.puts("Testing URL: #{url}")

    # Test the optimized download function
    start_time = System.monotonic_time(:millisecond)

    result = try do
      # Test the download_image_v2 function
      case DownloadUtils.download_image_v2(url) do
        {:ok, data, client} when is_binary(data) and byte_size(data) > 100 ->
          # Now we get the client directly from the function
          # Save the downloaded file
          filename = "#{client}_#{:crypto.hash(:md5, url) |> Base.encode16(case: :lower)}.bin"
          output_path = Path.join(@output_dir, filename)
          File.write!(output_path, data)

          %{
            success: true,
            message: "Successfully downloaded #{byte_size(data) |> format_bytes()}",
            time_ms: System.monotonic_time(:millisecond) - start_time,
            file: output_path,
            size: byte_size(data),
            client: client
          }

        {:ok, data, _} ->
          %{
            success: false,
            message: "Downloaded file too small: #{byte_size(data)} bytes",
            time_ms: System.monotonic_time(:millisecond) - start_time,
            client: :unknown
          }

        {:error, reason} ->
          %{
            success: false,
            message: "Error: #{inspect(reason)}",
            time_ms: System.monotonic_time(:millisecond) - start_time,
            client: :unknown
          }
      end
    rescue
      e ->
        %{
          success: false,
          message: "Exception: #{inspect(e)}",
          time_ms: System.monotonic_time(:millisecond) - start_time,
          client: :unknown
        }
    end

    IO.puts("  #{result.message}")
    if Map.has_key?(result, :client) && result.client != :unknown, do: IO.puts("  Used client: #{result.client}")
    IO.puts("  Time: #{result.time_ms}ms")
    IO.puts("-------------------")

    result
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes > 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end
end

# Run the test
DownloadUtilsTester.run()
