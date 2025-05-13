# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :image_caching_server,
  generators: [timestamp_type: :utc_datetime]

# Configure your endpoint
config :image_caching_server, ImageCachingServerWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: ImageCachingServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ImageCachingServer.PubSub,
  live_view: [signing_salt: "your-salt-here"]



# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :image_caching_server, ImageCachingServer.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :console,
  format: "[$time] $message\n",
  level: :info,
  colors: [
    info: :green,
    warning: :yellow,
    error: :red
  ]

# Configure allowed domains for image requests
config :image_caching_server,
  allowed_domains: String.split(System.get_env("ALLOWED_DOMAINS", "localhost,127.0.0.1"), ",")

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
