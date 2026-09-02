defmodule ImageCachingServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    configure_imagemagick_limits()

    children = [
      # Start the PubSub system
      {Phoenix.PubSub, name: ImageCachingServer.PubSub},
      ImageCachingServer.OriginKeys,
      # Start the Cache Supervisor
      ImageCachingServer.CacheSupervisor,
      # Start the Endpoint (http/https)
      ImageCachingServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ImageCachingServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImageCachingServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Inherited by `convert`/`identify` OS processes. Sized for a 512MB VM:
  # one convert at 64MB RAM, overflow to disk, never two jobs at once.
  defp configure_imagemagick_limits do
    Enum.each(
      [
        {"MAGICK_MEMORY_LIMIT", "64MB"},
        {"MAGICK_MAP_LIMIT", "64MB"},
        {"MAGICK_DISK_LIMIT", "256MB"},
        {"MAGICK_AREA_LIMIT", "16MP"},
        {"MAGICK_WIDTH_LIMIT", "8192"},
        {"MAGICK_HEIGHT_LIMIT", "8192"},
        {"MAGICK_THREAD_LIMIT", "1"},
        {"MAGICK_TIME_LIMIT", "15"}
      ],
      fn {key, default} ->
        case System.get_env(key) do
          value when value in [nil, ""] -> System.put_env(key, default)
          _ -> :ok
        end
      end
    )
  end
end
