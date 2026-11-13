defmodule BabelSyncWeb.VaultController do
  use BabelSyncWeb, :controller

  alias BabelSync.Vaults

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    user = scope.user

    vaults =
      for vault <- BabelSync.Accounts.Scope.vaults(scope) do
        %{
          id: vault.id,
          name: vault.name,
          role: Vaults.role(user, vault.id),
          files: Vaults.count_files(vault.id)
        }
      end

    json(conn, %{vaults: vaults})
  end
end
