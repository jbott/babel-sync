defmodule BabelSyncWeb.UserSocket do
  use Phoenix.Socket

  channel "vault:*", BabelSyncWeb.VaultChannel
  channel "doc:*", BabelSyncWeb.DocChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case BabelSync.Auth.scope_from_token(params["token"]) do
      {:ok, scope} -> {:ok, assign(socket, :scope, scope)}
      :error -> :error
    end
  end

  @impl true
  def id(socket), do: BabelSync.Accounts.Scope.socket_topic(socket.assigns.scope)
end
