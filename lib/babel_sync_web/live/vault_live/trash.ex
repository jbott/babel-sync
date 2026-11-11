defmodule BabelSyncWeb.VaultLive.Trash do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.Vaults
  alias BabelSync.Vaults.{Entry, Vault}
  alias BabelSyncWeb.Paths

  @impl true
  def mount(%{"vault_id" => vault_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         %Vault{} = vault <- Vaults.get_vault(vault_id) do
      if connected?(socket), do: Vaults.subscribe(vault_id)

      {:ok,
       socket
       |> assign(:page_title, "#{vault.name} trash")
       |> assign(:vault, vault)
       |> assign(:writable, Scope.authorize(scope, vault_id, :write) == :ok)
       |> assign(:retention_days, retention_days())
       |> load()}
    else
      _denied -> {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp load(socket) do
    trashed = Vaults.list_trash(socket.assigns.vault.id)
    socket |> assign(:empty?, trashed == []) |> stream(:trashed, trashed, reset: true)
  end

  @impl true
  def handle_event("restore", %{"id" => id}, socket) do
    change(socket, id, fn entry ->
      case Vaults.restore_entry(entry) do
        {:ok, restored} -> put_flash(socket, :info, "Restored to #{restored.path}.")
        {:error, :not_found} -> socket
      end
    end)
  end

  def handle_event("purge", %{"id" => id}, socket) do
    change(socket, id, fn entry ->
      :ok = Vaults.purge_entry(entry)
      socket
    end)
  end

  defp change(%{assigns: %{writable: false}} = socket, _id, _action) do
    {:noreply, put_flash(socket, :error, "You can only read this vault.")}
  end

  defp change(socket, id, action) do
    case Vaults.get_trashed(socket.assigns.vault.id, id) do
      %Entry{} = entry -> {:noreply, entry |> action.() |> load()}
      nil -> {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_info({:entry_changed, %Entry{}}, socket), do: {:noreply, load(socket)}

  defp retention_days do
    case Application.fetch_env!(:babel_sync, BabelSync.Janitor)[:retention_days] do
      days when is_integer(days) and days > 0 -> days
      _forever -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl px-4 py-10 space-y-6">
        <.header>
          Trash
          <:subtitle>
            <.link navigate={Paths.vault(@vault.id)} class="link">{@vault.name}</.link>
            <span :if={@retention_days}>
              · deleted files are kept for {@retention_days} days
            </span>
          </:subtitle>
        </.header>

        <p :if={@empty?} id="trash-empty" class="text-sm text-base-content/60">
          Nothing has been deleted lately.
        </p>

        <ul
          id="trash"
          phx-update="stream"
          class="divide-y divide-base-300 rounded-box border border-base-300 empty:hidden"
        >
          <li
            :for={{id, entry} <- @streams.trashed}
            id={id}
            class="flex items-center gap-3 px-4 py-3 transition hover:bg-base-200/60"
          >
            <.icon
              name={if(entry.kind == :doc, do: "hero-document-text", else: "hero-paper-clip")}
              class="size-5 shrink-0 text-base-content/50"
            />
            <div class="min-w-0 flex-1">
              <div class="truncate font-medium">{entry.path}</div>
              <div class="text-xs text-base-content/50">
                Deleted {Calendar.strftime(entry.deleted_at, "%d %b %Y %H:%M")} UTC
              </div>
            </div>
            <button
              :if={@writable}
              phx-click="restore"
              phx-value-id={entry.id}
              class="btn btn-sm transition hover:-translate-y-px"
            >
              Restore
            </button>
            <button
              :if={@writable}
              phx-click="purge"
              phx-value-id={entry.id}
              data-confirm={"Delete #{entry.path} forever?"}
              class="btn btn-ghost btn-sm text-error"
            >
              Delete forever
            </button>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
