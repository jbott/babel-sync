defmodule BabelSync.Fixtures do
  @moduledoc """
  Builds users, vaults and entries for tests.
  """

  alias BabelSync.{Accounts, Vaults}

  def user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(Map.merge(%{email: "user#{unique}@example.com"}, attrs))
    user
  end

  def vault(owner \\ user(), attrs \\ %{}) do
    {:ok, vault} = Vaults.create_vault(owner, Map.merge(%{name: "Notes"}, attrs))
    vault
  end

  def entry(vault, path, attrs \\ %{}) do
    {:ok, entry} = Vaults.create_entry(vault.id, Map.put(attrs, :path, path))
    entry
  end

  def client_doc(client_id) do
    doc = Yex.Doc.with_options(%Yex.Doc.Options{client_id: client_id})
    {doc, Yex.Doc.get_text(doc, "content")}
  end
end
