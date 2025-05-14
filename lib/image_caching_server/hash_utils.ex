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
  """
  @spec extract_hash_from_path(String.t()) :: String.t()
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
  """
  @spec etag_from_path(String.t()) :: String.t()
  def etag_from_path(path) do
    case extract_hash_from_path(path) do
      nil -> nil
      hash -> ~s("#{hash}")
    end
  end

  @doc """
  Check if a given hash string is likely an MD5 hash.
  MD5 hashes are 32 characters long, SHA256 are 64 characters.
  Used during cache initialization to clear old files.
  """
  @spec is_md5_hash?(String.t()) :: boolean()
  def is_md5_hash?(hash) when is_binary(hash) do
    String.length(hash) == 32 && String.match?(hash, ~r/^[a-f0-9]{32}$/i)
  end

  @doc """
  Find a file in the cache directory by its content hash.
  Checks both MD5 and SHA256 hashes to support migration period.
  """
  @spec find_file_by_hash(String.t(), String.t(), boolean()) :: {:ok, String.t()} | :not_found
  def find_file_by_hash(cache_dir, url, is_scaled \\ false) do
    # Generate both hash types
    sha256_hash = hash_string(url)
    md5_hash = :crypto.hash(:md5, url) |> Base.encode16()

    prefix = if is_scaled, do: "scaled_", else: ""

    # List all matching files
    with {:ok, files} <- File.ls(cache_dir) do
      matching_file = files
        |> Enum.find(fn file ->
          # Match either hash type
          (String.starts_with?(file, prefix <> sha256_hash) ||
           String.starts_with?(file, prefix <> md5_hash)) &&
          # Ensure we're matching the right type (scaled or original)
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

  @doc """
  Migrate a file from MD5 to SHA256 hash if needed.
  Returns the path to the SHA256 version of the file.
  """
  @spec ensure_sha256_hash(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure_sha256_hash(current_path, url, cache_dir) do
    current_hash = extract_hash_from_path(current_path)

    if current_hash && is_md5_hash?(current_hash) do
      # This is an MD5 hash, migrate to SHA256
      new_hash = hash_string(url)
      extension = Path.extname(current_path)
      is_scaled = String.contains?(current_path, "scaled_")
      prefix = if is_scaled, do: "scaled_", else: ""
      new_path = Path.join(cache_dir, "#{prefix}#{new_hash}#{extension}")

      Logger.info("Migrating cache file from MD5 to SHA256: #{Path.basename(current_path)} -> #{Path.basename(new_path)}")

      try do
        case File.copy(current_path, new_path) do
          {:ok, _} ->
            # Successfully copied, now remove the old file
            _ = File.rm(current_path)
            {:ok, new_path}
          {:error, reason} ->
            {:error, "Failed to migrate cache file: #{inspect(reason)}"}
        end
      rescue
        e -> {:error, "Failed to migrate cache file: #{inspect(e)}"}
      end
    else
      # Already using SHA256 or unknown hash
      {:ok, current_path}
    end
  end
end
