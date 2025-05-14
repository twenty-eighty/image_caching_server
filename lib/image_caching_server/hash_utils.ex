defmodule ImageCachingServer.HashUtils do
  @moduledoc """
  Utilities for consistent hashing across the application.
  Uses SHA256 for all hashing needs.
  """
  require Logger

  @doc """
  Generate a hash for a string value.
  Returns a hex-encoded string of the SHA256 hash.
  """
  @spec hash_string(String.t()) :: String.t()
  def hash_string(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Generate an HTTP ETag from a binary value.
  Returns a quoted string containing the hex-encoded SHA256 hash.
  """
  @spec generate_etag(binary()) :: String.t()
  def generate_etag(data) when is_binary(data) do
    ~s("#{hash_string(data)}")
  end

  @doc """
  Extract the hash from a cached file path.
  For original files, returns the hash portion of the filename.
  For scaled files, returns the hash portion after "scaled_".
  Returns nil if the path doesn't match expected patterns.
  """
  @spec extract_hash_from_path(String.t()) :: String.t() | nil
  def extract_hash_from_path(path) do
    filename = Path.basename(path)
    case String.split(filename, ".") do
      [hash, _ext] -> hash
      ["scaled_" <> rest, _ext] -> String.split(rest, ".") |> hd()
      _ -> nil
    end
  end

  @doc """
  Generate an ETag from a cached file path.
  This is more efficient than reading and hashing the file contents
  since we use content-addressed storage.
  Returns nil if the path doesn't contain a valid hash.
  """
  @spec etag_from_path(String.t()) :: String.t() | nil
  def etag_from_path(path) do
    case extract_hash_from_path(path) do
      nil -> nil
      hash -> ~s("#{hash}")
    end
  end

  @doc """
  Find a file in the cache directory by its content hash.
  """
  @spec find_file_by_hash(String.t(), String.t(), boolean()) :: {:ok, String.t()} | :not_found
  def find_file_by_hash(cache_dir, url, is_scaled \\ false) do
    hash = hash_string(url)
    prefix = if is_scaled, do: "scaled_", else: ""

    with {:ok, files} <- File.ls(cache_dir) do
      matching_file = files
        |> Enum.find(fn file ->
          String.starts_with?(file, prefix <> hash) &&
          (if is_scaled, do: String.starts_with?(file, "scaled_"), else: !String.starts_with?(file, "scaled_"))
        end)

      case matching_file do
        nil -> :not_found
        file -> {:ok, Path.join(cache_dir, file)}
      end
    else
      _ -> :not_found
    end
  end


end
