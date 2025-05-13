defmodule ImageCachingServerWeb.Plugs.VerifyOrigin do
  @moduledoc """
  Plug to verify that requests come from allowed domains.
  Checks both Origin and Referer headers.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    allowed_domains = Application.get_env(:image_caching_server, :allowed_domains, [])

    with {:ok, domain} <- extract_domain(conn),
         true <- domain_allowed?(domain, allowed_domains) do
      conn
    else
      {:error, :no_origin} ->
        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{error: "Direct access not allowed"})
        |> halt()
      false ->
        Logger.warning("Request from unauthorized domain: #{extract_domain(conn) |> elem(1)}")
        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{error: "Domain not authorized"})
        |> halt()
    end
  end

  # Extract domain from Origin or Referer header
  defp extract_domain(conn) do
    cond do
      origin = get_req_header(conn, "origin") |> List.first() ->
        {:ok, parse_domain(origin)}
      referer = get_req_header(conn, "referer") |> List.first() ->
        {:ok, parse_domain(referer)}
      true ->
        {:error, :no_origin}
    end
  end

  # Parse domain from URL
  defp parse_domain(url) do
    uri = URI.parse(url)
    # Handle both hostname and hostname:port formats
    case uri.host do
      nil -> url  # For simple domain strings
      host -> host
    end
  end

  # Check if domain is in allowed list
  defp domain_allowed?(domain, allowed_domains) do
    Enum.any?(allowed_domains, fn allowed ->
      # Allow exact matches and wildcards
      case String.split(allowed, "*", parts: 2) do
        [prefix, suffix] ->
          String.starts_with?(domain, prefix) and String.ends_with?(domain, suffix)
        [exact] ->
          domain == exact
      end
    end)
  end
end
