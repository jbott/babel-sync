defmodule BabelSync.Vaults.Path do
  @moduledoc """
  Vault-relative paths: forward slashes, NFC, no leading slash, and no
  segment that could escape the vault.
  """

  @doc_extensions ~w(.md .markdown .txt)
  @max_bytes 1024

  @spec normalize(String.t()) :: String.t()
  def normalize(path) do
    path
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> Enum.join("/")
    |> :unicode.characters_to_nfc_binary()
  end

  @spec valid?(String.t()) :: boolean()
  def valid?(path) do
    segments = String.split(path, "/")

    path != "" and byte_size(path) <= @max_bytes and String.valid?(path) and
      not String.contains?(path, <<0>>) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  @spec kind_for(String.t()) :: :doc | :blob
  def kind_for(path) do
    if String.downcase(Path.extname(path)) in @doc_extensions, do: :doc, else: :blob
  end
end
