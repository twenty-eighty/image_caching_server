defmodule ImageCachingServer.ImageHmac do
  @moduledoc """
  HMAC-SHA256 for `/api/scale` query parameters.

  Canonical message is `url <> "\\n" <> Integer.to_string(width)` using the
  decoded image URL and the width as a decimal integer.
  """

  @spec sign(String.t(), String.t(), pos_integer()) :: String.t()
  def sign(key, url, width) when is_binary(key) and is_binary(url) and is_integer(width) and width > 0 do
    :crypto.mac(:hmac, :sha256, key, url <> "\n" <> Integer.to_string(width))
    |> Base.encode16(case: :lower)
  end

  @spec valid?(String.t() | nil, map(), String.t(), pos_integer()) :: boolean()
  def valid?(sig, keys, url, width) when is_binary(url) and is_integer(width) do
    case normalize_sig(sig) do
      nil ->
        false

      given ->
        keys
        |> key_list()
        |> Enum.any?(fn key ->
          Plug.Crypto.secure_compare(sign(key, url, width), given)
        end)
    end
  end

  defp normalize_sig(sig) when is_binary(sig) and byte_size(sig) == 64 do
    downcased = String.downcase(sig)

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, downcased) do
      downcased
    else
      nil
    end
  end

  defp normalize_sig(_), do: nil

  defp key_list(%{current: current, previous: previous}) do
    [current, previous]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end
end
