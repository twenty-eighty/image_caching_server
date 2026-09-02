defmodule ImageCachingServerWeb.Plugs.VerifyImageHmac do
  @moduledoc """
  Requires a valid `s` HMAC query parameter when signing keys are available
  for the request origin.

  If the origin's `/image-cache-key.json` cannot be loaded (or has no current
  key), HMAC is not required. That lets this server be deployed before the
  backends that publish keys.
  """

  import Plug.Conn
  require Logger

  alias ImageCachingServer.ImageHmac
  alias ImageCachingServer.OriginKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    url = conn.params["url"]
    width_param = conn.params["width"]
    sig = conn.params["s"]

    with true <- is_binary(url) and url != "",
         {width, _} <- parse_width(width_param) do
      verify(conn, url, width, sig)
    else
      _ ->
        # Missing/invalid url or width are handled by the controller.
        conn
    end
  end

  defp parse_width(width) when is_binary(width) do
    case Integer.parse(width) do
      {width_int, _} when width_int > 0 -> {width_int, nil}
      _ -> :error
    end
  end

  defp parse_width(_), do: :error

  defp verify(conn, url, width, sig) do
    case conn.assigns[:origin_host] do
      host when is_binary(host) ->
        verify_with_host(conn, host, url, width, sig)

      _ ->
        conn
    end
  end

  defp verify_with_host(conn, host, url, width, sig) do
    case OriginKeys.keys_for(host) do
      :not_configured ->
        conn

      {:ok, keys} ->
        if ImageHmac.valid?(sig, keys, url, width) do
          conn
        else
          reason = if is_binary(sig) and sig != "", do: "invalid", else: "missing"

          Logger.error(
            "Image HMAC #{reason}: host=#{host} url=#{url} width=#{width} ip=#{format_remote_ip(conn)}"
          )

          conn
          |> put_status(:forbidden)
          |> Phoenix.Controller.json(%{error: "Invalid image signature"})
          |> halt()
        end
    end
  end

  defp format_remote_ip(%{remote_ip: remote_ip}) do
    remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
end
