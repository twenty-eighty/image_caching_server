defmodule ImageCachingServerWeb.ImageController do
  use ImageCachingServerWeb, :controller
  require Logger

  plug ImageCachingServerWeb.Plugs.VerifyOrigin

  @type request_timing :: %{start_time: integer(), url: String.t(), width: integer()}

  @doc """
  Handles image scaling requests.
  """
  def scale(conn, %{"url" => url, "width" => width}) do
    timing = %{start_time: System.monotonic_time(), url: url}

    with {:ok, width_int} <- validate_width(width),
         timing = Map.put(timing, :width, width_int),
         {:ok, image_path} <- get_cached_image(url, width_int, timing),
         {:ok, image_data} <- read_image_file(image_path, timing) do
      send_success_response(conn, image_data, timing)
    else
      {:error, :invalid_width} ->
        send_error_response(conn, :bad_request, "Invalid width parameter", timing)
      {:error, :file_read_error, reason} ->
        send_error_response(conn, :internal_server_error, "Failed to read scaled image: #{reason}", timing)
      {:error, reason} ->
        send_error_response(conn, :bad_request, reason, timing)
    end
  end

  def scale(conn, _params) do
    send_error_response(conn, :bad_request, "Missing required parameters: url and width")
  end

  # Private helper functions

  @spec validate_width(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_width}
  defp validate_width(width) do
    case Integer.parse(width) do
      {width_int, _} when width_int > 0 -> {:ok, width_int}
      _ -> {:error, :invalid_width}
    end
  end

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
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, :file_read_error, inspect(reason)}
    end
  end

  @spec send_success_response(Plug.Conn.t(), binary(), request_timing()) :: Plug.Conn.t()
  defp send_success_response(conn, image_data, timing) do
    log_timing("Request completed", timing)

    conn
    |> put_resp_content_type(get_content_type(image_data))
    |> send_resp(200, image_data)
  end

  @spec send_error_response(Plug.Conn.t(), atom(), String.t(), request_timing() | nil) :: Plug.Conn.t()
  defp send_error_response(conn, status, message, timing \\ nil) do
    if timing, do: log_timing("Request failed: #{message}", timing)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  @spec log_timing(String.t(), request_timing()) :: :ok
  defp log_timing(prefix, %{start_time: start_time, url: url} = timing) do
    processing_time = System.convert_time_unit(
      System.monotonic_time() - start_time,
      :native,
      :millisecond
    )

    width_info = if Map.has_key?(timing, :width), do: " width=#{timing.width}", else: ""
    Logger.info("#{prefix}: url=#{url}#{width_info} time=#{processing_time}ms")
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
