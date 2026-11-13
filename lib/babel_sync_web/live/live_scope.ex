defmodule BabelSyncWeb.LiveScope do
  @moduledoc false

  import Phoenix.Component, only: [assign_new: 3]

  alias BabelSync.Auth
  alias BabelSyncWeb.Plugs.Scope

  def on_mount(:require, _params, session, socket) do
    socket = fetch(socket, session)

    if socket.assigns.current_scope,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
  end

  def on_mount(:signed_out, _params, session, socket) do
    socket = fetch(socket, session)

    if socket.assigns.current_scope,
      do: {:halt, Phoenix.LiveView.redirect(socket, to: "/")},
      else: {:cont, socket}
  end

  defp fetch(socket, session) do
    socket
    |> assign_new(:current_scope, fn ->
      case Auth.scope_from_session(session[Scope.session_key()]) do
        {:ok, scope} -> scope
        :error -> nil
      end
    end)
    |> announce_new_assets()
  end

  defp announce_new_assets(socket) do
    if Phoenix.LiveView.connected?(socket) and Phoenix.LiveView.static_changed?(socket),
      do: Phoenix.LiveView.push_event(socket, "assets-changed", %{}),
      else: socket
  end
end
