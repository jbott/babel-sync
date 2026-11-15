defmodule BabelSyncWeb.VaultLive.SourceNotes do
  use BabelSyncWeb, :live_view

  import BabelSyncWeb.SourceComponents

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Sources, Vaults}
  alias BabelSync.Sources.{Items, Script, Source}
  alias BabelSync.Vaults.{Entry, Vault}
  alias BabelSyncWeb.Paths

  @page 100
  @tabs [all: "All", current: "Current", deleted: "Deleted"]

  @impl true
  def mount(%{"vault_id" => vault_id, "entry_id" => entry_id}, _session, socket) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         true <- Sources.enabled?(),
         :ok <- Scope.authorize(socket.assigns.current_scope, vault_id, :admin),
         %Vault{} = vault <- Vaults.get_vault(vault_id),
         %Entry{vault_id: ^vault_id} = entry <- Vaults.get_entry(entry_id) do
      if connected?(socket), do: :ok = Sources.subscribe(vault.id)
      name = Script.name(entry.path, vault.sources_folder || "")

      {:ok,
       socket
       |> assign(:vault, vault)
       |> assign(:entry, entry)
       |> assign(:name, name)
       |> assign(:page_title, "#{name} notes")
       |> assign(:may_change, Sources.browser_admin?(socket.assigns.current_scope, vault.id))
       |> assign(:limit, @page)
       |> stream_configure(:notes, dom_id: fn {item, _entry} -> "note-#{item.id}" end)}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, "Only an owner can look after a vault's sources.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:shown, shown(params["show"]))
     |> assign(:matching, params["q"] || "")
     |> assign(:limit, @page)
     |> load()}
  end

  defp shown("current"), do: :current
  defp shown("deleted"), do: :deleted
  defp shown(_all), do: :all

  @impl true
  def handle_event("filter", %{"q" => matching}, socket) do
    {:noreply,
     push_patch(socket, to: here(socket.assigns, socket.assigns.shown, matching), replace: true)}
  end

  def handle_event("more", _params, socket) do
    {:noreply, socket |> assign(:limit, socket.assigns.limit + @page) |> load()}
  end

  def handle_event("reinstate", %{"item" => item_id}, socket) do
    with %Source{} = source <- socket.assigns.source,
         {:ok, item_id} <- Ecto.UUID.cast(item_id),
         {:ok, done} <- Sources.reinstate(socket.assigns.current_scope, source, item_id) do
      {:noreply, socket |> put_flash(:info, reinstated(done)) |> load()}
    else
      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "That takes an owner signed in here in the browser.")}

      _missing ->
        {:noreply, socket |> put_flash(:error, "That note is no longer deleted.") |> load()}
    end
  end

  defp reinstated(:restored),
    do: "The note is back from the trash, and the source keeps it again."

  defp reinstated(:forgotten), do: "The source will make the note again on its next run."

  @impl true
  def handle_info({:source_changed, _id}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp load(socket) do
    %{entry: entry, vault: vault, shown: shown, matching: matching, limit: limit} = socket.assigns
    source = Enum.find(Sources.list(vault.id), &(&1.entry_id == entry.id))

    counts =
      if source, do: Items.counts(source, matching), else: %{all: 0, current: 0, deleted: 0}

    notes = if source, do: Items.list(source, shown, matching, limit), else: []

    socket
    |> assign(:source, source)
    |> assign(:counts, counts)
    |> assign(:more, counts[shown] > length(notes))
    |> assign(:form, to_form(%{"q" => matching}))
    |> stream(:notes, notes, reset: true)
  end

  defp here(%{vault: vault, entry: entry}, shown, matching) do
    query =
      [show: shown != :all && shown, q: matching != "" && matching]
      |> Enum.filter(fn {_name, value} -> value end)

    ~p"/v/#{vault.id}/sources/#{entry.id}/notes?#{query}"
  end

  defp title(%Entry{path: path}), do: path |> Path.basename() |> Path.rootname()
  defp folder(%Entry{path: path}), do: Path.dirname(path)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl space-y-6 pb-12 pt-7 md:pb-20 md:pt-10">
        <.header>
          <:trail>
            <.back_link navigate={~p"/v/#{@vault.id}/sources/#{@entry.id}"} />
          </:trail>
          {@name} notes
          <:subtitle>
            Every note this source keeps up to date, and the ones deleted here that it will
            not make again.
          </:subtitle>
        </.header>

        <div class="flex flex-wrap items-center gap-x-4 gap-y-3">
          <nav id="note-tabs" class="flex gap-1 rounded-lg border border-line bg-sunken p-1">
            <.link
              :for={{shown, label} <- @tabs}
              id={"tab-#{shown}"}
              patch={here(assigns, shown, @matching)}
              aria-current={@shown == shown && "page"}
              class={[
                "flex items-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium transition-colors duration-150",
                if(@shown == shown,
                  do: "bg-surface text-ink shadow-raise",
                  else: "text-muted hover:text-ink"
                )
              ]}
            >
              {label}
              <span id={"count-#{shown}"} class="tabular-nums text-xs text-faint">
                {@counts[shown]}
              </span>
            </.link>
          </nav>
          <.form
            for={@form}
            id="note-filter"
            phx-change="filter"
            phx-submit="filter"
            class="min-w-48 flex-1"
          >
            <.input
              field={@form[:q]}
              type="search"
              placeholder="Filter by name, folder or key"
              phx-debounce="250"
              autocomplete="off"
            />
          </.form>
        </div>

        <div class="overflow-hidden rounded-xl border border-line bg-surface shadow-raise">
          <ul id="notes" phx-update="stream" class="divide-y divide-line">
            <li
              id="notes-empty"
              class="hidden px-4 py-10 text-center text-sm text-muted only:block"
            >
              {empty(@source, @shown, @matching)}
            </li>
            <li
              :for={{id, {item, entry}} <- @streams.notes}
              id={id}
              class="flex items-center gap-x-3 px-4 py-3 text-sm"
            >
              <div class="min-w-0 flex-1 space-y-0.5">
                <%= cond do %>
                  <% entry && is_nil(entry.deleted_at) -> %>
                    <.link
                      navigate={Paths.vault(@vault.id) <> "/f/" <> entry.path}
                      class="block truncate font-medium text-ink hover:underline"
                    >
                      {title(entry)}
                    </.link>
                    <p class="truncate text-xs text-faint">{folder(entry)}</p>
                  <% entry -> %>
                    <p class="truncate font-medium text-muted line-through decoration-faint">
                      {title(entry)}
                    </p>
                    <p class="truncate text-xs text-faint">
                      In the trash since
                      <.local_time id={"deleted-#{item.id}"} at={entry.deleted_at} />, from {folder(
                        entry
                      )}
                    </p>
                  <% true -> %>
                    <p class="truncate font-medium text-muted">{item.key}</p>
                    <p class="truncate text-xs text-faint">
                      Deleted, and no longer in the trash
                    </p>
                <% end %>
                <p :if={entry} class="truncate font-mono text-[0.7rem] text-faint">{item.key}</p>
              </div>
              <.button
                :if={@may_change and not (entry && is_nil(entry.deleted_at))}
                id={"reinstate-#{item.id}"}
                size="sm"
                phx-click="reinstate"
                phx-value-item={item.id}
              >
                <.icon name="hero-arrow-uturn-left-mini" class="size-4" />
                {if entry, do: "Restore", else: "Make again"}
              </.button>
            </li>
          </ul>
          <div :if={@more} class="border-t border-line px-4 py-3 text-center">
            <.button id="more-notes" size="sm" variant="ghost" phx-click="more">
              Show more
            </.button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp empty(nil, _shown, _matching),
    do: "This source has not been approved, so it keeps no notes yet."

  defp empty(_source, _shown, matching) when matching != "", do: "No note matches that."
  defp empty(_source, :deleted, _matching), do: "No note of this source's has been deleted."
  defp empty(_source, _shown, _matching), do: "This source has not made a note yet."
end
