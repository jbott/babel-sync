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
      <div class="mx-auto max-w-2xl space-y-7 pb-12 pt-7 md:pb-20 md:pt-10">
        <.header>
          <:trail>
            <.back_link navigate={Paths.vault(@vault.id)}>{@vault.name}</.back_link>
          </:trail>
          Trash
          <:subtitle :if={@retention_days}>
            Deleted files are kept for {@retention_days} days.
          </:subtitle>
        </.header>

        <div
          :if={@empty?}
          id="trash-empty"
          class="rounded-xl border border-dashed border-line-strong px-6 py-14 text-center"
        >
          <.icon name="hero-trash" class="size-8 text-line-strong" />
          <p class="mt-3 text-muted">Nothing has been deleted lately.</p>
        </div>

        <.rows id="trash" phx-update="stream" class="empty:hidden">
          <li
            :for={{id, entry} <- @streams.trashed}
            id={id}
            class="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3"
          >
            <.icon
              name={if(entry.kind == :doc, do: "hero-document-text", else: "hero-paper-clip")}
              class="size-5 shrink-0 text-faint"
            />
            <div class="min-w-0 flex-1 basis-48">
              <div class="truncate font-medium text-ink">{entry.path}</div>
              <div class="text-xs tabular-nums text-faint">
                Deleted {Calendar.strftime(entry.deleted_at, "%d %b %Y %H:%M")} UTC
              </div>
            </div>
            <div :if={@writable} class="ml-auto flex items-center gap-1.5">
              <.button
                phx-click="purge"
                phx-value-id={entry.id}
                data-confirm={"Delete #{entry.path} forever?"}
                variant="danger-ghost"
                size="sm"
              >
                Delete forever
              </.button>
              <.button phx-click="restore" phx-value-id={entry.id} size="sm">
                <.icon name="hero-arrow-uturn-left-mini" class="size-4" /> Restore
              </.button>
            </div>
          </li>
        </.rows>
      </div>
    </Layouts.app>
    """
  end
end
