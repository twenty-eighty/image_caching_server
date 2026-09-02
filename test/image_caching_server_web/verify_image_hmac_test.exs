defmodule ImageCachingServerWeb.VerifyImageHmacTest do
  use ImageCachingServerWeb.ConnCase, async: false

  alias ImageCachingServer.ImageHmac
  alias ImageCachingServer.OriginKeys

  @url "https://example.com/a.jpg"
  @current "test-current-key"
  @previous "test-previous-key"

  setup do
    previous_current = System.get_env("IMAGE_CACHE_KEY")
    previous_previous = System.get_env("IMAGE_CACHE_KEY_PREVIOUS")

    System.put_env("IMAGE_CACHE_KEY", @current)
    System.put_env("IMAGE_CACHE_KEY_PREVIOUS", @previous)
    OriginKeys.clear_cache()

    on_exit(fn ->
      restore_env("IMAGE_CACHE_KEY", previous_current)
      restore_env("IMAGE_CACHE_KEY_PREVIOUS", previous_previous)
      OriginKeys.clear_cache()
    end)

    :ok
  end

  test "rejects scale requests without an HMAC when keys are configured", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:1234")
      |> get("/api/scale", %{url: @url, width: "640"})

    assert json_response(conn, 403) == %{"error" => "Invalid image signature"}
  end

  test "rejects scale requests with an invalid HMAC", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:1234")
      |> get("/api/scale", %{url: @url, width: "640", s: String.duplicate("a", 64)})

    assert json_response(conn, 403) == %{"error" => "Invalid image signature"}
  end

  test "loads localhost keys from IMAGE_CACHE_KEY env" do
    assert {:ok, %{current: @current, previous: @previous}} = OriginKeys.keys_for("localhost")
    assert ImageHmac.valid?(ImageHmac.sign(@previous, @url, 640), %{current: @current, previous: @previous}, @url, 640)
  end

  test "does not expect HMAC when origin keys cannot be loaded" do
    System.delete_env("IMAGE_CACHE_KEY")
    System.delete_env("IMAGE_CACHE_KEY_PREVIOUS")
    OriginKeys.clear_cache()

    conn =
      build_conn()
      |> Map.put(:params, %{"url" => @url, "width" => "640"})
      |> assign(:origin_host, "localhost")
      |> ImageCachingServerWeb.Plugs.VerifyImageHmac.call([])

    refute conn.halted
    refute conn.status == 403
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
