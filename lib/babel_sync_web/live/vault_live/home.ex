defmodule BabelSyncWeb.VaultLive.Home do
  @moduledoc """
  Sends a signed-in person to their first vault by name, or to the account
  page, where vaults are created, when they have none.
  """
  use BabelSyncWeb, :live_view

  alias BabelSync.Vaults
  alias BabelSyncWeb.Paths

  @impl true
  def mount(_params, _session, socket) do
    destination =
      case Vaults.list_vaults(socket.assigns.current_scope.user) do
        [first | _rest] -> Paths.vault(first.id)
        [] -> ~p"/account"
      end

    {:ok, push_navigate(socket, to: destination)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} masthead={false}>
      <span></span>
    </Layouts.app>
    """
  end
end
