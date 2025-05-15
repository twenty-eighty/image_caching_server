#!/usr/bin/env elixir

# This script tests various native Elixir HTTP clients on problematic URLs
# Run with: mix run test_native_clients.exs

defmodule NativeClientsTester do
  require Logger

  @test_urls [
    "https://picsum.photos/seed/The%20Business%20School%20and%20Bitcoin/800/400",
    "https://m.primal.net/IeiY.jpg",
    "https://cdn.nostr.build/i/p/fb4f2c4d4cf0255f39fb5ee98d5d14990e83804a44750b86e1e164a38934decc.jpg",
    "https://m.primal.net/NMdI.jpg",
    "https://m.primal.net/LKte.jpg",
    "https://imgproxy.f7z.io/x_gXik-JZQ7U2VoQpIXhicgj5X27mTrdxHziH6GZImw/w:2400/aHR0cHM6Ly9ibG9zc29tLnByaW1hbC5uZXQvZTZlNjcxOWJhODQwOGJjMjJkMzNmNDgzNDgyOWYzYzU2NGE3MjJlNjMwMWI2YWI3ZDNlMDRkNTZlMmZlMTQ2MC5qcGc"
  ]

  @output_dir "tmp/native_test_downloads"

  def run do
    # Ensure output directory exists
    File.mkdir_p!(@output_dir)

    IO.puts("\n=== TESTING NATIVE ELIXIR HTTP CLIENTS ===\n")

    # Start Finch for tests
    {:ok, _} = Finch.start_link(name: MyFinch)

    # Start Tesla for tests (if not using Finch adapter)
    # Tesla.Adapter.Hackney.start()

    # Run tests for each URL
    results = Enum.map(@test_urls, &test_url_with_all_clients/1)

    # Print summary
    print_summary(results)
  end

  def test_url_with_all_clients(url) do
    IO.puts("Testing URL: #{url}")

    # Define all clients to test
    clients = [
      {:curl, &download_with_curl/1},
      {:httpoison_advanced, &download_with_httpoison_advanced/1},
      {:finch_basic, &download_with_finch_basic/1},
      {:finch_advanced, &download_with_finch_advanced/1},
      {:req_basic, &download_with_req_basic/1},
      {:req_advanced, &download_with_req_advanced/1},
      {:httpc, &download_with_httpc/1},
      {:gun, &download_with_gun/1},
      {:tesla, &download_with_tesla/1}
    ]

    # Test each client
    client_results = Enum.map(clients, fn {name, client_fn} ->
      IO.puts("  Testing #{name}...")
      result = test_client(name, client_fn, url)
      IO.puts("    #{result.status}: #{result.message}")
      {name, result}
    end)

    IO.puts("---------------------------------------------")
    {url, client_results}
  end

  defp test_client(name, client_fn, url) do
    start_time = System.monotonic_time(:millisecond)

    result = try do
      case client_fn.(url) do
        {:ok, body} when is_binary(body) and byte_size(body) > 100 ->
          # Save successful download as evidence
          file_name = "#{name}_#{Path.basename(url)}"
          output_path = Path.join(@output_dir, file_name)
          File.write!(output_path, body)

          %{
            status: :success,
            message: "Downloaded #{byte_size(body) |> format_bytes()}",
            file: output_path,
            size: byte_size(body)
          }

        {:ok, body} when is_binary(body) ->
          %{
            status: :partial,
            message: "Downloaded too small file (#{byte_size(body)} bytes)",
            size: byte_size(body)
          }

        {:error, reason} ->
          %{
            status: :error,
            message: "Failed: #{inspect(reason)}"
          }

        unexpected ->
          %{
            status: :error,
            message: "Unexpected response: #{inspect(unexpected)}"
          }
      end
    rescue
      e ->
        %{
          status: :error,
          message: "Exception: #{inspect(e)}"
        }
    catch
      kind, value ->
        %{
          status: :error,
          message: "#{kind}: #{inspect(value)}"
        }
    end

    end_time = System.monotonic_time(:millisecond)
    Map.put(result, :time_ms, end_time - start_time)
  end

  # CURL - reference method
  defp download_with_curl(url) do
    temp_dir = System.tmp_dir!()
    output_path = Path.join(temp_dir, "curl_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}.tmp")

    result = System.cmd("curl", [
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

          if byte_size(data) > 0 do
            {:ok, data}
          else
            {:error, "Downloaded file is empty"}
          end
        else
          {:error, "File not downloaded"}
        end
      {error, code} ->
        File.rm(output_path)
        {:error, "Curl failed with code #{code}: #{error}"}
    end
  rescue
    e -> {:error, "Exception in curl download: #{inspect(e)}"}
  end

  # HTTPOISON ADVANCED - with browser headers and TLS options
  defp download_with_httpoison_advanced(url) do
    headers = [
      {"Host", URI.parse(url).host},
      {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36"},
      {"Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.9"},
      {"Connection", "keep-alive"}
    ]

    # Try with advanced hackney options
    case HTTPoison.get(url, headers, [
      follow_redirect: true,
      hackney: [
        cookie: [],
        follow_redirect: true,
        ssl_options: [
          verify: :verify_none,
          versions: [:"tlsv1.2", :"tlsv1.1", :"tlsv1"],
          ciphers: :ssl.cipher_suites(:all, :"tlsv1.2"),
          honor_cipher_order: true,
          fallback: true
        ]
      ],
      recv_timeout: 30_000,
      timeout: 30_000
    ]) do
      {:ok, %{status_code: 200, body: body}} -> {:ok, body}
      {:ok, %{status_code: status}} -> {:error, "HTTP status: #{status}"}
      {:error, reason} -> {:error, "HTTPoison error: #{inspect(reason)}"}
    end
  end

  # FINCH BASIC - simple configuration
  defp download_with_finch_basic(url) do
    request = Finch.build(:get, url)

    case Finch.request(request, MyFinch) do
      {:ok, %Finch.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Finch.Response{status: status}} -> {:error, "Finch status: #{status}"}
      {:error, reason} -> {:error, "Finch error: #{inspect(reason)}"}
    end
  end

  # FINCH ADVANCED - with browser headers and TLS options
  defp download_with_finch_advanced(url) do
    # Advanced TLS options
    tls_options = [
      verify: :verify_none,
      versions: [:"tlsv1.2", :"tlsv1.1", :"tlsv1"],
      ciphers: :ssl.cipher_suites(:all, :"tlsv1.2"),
      honor_cipher_order: true,
      fallback: true
    ]

    # Build request with browser-like headers
    request = Finch.build(:get, url, [
      {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36"},
      {"Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.9"}
    ], nil, [
      pool_timeout: 30_000,
      receive_timeout: 30_000,
      transport_opts: %{
        ssl_opts: tls_options
      }
    ])

    case Finch.request(request, MyFinch) do
      {:ok, %Finch.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Finch.Response{status: status}} -> {:error, "Finch status: #{status}"}
      {:error, error} -> {:error, "Finch error: #{inspect(error)}"}
    end
  end

  # REQ BASIC - simple configuration
  defp download_with_req_basic(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Req status: #{status}"}
      {:error, reason} -> {:error, "Req error: #{inspect(reason)}"}
    end
  end

  # REQ ADVANCED - with browser headers and TLS options
  defp download_with_req_advanced(url) do
    case Req.get(url,
      connect_options: [
        transport_opts: [
          verify: :verify_none,
          versions: [:"tlsv1.2", :"tlsv1.1", :"tlsv1"],
          ciphers: :ssl.cipher_suites(:all, :"tlsv1.2")
        ]
      ],
      max_redirects: 10,
      user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36",
      headers: [
        {"accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"},
        {"accept-language", "en-US,en;q=0.9"}
      ],
      retry: :transient,
      cache: false
    ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Req status: #{status}"}
      {:error, error} -> {:error, "Req error: #{inspect(error)}"}
    end
  end

  # HTTPC - Erlang's built-in HTTP client
  defp download_with_httpc(url) do
    {:ok, _} = :inets.start()
    {:ok, _} = :ssl.start()

    # Set advanced SSL options
    http_options = [
      ssl: [
        verify: :verify_none,
        versions: [:"tlsv1.2", :"tlsv1.1", :"tlsv1"],
        ciphers: :ssl.cipher_suites(:all, :"tlsv1.2")
      ],
      timeout: 30_000,
      autoredirect: true
    ]

    headers = [
      {'User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36'},
      {'Accept', 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8'}
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_options, [body_format: :binary]) do
      {:ok, {{_, 200, _}, _headers, body}} when is_binary(body) ->
        {:ok, body}
      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Httpc status: #{status}"}
      {:error, reason} ->
        {:error, "Httpc error: #{inspect(reason)}"}
    end
  end

  # GUN - Erlang HTTP client
  defp download_with_gun(url) do
    uri = URI.parse(url)

    # Start gun
    {:ok, conn} = :gun.open(String.to_charlist(uri.host), uri.port || 443, %{
      protocols: [:http],
      transport: :tls,
      transport_opts: %{
        verify: :verify_none,
        versions: [:"tlsv1.2", :"tlsv1.1", :"tlsv1"],
        ciphers: :ssl.cipher_suites(:all, :"tlsv1.2")
      }
    })

    # Wait for connection
    case :gun.await_up(conn, 5000) do
      {:ok, _} ->
        path = case uri.query do
          nil -> uri.path || "/"
          query -> "#{uri.path || "/"}?#{query}"
        end

        # Send request
        stream = :gun.get(conn, String.to_charlist(path), [
          {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36"},
          {"Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"},
          {"Host", uri.host}
        ])

        # Get response
        case :gun.await(conn, stream, 30000) do
          {:response, :fin, status, _headers} ->
            :gun.close(conn)
            {:error, "Empty response with status #{status}"}

          {:response, :nofin, status, headers} ->
            case status do
              200 ->
                # Get body
                {:ok, body} = receive_body(conn, stream, [])
                :gun.close(conn)
                {:ok, body}

              _ ->
                :gun.close(conn)
                {:error, "HTTP status: #{status}"}
            end

          {:error, reason} ->
            :gun.close(conn)
            {:error, "Gun error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Gun connection error: #{inspect(reason)}"}
    end
  end

  # Helper for gun to receive body chunks
  defp receive_body(conn, stream, acc) do
    case :gun.await(conn, stream, 30000) do
      {:data, :fin, data} ->
        {:ok, Enum.reverse([data | acc]) |> IO.iodata_to_binary()}

      {:data, :nofin, data} ->
        receive_body(conn, stream, [data | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  # TESLA - HTTP client framework
  defp download_with_tesla(url) do
    # Configure Tesla with middlewares
    client = Tesla.client([
      {Tesla.Middleware.Headers, [
        {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36"},
        {"Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"}
      ]},
      {Tesla.Middleware.FollowRedirects, max_redirects: 10},
      {Tesla.Middleware.Timeout, timeout: 30_000}
    ], {Tesla.Adapter.Hackney, [
      ssl_options: [
        verify: :verify_none,
        versions: [:"tlsv1.2", :"tlsv1.1", :"tlsv1"],
        ciphers: :ssl.cipher_suites(:all, :"tlsv1.2")
      ]
    ]})

    case Tesla.get(client, url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Tesla status: #{status}"}
      {:error, reason} -> {:error, "Tesla error: #{inspect(reason)}"}
    end
  end

  # Print summary of results
  defp print_summary(results) do
    IO.puts("\n=== SUMMARY ===\n")

    # Count successes per client
    client_results = results
    |> Enum.flat_map(fn {_url, client_results} -> client_results end)
    |> Enum.group_by(fn {client, _} -> client end, fn {_, result} -> result.status end)
    |> Enum.map(fn {client, statuses} ->
      success_count = Enum.count(statuses, fn status -> status == :success end)
      {client, success_count, length(results)}
    end)
    |> Enum.sort_by(fn {_, success_count, _} -> success_count end, :desc)

    # Print success rate per client
    IO.puts("Success rate by client:")
    Enum.each(client_results, fn {client, success_count, total} ->
      percentage = Float.round(success_count / total * 100, 1)
      IO.puts("  #{client}: #{success_count}/#{total} (#{percentage}%)")
    end)

    # Find best client
    case Enum.max_by(client_results, fn {_, success_count, _} -> success_count end, fn -> nil end) do
      {best_client, best_count, total} when best_count > 0 ->
        IO.puts("\nBest client: #{best_client} with #{best_count}/#{total} successful downloads")

        # Compare with curl
        curl_result = Enum.find(client_results, fn {client, _, _} -> client == :curl end)
        case curl_result do
          {:curl, curl_count, _} when best_count > curl_count ->
            IO.puts("\n#{best_client} is better than curl for these URLs")
          {:curl, curl_count, _} when best_count == curl_count ->
            IO.puts("\n#{best_client} is as good as curl for these URLs")
          {:curl, curl_count, _} when best_count < curl_count ->
            IO.puts("\nCurl is still better than native clients for these URLs")
          _ ->
            IO.puts("\nCould not compare with curl")
        end

      _ ->
        IO.puts("\nNo successful downloads with any client")
    end

    # Print performance comparison
    IO.puts("\nAverage download time by client:")
    time_by_client = results
    |> Enum.flat_map(fn {_url, client_results} -> client_results end)
    |> Enum.filter(fn {_, result} -> result.status == :success end)
    |> Enum.group_by(fn {client, _} -> client end, fn {_, result} -> result.time_ms end)
    |> Enum.map(fn {client, times} ->
      avg_time = case times do
        [] -> nil
        _ -> Enum.sum(times) / length(times)
      end
      {client, avg_time}
    end)
    |> Enum.filter(fn {_, avg} -> avg != nil end)
    |> Enum.sort_by(fn {_, avg} -> avg end)

    Enum.each(time_by_client, fn {client, avg} ->
      IO.puts("  #{client}: #{Float.round(avg, 2)}ms")
    end)
  end

  # Helper to format byte sizes
  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes > 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes > 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end
end

# Run the tests
NativeClientsTester.run()
