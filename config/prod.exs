import Config

config :logger, level: :info

config :image_caching_server, ImageCachingServerWeb.Endpoint,
  check_origin: false,
  code_reloader: false,
  debug_errors: false

config :logger, :console, format: "[$time] $message\n"

config :phoenix, :plug_init_mode, :runtime

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
