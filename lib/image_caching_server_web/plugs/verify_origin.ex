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

    with {:ok, domain, _headers} <- extract_domain(conn),
         true <- domain_allowed?(domain, allowed_domains) do
      conn
    else
      {:error, :no_origin} ->
        # Log attempt to access without origin/referer
        Logger.error("Direct access attempt without Origin/Referer headers: " <>
          "path=#{conn.request_path}, ip=#{format_remote_ip(conn)}")
        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{error: "Direct access not allowed"})
        |> halt()
      false ->
        # Get both headers for logging
        {domain, headers} = case extract_domain(conn) do
          {:ok, d, h} -> {d, h}
          _ -> {"unknown", %{}}
        end

        # Log unauthorized access with all available context
        Logger.error("Unauthorized domain access attempt: " <>
          "domain=#{domain}, " <>
          "origin=#{headers[:origin] || "none"}, " <>
          "referer=#{headers[:referer] || "none"}, " <>
          "path=#{conn.request_path}, " <>
          "ip=#{format_remote_ip(conn)}")

        conn
        |> put_status(:forbidden)
        |> Phoenix.Controller.json(%{error: "Domain not authorized"})
        |> halt()
    end
  end

  # Extract domain from Origin or Referer header
  defp extract_domain(conn) do
    headers = %{
      origin: get_req_header(conn, "origin") |> List.first(),
      referer: get_req_header(conn, "referer") |> List.first()
    }

    cond do
      headers.origin ->
        {:ok, parse_domain(headers.origin), headers}
      headers.referer ->
        {:ok, parse_domain(headers.referer), headers}
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

  # Format remote IP address for logging
  defp format_remote_ip(%{remote_ip: remote_ip}) do
    remote_ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end
end
