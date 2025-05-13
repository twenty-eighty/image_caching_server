defmodule ImageCachingServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :image_caching_server

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_image_caching_server_key",
    signing_salt: "your-salt-here",
    same_site: "Lax"
  ]

  # Serve at "/" the static files from "priv/static" directory.
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  # plug Plug.Static,
  #   at: "/",
  #   from: :image_caching_server,
  #   gzip: false,
  #   only: ImageCachingServerWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ImageCachingServerWeb.Router
end
