defmodule ImageCachingServerWeb.HealthController do
  use ImageCachingServerWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
