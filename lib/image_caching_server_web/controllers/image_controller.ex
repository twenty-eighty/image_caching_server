defmodule ImageCachingServerWeb.ImageController do
  use ImageCachingServerWeb, :controller
  require Logger
  alias ImageCachingServer.HashUtils

  plug ImageCachingServerWeb.Plugs.VerifyOrigin

  @type request_timing :: %{
    start_time: integer(),
    url: String.t(),
    width: integer(),
    path: String.t() | nil
  }

  @doc """
  Handles image scaling requests.
  """
  def scale(conn = %Plug.Conn{}, %{"url" => url, "width" => width}) do
    timing = %{
      start_time: System.monotonic_time(),
      url: url,
      width: 0,  # Default width, will be updated after validation
      path: nil  # Will be set when we get the image path
    }

    with {:ok, width_int} <- validate_width(width),
         timing = %{timing | width: width_int},
         {:ok, image_path} <- get_cached_image(url, width_int, timing),
         timing = %{timing | path: image_path},
         {:ok, image_data} <- read_image_file(image_path, timing) do
      send_success_response(conn, image_data, timing)
    else
      {:error, :invalid_width} ->
        send_error_response(conn, :bad_request, "Invalid width parameter", timing)
      {:error, :file_read_error, reason} ->
        error_message = "Failed to read scaled image: #{inspect(reason)}"
        send_error_response(conn, :internal_server_error, error_message, timing)
      {:error, reason} when is_binary(reason) ->
        if String.contains?(reason, "Failed to download image") do
          # Log the failure and redirect to original URL
          log_timing("Redirecting to original URL due to download failure", timing)
          conn
          |> put_status(302)
          |> put_resp_header("location", url)
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(302, "")
        else
          error_message = "#{inspect(reason)}"
          send_error_response(conn, :bad_request, error_message, timing)
        end
    end
  end

  def scale(conn = %Plug.Conn{}, _params) do
    # Create a minimal timing map for consistency
    timing = %{
      start_time: System.monotonic_time(),
      url: "",
      width: 0,
      path: nil
    }
    send_error_response(conn, :bad_request, "Missing required parameters: url and width", timing)
  end

  # Private helper functions

  @spec validate_width(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_width}
  defp validate_width(width) when is_binary(width) do
    case Integer.parse(width) do
      {width_int, _} when width_int > 0 -> {:ok, width_int}
      _ -> {:error, :invalid_width}
    end
  end
  defp validate_width(_), do: {:error, :invalid_width}

  @spec get_cached_image(String.t(), pos_integer(), request_timing()) ::
    {:ok, String.t()} | {:error, String.t()}
  defp get_cached_image(url, width, _timing) do
    Logger.info("Processing request: url=#{url} width=#{width}")
    ImageCachingServer.ImageCache.get_image(url, width)
  end

  @spec read_image_file(String.t(), request_timing()) ::
    {:ok, binary()} | {:error, :file_read_error, String.t()}
  defp read_image_file(path, _timing) do
    case File.read(path) do
      {:ok, data} ->
        {:ok, data}
      {:error, reason} ->
        error_str = "#{inspect(reason)}"
        {:error, :file_read_error, error_str}
    end
  end

  @spec send_success_response(Plug.Conn.t(), binary(), request_timing()) :: Plug.Conn.t()
  defp send_success_response(%Plug.Conn{} = conn, image_data, timing) do
    log_timing("Request completed", timing)

    # Get the path from the timing map and generate ETag
    # We know path is always present in the success case
    etag = HashUtils.etag_from_path(timing.path) || HashUtils.generate_etag(image_data)

    # Set aggressive caching headers since our images are content-addressed
    # Cache for 1 year (31536000 seconds)
    conn
    |> put_resp_content_type(get_content_type(image_data))
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("expires", format_expires_header(31536000))
    |> put_resp_header("etag", etag)
    |> send_resp(200, image_data)
  end

  # Format expires header in RFC 1123 format
  defp format_expires_header(max_age_seconds) do
    DateTime.utc_now()
    |> DateTime.add(max_age_seconds, :second)
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  @spec send_error_response(Plug.Conn.t(), atom(), String.t(), request_timing()) :: Plug.Conn.t()
  defp send_error_response(%Plug.Conn{} = conn, status, message, timing) do
    log_timing("Request failed: #{message}", timing)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  @spec log_timing(String.t(), request_timing()) :: :ok
  defp log_timing(prefix, %{start_time: start_time, url: url, width: width} = _timing) do
    processing_time = System.convert_time_unit(
      System.monotonic_time() - start_time,
      :native,
      :millisecond
    )

    Logger.info("#{prefix}: url=#{url} width=#{width} time=#{processing_time}ms")
  end

  @spec get_content_type(binary()) :: String.t()
  defp get_content_type(image_data) do
    # Simple magic number check for common image formats
    case image_data do
      <<0x47, 0x49, 0x46, 0x38, _rest::binary>> -> "image/gif"
      <<0x89, 0x50, 0x4E, 0x47, _rest::binary>> -> "image/png"
      <<0xFF, 0xD8, _rest::binary>> -> "image/jpeg"
      <<0x52, 0x49, 0x46, 0x46, _rest::binary>> -> "image/webp"
      _ -> "image/jpeg"  # Default to JPEG if unknown
    end
  end
end
