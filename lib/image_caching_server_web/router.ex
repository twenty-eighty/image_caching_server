defmodule ImageCachingServerWeb.Router do
  use ImageCachingServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ImageCachingServerWeb do
    pipe_through :api

    get "/scale", ImageController, :scale
  end
end
