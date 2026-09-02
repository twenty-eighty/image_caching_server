defmodule ImageCachingServer.OriginKeys do
  @moduledoc """
  Loads HMAC keys for an allowlisted request host.

  Production hosts are fetched from `https://{host}/image-cache-key.json`.
  Localhost uses `IMAGE_CACHE_KEY` / `IMAGE_CACHE_KEY_PREVIOUS` so a remote
  cache server is not asked to fetch the developer's browser origin.
  """

  use GenServer
  require Logger

  @success_ttl_ms :timer.seconds(120)
  @failure_ttl_ms :timer.seconds(30)
  @host_re ~r/\A[a-zA-Z0-9.-]+\z/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec keys_for(String.t()) :: {:ok, %{current: String.t(), previous: String.t() | nil}} | :not_configured
  def keys_for(host) when is_binary(host) do
    GenServer.call(__MODULE__, {:keys_for, host})
  end

  def clear_cache do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:keys_for, host}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state, host) do
      %{expires_at: expires_at, result: result} when expires_at > now ->
        {:reply, result, state}

      _ ->
        {result, ttl} = load_keys(host)
        entry = %{result: result, expires_at: now + ttl}
        {:reply, result, Map.put(state, host, entry)}
    end
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{}}
  end

  defp load_keys(host) do
    cond do
      local_host?(host) ->
        wrap_fallback()

      not Regex.match?(@host_re, host) ->
        Logger.error("Refusing to fetch image cache keys for invalid host=#{host}")
        {:not_configured, @failure_ttl_ms}

      true ->
        case fetch_origin_keys(host) do
          {:ok, keys} ->
            {{:ok, keys}, @success_ttl_ms}

          :error ->
            Logger.warning(
              "Image cache keys unavailable for host=#{host}; HMAC will not be required"
            )

            {:not_configured, @failure_ttl_ms}
        end
    end
  end

  defp wrap_fallback do
    case fallback_keys() do
      {:ok, keys} -> {{:ok, keys}, @success_ttl_ms}
      :error -> {:not_configured, @failure_ttl_ms}
    end
  end

  defp local_host?(host), do: host in ["localhost", "127.0.0.1"]

  defp fetch_origin_keys(host) do
    url = "https://#{host}/image-cache-key.json"

    case Req.get(url, max_redirects: 0, receive_timeout: 5_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_keys(body)

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Image cache key fetch failed: host=#{host} status=#{status}")
        :error

      {:error, reason} ->
        Logger.warning("Image cache key fetch failed: host=#{host} reason=#{inspect(reason)}")
        :error
    end
  end

  defp parse_keys(%{"current" => current} = body) when is_binary(current) and current != "" do
    previous =
      case Map.get(body, "previous") do
        prev when is_binary(prev) and prev != "" -> prev
        _ -> nil
      end

    {:ok, %{current: current, previous: previous}}
  end

  defp parse_keys(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_keys(decoded)
      {:error, _} -> :error
    end
  end

  defp parse_keys(_), do: :error

  defp fallback_keys do
    current = nonempty_env("IMAGE_CACHE_KEY")

    case current do
      nil ->
        :error

      key ->
        {:ok, %{current: key, previous: nonempty_env("IMAGE_CACHE_KEY_PREVIOUS")}}
    end
  end

  defp nonempty_env(name) do
    case System.get_env(name, "") do
      "" -> nil
      value -> value
    end
  end
end
