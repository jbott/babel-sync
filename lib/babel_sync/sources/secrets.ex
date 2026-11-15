defmodule BabelSync.Sources.Secrets do
  @moduledoc """
  Keeps the secrets sources send, encrypted under keys made from the
  server's `SECRET_KEY_BASE`, so a copy of the database alone gives none
  of them up. Each is sealed together with the source and name it was
  saved for, and does not open as any other.

  Nothing returns a secret to a person or a script once saved. It is
  opened only to be put on a request to its host.
  """

  import Ecto.Query

  alias BabelSync.Repo
  alias BabelSync.Sources.{Secret, Source}

  @spec put(Source.t(), String.t(), String.t()) :: :ok
  def put(%Source{id: source_id}, name, value) do
    now = DateTime.utc_now()
    sealed = Plug.Crypto.MessageEncryptor.encrypt(value, bound(source_id, name), key(), signing())

    Repo.insert!(
      %Secret{
        source_id: source_id,
        name: name,
        sealed: sealed,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [sealed: sealed, updated_at: now]],
      conflict_target: [:source_id, :name]
    )

    :ok
  end

  @spec delete(Source.t(), String.t()) :: :ok
  def delete(%Source{id: source_id}, name) do
    Repo.delete_all(from s in Secret, where: s.source_id == ^source_id and s.name == ^name)
    :ok
  end

  @spec names(Source.t()) :: [String.t()]
  def names(%Source{id: source_id}) do
    Repo.all(from s in Secret, where: s.source_id == ^source_id, select: s.name, order_by: s.name)
  end

  @spec open(Source.t()) :: %{String.t() => String.t()}
  def open(%Source{id: source_id}) do
    for %Secret{name: name, sealed: sealed} <-
          Repo.all(from s in Secret, where: s.source_id == ^source_id),
        {:ok, value} <- [
          Plug.Crypto.MessageEncryptor.decrypt(sealed, bound(source_id, name), key(), signing())
        ],
        into: %{},
        do: {name, value}
  end

  defp bound(source_id, name), do: source_id <> ":" <> name

  defp key, do: derived("source secrets")
  defp signing, do: derived("source secrets signing")

  defp derived(salt) do
    base = Application.fetch_env!(:babel_sync, BabelSyncWeb.Endpoint)[:secret_key_base]
    Plug.Crypto.KeyGenerator.generate(base, salt, length: 32, cache: Plug.Keys)
  end
end
