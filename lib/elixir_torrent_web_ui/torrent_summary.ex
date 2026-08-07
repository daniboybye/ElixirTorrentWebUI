defmodule ElixirTorrentWebUI.TorrentSummary do
  @moduledoc false

  # Turns a .torrent file's raw bytes (or the temp path from a Phoenix upload)
  # into the small map the bug-report form embeds. Parsing is delegated to the
  # engine's Torrent.parse_file!/1 so we track the same UTI/bencoding rules
  # the running client does.

  @type t :: %{
          name: String.t(),
          info_hash_hex: String.t(),
          size_bytes: non_neg_integer() | nil,
          magnet: String.t()
        }

  @spec from_path(Path.t()) :: {:ok, t()} | {:error, term()}
  def from_path(path) when is_binary(path) do
    torrent = Torrent.parse_file!(path)

    name = get_in(torrent.metadata, ["info", "name"]) || Path.basename(path)
    info_hash_hex = Torrent.hex_encoded_hash(torrent.hash)
    size_bytes = total_size(torrent.metadata)

    {:ok,
     %{
       name: to_string(name),
       info_hash_hex: info_hash_hex,
       size_bytes: size_bytes,
       magnet: magnet_uri(info_hash_hex, name)
     }}
  rescue
    error -> {:error, error}
  end

  @spec magnet_uri(String.t(), String.t()) :: String.t()
  def magnet_uri(info_hash_hex, name) when is_binary(info_hash_hex) and is_binary(name) do
    "magnet:?xt=urn:btih:#{String.downcase(info_hash_hex)}&dn=#{URI.encode_www_form(name)}"
  end

  @spec total_size(map()) :: non_neg_integer() | nil
  def total_size(%{"info" => %{"length" => length}}) when is_integer(length) and length >= 0,
    do: length

  def total_size(%{"info" => %{"files" => files}}) when is_list(files) do
    Enum.reduce_while(files, 0, fn
      %{"length" => length}, acc when is_integer(length) and length >= 0 -> {:cont, acc + length}
      _, _ -> {:halt, nil}
    end)
  end

  def total_size(_metadata), do: nil
end
