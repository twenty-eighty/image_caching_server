defmodule ImageCachingServer.CacheSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Start ConCache with TTL of 1 hour
      Supervisor.child_spec(
        {ConCache,
          [
            name: :image_cache,
            ttl_check_interval: :timer.minutes(1),
            global_ttl: :timer.hours(1),
            touch_on_read: true
          ]
        },
        id: :image_cache_ttl
      ),
      # Start size tracking cache (no TTL)
      Supervisor.child_spec(
        {ConCache,
          [
            name: :size_cache,
            ttl_check_interval: false
          ]
        },
        id: :size_cache_no_ttl
      ),
      {Task.Supervisor, name: ImageCachingServer.ImageTaskSupervisor},
      # Start the Image Cache GenServer
      {ImageCachingServer.ImageCache, []}
    ]

    # Restart all children if any fails
    Supervisor.init(children, strategy: :one_for_all)
  end
end
