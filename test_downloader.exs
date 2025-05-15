#!/usr/bin/env elixir

# This script tests the download utilities on problematic URLs
# Run with: mix run test_downloader.exs

defmodule DownloaderTest do
  require Logger

  @test_urls [
    "https://picsum.photos/seed/The%20Business%20School%20and%20Bitcoin/800/400",
    "https://m.primal.net/IeiY.jpg",
    "https://cdn.nostr.build/i/p/fb4f2c4d4cf0255f39fb5ee98d5d14990e83804a44750b86e1e164a38934decc.jpg",
    "https://m.primal.net/NMdI.jpg",
    "https://m.primal.net/LKte.jpg",
    "https://imgproxy.f7z.io/x_gXik-JZQ7U2VoQpIXhicgj5X27mTrdxHziH6GZImw/w:2400/aHR0cHM6Ly9ibG9zc29tLnByaW1hbC5uZXQvZTZlNjcxOWJhODQwOGJjMjJkMzNmNDgzNDgyOWYzYzU2NGE3MjJlNjMwMWI2YWI3ZDNlMDRkNTZlMmZlMTQ2MC5qcGc"
  ]

  @output_dir "tmp/test_downloads"

  def run do
    # Ensure output directory exists
    File.mkdir_p!(@output_dir)

    IO.puts("\n=== TESTING DOWNLOAD METHODS ===\n")

    # Run tests for each URL
    Enum.each(@test_urls, fn url ->
      test_url(url)
    end)
  end

  def test_url(url) do
    IO.puts("Testing URL: #{url}")

    # Try to download with our utility
    result = ImageCachingServer.DownloadUtils.download_image(url)

    case result do
      {:ok, data} when is_binary(data) and byte_size(data) > 100 ->
        # Save the file for inspection
        filename = Path.basename(url)
        output_path = Path.join(@output_dir, "success_#{filename}")
        File.write!(output_path, data)

        IO.puts("✅ SUCCESS: Downloaded #{byte_size(data) |> format_bytes()} to #{output_path}")

      {:ok, data} ->
        IO.puts("⚠️ WARNING: Downloaded too small file (#{byte_size(data)} bytes)")

      {:error, reason} ->
        IO.puts("❌ FAILED: #{reason}")
    end

    IO.puts("---------------------------------------------")
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes > 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end
end

# Run the tests
DownloaderTest.run()
