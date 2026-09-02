defmodule ImageCachingServer.ImageHmacTest do
  use ExUnit.Case, async: true

  alias ImageCachingServer.ImageHmac

  @url "https://example.com/a.jpg"
  @width 640
  @current "test-current-key"
  @previous "test-previous-key"

  test "signs the canonical url and width message" do
    expected =
      :crypto.mac(:hmac, :sha256, @current, @url <> "\n640")
      |> Base.encode16(case: :lower)

    assert ImageHmac.sign(@current, @url, @width) == expected
    assert String.length(expected) == 64
  end

  test "accepts HMAC from the current or previous key" do
    keys = %{current: @current, previous: @previous}

    assert ImageHmac.valid?(ImageHmac.sign(@current, @url, @width), keys, @url, @width)
    assert ImageHmac.valid?(ImageHmac.sign(@previous, @url, @width), keys, @url, @width)
  end

  test "rejects missing, truncated, and wrong signatures" do
    keys = %{current: @current, previous: @previous}
    good = ImageHmac.sign(@current, @url, @width)

    refute ImageHmac.valid?(nil, keys, @url, @width)
    refute ImageHmac.valid?("", keys, @url, @width)
    refute ImageHmac.valid?(String.slice(good, 0, 32), keys, @url, @width)
    refute ImageHmac.valid?(ImageHmac.sign(@current, @url, 320), keys, @url, @width)
    refute ImageHmac.valid?(ImageHmac.sign("other-key", @url, @width), keys, @url, @width)
  end
end
