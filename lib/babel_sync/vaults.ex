defmodule BabelSync.Vaults do
  @moduledoc """
  Vaults, who may access them, and the tree of entries inside each one.

  Every change to a vault's tree takes the next value of the vault's `seq`
  counter, so a client that remembers the last `seq` it saw can ask for
  exactly what changed since.
  """

  import Ecto.Query

  alias BabelSync.Accounts.User
  alias BabelSync.Repo
  alias BabelSync.Vaults.{Entry, Member, Vault}

  @type access :: :read | :write | :admin

  @spec create_vault(User.t(), map()) :: {:ok, Vault.t()} | {:error, Ecto.Changeset.t()}
  def create_vault(%User{} = user, attrs) do
    Repo.transact(fn ->
      with {:ok, vault} <- %Vault{} |> Vault.changeset(attrs) |> Repo.insert(),
           {:ok, _member} <- put_member(vault, user, :owner) do
        {:ok, vault}
      end
    end)
  end

  @spec list_vaults(User.t()) :: [Vault.t()]
  def list_vaults(%User{id: user_id}) do
    Repo.all(
      from v in Vault,
        join: m in Member,
        on: m.vault_id == v.id,
        where: m.user_id == ^user_id,
        order_by: v.name
    )
  end

  @spec get_vault(Ecto.UUID.t()) :: Vault.t() | nil
  def get_vault(id), do: Repo.get(Vault, id)

  @spec update_vault(Vault.t(), map()) :: {:ok, Vault.t()} | {:error, Ecto.Changeset.t()}
  def update_vault(%Vault{} = vault, attrs) do
    vault |> Vault.changeset(attrs) |> Repo.update()
  end

  @spec delete_vault(Vault.t()) :: {:ok, Vault.t()} | {:error, Ecto.Changeset.t()}
  def delete_vault(%Vault{} = vault), do: Repo.delete(vault)

  @spec put_member(Vault.t(), User.t(), Member.role()) ::
          {:ok, Member.t()} | {:error, Ecto.Changeset.t()}
  def put_member(%Vault{id: vault_id}, %User{id: user_id}, role) do
    member = Repo.get_by(Member, vault_id: vault_id, user_id: user_id)

    (member || %Member{vault_id: vault_id, user_id: user_id})
    |> Member.changeset(%{role: role})
    |> Repo.insert_or_update()
  end

  @spec remove_member(Vault.t(), User.t()) :: :ok
  def remove_member(%Vault{id: vault_id}, %User{id: user_id}) do
    Repo.delete_all(from m in Member, where: m.vault_id == ^vault_id and m.user_id == ^user_id)
    :ok
  end

  @spec list_members(Vault.t()) :: [Member.t()]
  def list_members(%Vault{id: vault_id}) do
    Repo.all(from m in Member, where: m.vault_id == ^vault_id, preload: :user)
  end

  @spec role(User.t(), Ecto.UUID.t()) :: Member.role() | nil
  def role(%User{id: user_id}, vault_id) do
    Repo.one(
      from m in Member,
        where: m.vault_id == ^vault_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  @spec authorize(User.t(), Ecto.UUID.t(), access()) :: :ok | {:error, :forbidden}
  def authorize(%User{} = user, vault_id, access) do
    if allows?(role(user, vault_id), access), do: :ok, else: {:error, :forbidden}
  end

  defp allows?(:owner, _access), do: true
  defp allows?(:editor, access), do: access in [:read, :write]
  defp allows?(:viewer, access), do: access == :read
  defp allows?(nil, _access), do: false

  @spec get_entry(Ecto.UUID.t()) :: Entry.t() | nil
  def get_entry(id), do: Repo.get(Entry, id)

  @spec get_entry_by_path(Ecto.UUID.t(), String.t()) :: Entry.t() | nil
  def get_entry_by_path(vault_id, path) do
    path = BabelSync.Vaults.Path.normalize(path)

    Repo.one(
      from e in Entry,
        where: e.vault_id == ^vault_id and e.path == ^path and is_nil(e.deleted_at)
    )
  end

  @spec list_entries(Ecto.UUID.t()) :: [Entry.t()]
  def list_entries(vault_id) do
    Repo.all(
      from e in Entry,
        where: e.vault_id == ^vault_id and is_nil(e.deleted_at),
        order_by: e.path
    )
  end

  @spec changes_since(Ecto.UUID.t(), non_neg_integer()) :: [Entry.t()]
  def changes_since(vault_id, seq) do
    Repo.all(
      from e in Entry,
        where: e.vault_id == ^vault_id and e.seq > ^seq,
        order_by: e.seq
    )
  end

  @spec create_entry(Ecto.UUID.t(), map()) ::
          {:ok, Entry.t()} | {:error, {:exists, Entry.t()}} | {:error, Ecto.Changeset.t()}
  def create_entry(vault_id, attrs) do
    attrs = Map.put_new_lazy(attrs, :kind, fn -> BabelSync.Vaults.Path.kind_for(attrs.path) end)

    result =
      Repo.transact(fn ->
        seq = next_seq(vault_id)

        case get_entry_by_path(vault_id, attrs.path) do
          %Entry{} = existing ->
            {:error, {:exists, existing}}

          nil ->
            %Entry{vault_id: vault_id, seq: seq}
            |> Entry.changeset(attrs)
            |> Repo.insert()
        end
      end)

    announce(result)
  end

  @spec update_entry(Entry.t(), map()) ::
          {:ok, Entry.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def update_entry(%Entry{} = entry, attrs) do
    entry
    |> change(fn current, seq ->
      current
      |> Entry.changeset(attrs)
      |> Ecto.Changeset.put_change(:seq, seq)
      |> Repo.update()
    end)
    |> announce()
  end

  @spec rename_entry(Entry.t(), String.t()) ::
          {:ok, [Entry.t()]}
          | {:error, :not_found}
          | {:error, {:exists, Entry.t()}}
          | {:error, Ecto.Changeset.t()}
  def rename_entry(%Entry{} = entry, new_path) do
    new_path = BabelSync.Vaults.Path.normalize(new_path)

    entry
    |> change(fn current, seq ->
      case get_entry_by_path(current.vault_id, new_path) do
        %Entry{id: id} = existing when id != current.id ->
          {:error, {:exists, existing}}

        _none_or_self ->
          [{current, seq} | with_seqs(descendants(current))]
          |> Enum.reduce_while({:ok, []}, fn {moving, seq}, {:ok, moved} ->
            target = new_path <> String.replace_prefix(moving.path, current.path, "")

            moving
            |> Entry.changeset(%{path: target})
            |> Ecto.Changeset.put_change(:seq, seq)
            |> Repo.update()
            |> case do
              {:ok, updated} -> {:cont, {:ok, [updated | moved]}}
              {:error, changeset} -> {:halt, {:error, changeset}}
            end
          end)
      end
    end)
    |> announce_all()
  end

  @spec delete_entry(Entry.t()) :: {:ok, [Entry.t()]} | {:error, :not_found}
  def delete_entry(%Entry{} = entry) do
    now = DateTime.utc_now()

    entry
    |> change(fn current, seq ->
      deleted =
        for {doomed, seq} <- [{current, seq} | with_seqs(descendants(current))] do
          doomed
          |> Ecto.Changeset.change(deleted_at: now, seq: seq)
          |> Repo.update!()
        end

      {:ok, deleted}
    end)
    |> announce_all()
  end

  defp change(%Entry{id: id, vault_id: vault_id}, fun) do
    Repo.transact(fn ->
      seq = next_seq(vault_id)

      case Repo.get(Entry, id) do
        %Entry{deleted_at: nil} = current -> fun.(current, seq)
        _gone -> {:error, :not_found}
      end
    end)
  end

  defp with_seqs(entries), do: Enum.map(entries, &{&1, next_seq(&1.vault_id)})

  @spec subscribe(Ecto.UUID.t()) :: :ok
  def subscribe(vault_id), do: Phoenix.PubSub.subscribe(BabelSync.PubSub, topic(vault_id))

  defp descendants(%Entry{kind: :folder, vault_id: vault_id, path: path}) do
    prefix = path <> "/"

    Repo.all(from e in Entry, where: e.vault_id == ^vault_id and is_nil(e.deleted_at))
    |> Enum.filter(&String.starts_with?(&1.path, prefix))
  end

  defp descendants(%Entry{}), do: []

  defp next_seq(vault_id) do
    {1, [seq]} =
      Repo.update_all(
        from(v in Vault, where: v.id == ^vault_id, select: v.seq),
        inc: [seq: 1]
      )

    seq
  end

  defp announce({:ok, %Entry{} = entry} = result) do
    broadcast(entry)
    result
  end

  defp announce(error), do: error

  defp announce_all({:ok, entries} = result) do
    Enum.each(entries, &broadcast/1)
    result
  end

  defp announce_all(error), do: error

  defp broadcast(%Entry{} = entry) do
    Phoenix.PubSub.broadcast(BabelSync.PubSub, topic(entry.vault_id), {:entry_changed, entry})
  end

  defp topic(vault_id), do: "vault:" <> vault_id
end
