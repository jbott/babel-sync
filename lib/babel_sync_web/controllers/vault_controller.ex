defmodule BabelSyncWeb.VaultController do
  use BabelSyncWeb, :controller

  alias BabelSync.Vaults

  def index(conn, _params) do
    user = conn.assigns.current_scope.user

    vaults =
      for vault <- Vaults.list_vaults(user) do
        %{id: vault.id, name: vault.name, role: Vaults.role(user, vault.id)}
      end

    json(conn, %{vaults: vaults})
  end
end
