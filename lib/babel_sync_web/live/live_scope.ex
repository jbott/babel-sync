defmodule BabelSyncWeb.LiveScope do
  @moduledoc false

  import Phoenix.Component, only: [assign_new: 3]

  alias BabelSync.Auth
  alias BabelSyncWeb.Plugs.Scope

  def on_mount(:require, _params, session, socket) do
    socket =
      assign_new(socket, :current_scope, fn ->
        case Auth.scope_from_token(session[Scope.session_key()]) do
          {:ok, scope} -> scope
          :error -> nil
        end
      end)

    if socket.assigns.current_scope,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
  end
end
