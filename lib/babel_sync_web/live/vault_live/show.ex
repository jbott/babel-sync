defmodule BabelSyncWeb.VaultLive.Show do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Blobs, History, Markdown, Sync, Vaults}
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths
  alias BabelSyncWeb.VaultLive.Tree

  @image ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  @audio ~w(.mp3 .wav .ogg .m4a .flac)
  @video ~w(.mp4 .webm .mov .mkv)
  @preview_delay 250

  @fence String.duplicate("`", 12)

  @impl true
  def mount(%{"vault_id" => vault_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         %Vaults.Vault{} = vault <- Vaults.get_vault(vault_id) do
      if connected?(socket), do: Vaults.subscribe(vault_id)
      writable = Scope.authorize(scope, vault_id, :write) == :ok

      {:ok,
       socket
       |> assign(:vault, vault)
       |> assign(:vaults, Vaults.list_vaults(scope.user))
       |> assign(:writable, writable)
       |> assign(:admin, Scope.authorize(scope, vault_id, :admin) == :ok)
       |> assign(:mode, if(writable, do: :edit, else: :read))
       |> assign(:socket_token, Auth.socket_token(scope))
       |> assign(:entry, nil)
       |> assign(:preview, nil)
       |> assign(:versions, nil)
       |> assign(:version, nil)
       |> assign(:against, :previous)
       |> assign(:blob_versions, nil)
       |> assign(:preview_timer, nil)
       |> assign(:new_form, to_form(%{"path" => ""}, as: :note))
       |> assign(:notes_created, 0)
       |> assign(:rename_form, nil)
       |> track(Vaults.list_entries(vault_id))}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, "That vault does not exist or is not shared with you.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = params |> Map.get("path", []) |> Enum.join("/")
    socket = if path == "", do: socket, else: ensure_known(socket, path)
    entry = if path != "", do: Enum.find(socket.assigns.entries, &(&1.path == path))

    socket =
      if path != "" and is_nil(entry),
        do: put_flash(socket, :error, "#{path} does not exist."),
        else: socket

    {:noreply, select(socket, entry)}
  end

  defp ensure_known(socket, path) do
    known = Enum.find(socket.assigns.entries, &(&1.path == path))

    case known || Vaults.get_entry_by_path(socket.assigns.vault.id, path) do
      nil ->
        socket

      ^known ->
        socket

      fresh ->
        put_entries(socket, [fresh | Enum.reject(socket.assigns.entries, &(&1.id == fresh.id))])
    end
  end

  @impl true
  def handle_event("create_note", %{"note" => %{"path" => path}}, socket) do
    path = if Path.extname(path) == "", do: path <> ".md", else: path

    write(socket, fn ->
      case Vaults.create_entry(socket.assigns.vault.id, %{path: path}) do
        {:ok, entry} -> {:noreply, open_created(socket, entry)}
        {:error, {:exists, entry}} -> {:noreply, open_created(socket, entry)}
        {:error, _changeset} -> {:noreply, put_flash(socket, :error, "That is not a valid path.")}
      end
    end)
  end

  def handle_event("switch_vault", %{"vault" => "connect"}, socket) do
    {:noreply, push_navigate(socket, to: Paths.connect(socket.assigns.vault.id))}
  end

  def handle_event("switch_vault", %{"vault" => "manage"}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/account")}
  end

  def handle_event("switch_vault", %{"vault" => id}, socket) do
    case Enum.find(socket.assigns.vaults, &(&1.id == id)) do
      %Vaults.Vault{id: ^id} -> {:noreply, push_navigate(socket, to: Paths.vault(id))}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("attach", %{"name" => name, "hash" => hash}, socket) do
    write(socket, fn ->
      vault_id = socket.assigns.vault.id
      path = Path.join(current_folder(socket), Path.basename(name))

      with %Blobs.Blob{size: size} <- Blobs.get(vault_id, hash),
           {:ok, entry} <- put_blob(vault_id, path, hash, size) do
        {:noreply, push_patch(socket, to: Paths.entry(entry))}
      else
        _failed -> {:noreply, put_flash(socket, :error, "Could not attach #{name}.")}
      end
    end)
  end

  def handle_event("upload_failed", %{"name" => name}, socket) do
    {:noreply, put_flash(socket, :error, "Uploading #{name} failed.")}
  end

  def handle_event("mode", %{"mode" => mode}, socket) when mode in ["edit", "read"] do
    mode = if mode == "edit" and socket.assigns.writable, do: :edit, else: :read
    {:noreply, socket |> assign(:mode, mode) |> render_preview()}
  end

  def handle_event("start_rename", _params, %{assigns: %{entry: %Entry{} = entry}} = socket) do
    {:noreply, assign(socket, :rename_form, to_form(%{"path" => entry.path}, as: :rename))}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :rename_form, nil)}
  end

  def handle_event(
        "rename",
        %{"rename" => %{"path" => path}},
        %{assigns: %{entry: %Entry{} = entry}} = socket
      ) do
    write(socket, fn ->
      case Vaults.rename_entry(entry, path) do
        {:ok, moved} ->
          renamed = Enum.find(moved, &(&1.id == entry.id))
          {:noreply, socket |> assign(:rename_form, nil) |> push_patch(to: Paths.entry(renamed))}

        {:error, {:exists, _entry}} ->
          {:noreply, put_flash(socket, :error, "Something already exists at #{path}.")}

        {:error, :not_found} ->
          {:noreply, push_patch(socket, to: Paths.vault(entry.vault_id))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That is not a valid path.")}
      end
    end)
  end

  def handle_event("delete", _params, %{assigns: %{entry: %Entry{} = entry}} = socket) do
    write(socket, fn ->
      _deleted_here_or_elsewhere = Vaults.delete_entry(entry)
      {:noreply, push_patch(socket, to: Paths.vault(entry.vault_id))}
    end)
  end

  def handle_event("history", _params, %{assigns: %{entry: %Entry{kind: :doc} = entry}} = socket) do
    {:noreply, socket |> assign(:versions, History.versions(entry.id)) |> assign(:version, nil)}
  end

  def handle_event("history", _params, %{assigns: %{entry: %Entry{kind: :blob} = entry}} = socket) do
    {:noreply, assign(socket, :blob_versions, Vaults.list_blob_versions(entry.id))}
  end

  def handle_event("close_history", _params, socket) do
    {:noreply,
     socket |> assign(:versions, nil) |> assign(:version, nil) |> assign(:blob_versions, nil)}
  end

  def handle_event(
        "restore_blob",
        %{"id" => id},
        %{assigns: %{entry: %Entry{kind: :blob} = entry}} = socket
      ) do
    write(socket, fn ->
      case Vaults.restore_blob_version(entry, String.to_integer(id)) do
        {:ok, restored} ->
          {:noreply,
           socket
           |> assign(:entry, restored)
           |> assign(:blob_versions, Vaults.list_blob_versions(entry.id))
           |> put_flash(:info, "Restored. The replaced file is still in the history.")}

        {:error, _gone} ->
          {:noreply, put_flash(socket, :error, "That version is no longer available.")}
      end
    end)
  end

  def handle_event("show_version", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:against, :previous) |> compare(String.to_integer(id))}
  end

  def handle_event("compare", %{"against" => against}, %{assigns: %{version: version}} = socket)
      when against in ~w(previous now text) and not is_nil(version) do
    {:noreply,
     socket |> assign(:against, String.to_existing_atom(against)) |> compare(version.version.id)}
  end

  def handle_event("restore", %{"id" => id}, %{assigns: %{entry: %Entry{} = entry}} = socket) do
    write(socket, fn ->
      author = socket.assigns.current_scope.user.id
      :ok = Sync.restore_version(entry.id, String.to_integer(id), author_id: author)

      {:noreply,
       socket
       |> assign(:versions, History.versions(entry.id))
       |> assign(:version, nil)
       |> put_flash(:info, "Restored. The previous text is still in the history.")
       |> render_preview()}
    end)
  end

  def handle_event(_event_for_an_entry_no_longer_open, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:entry_changed, %Entry{} = changed}, socket) do
    if Map.get(socket.assigns.latest, changed.id, -1) >= changed.seq,
      do: {:noreply, socket},
      else: entry_changed(changed, socket)
  end

  def handle_info({:doc_update, _entry_id, _update, _origin}, socket) do
    if socket.assigns.mode == :read and is_nil(socket.assigns.preview_timer) do
      timer = Process.send_after(self(), :render_preview, @preview_delay)
      {:noreply, assign(socket, :preview_timer, timer)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:render_preview, socket) do
    {:noreply, socket |> assign(:preview_timer, nil) |> render_preview()}
  end

  def handle_info({:awareness, _state}, socket), do: {:noreply, socket}

  defp entry_changed(changed, socket) do
    socket = assign(socket, :latest, Map.put(socket.assigns.latest, changed.id, changed.seq))
    entries = Enum.reject(socket.assigns.entries, &(&1.id == changed.id))
    entries = if changed.deleted_at, do: entries, else: [changed | entries]
    socket = put_entries(socket, entries)

    case socket.assigns.entry do
      %Entry{id: id} when id == changed.id and not is_nil(changed.deleted_at) ->
        {:noreply,
         socket
         |> put_flash(:info, "#{changed.path} was deleted.")
         |> push_patch(to: Paths.vault(changed.vault_id))}

      %Entry{id: id, path: path} when id == changed.id and path != changed.path ->
        {:noreply, push_patch(socket, to: Paths.entry(changed))}

      %Entry{id: id} when id == changed.id ->
        {:noreply, assign(socket, :entry, changed)}

      _other ->
        {:noreply, socket}
    end
  end

  defp open_created(socket, entry) do
    socket |> update(:notes_created, &(&1 + 1)) |> push_patch(to: Paths.entry(entry))
  end

  defp compare(%{assigns: %{entry: %Entry{} = entry, against: against}} = socket, version_id) do
    case History.compare(entry.id, version_id, if(against == :now, do: :now, else: :previous)) do
      {:ok, comparison} -> assign(socket, :version, comparison)
      {:error, :not_found} -> put_flash(socket, :error, "That version is no longer available.")
    end
  end

  defp write(socket, fun) do
    if socket.assigns.writable,
      do: fun.(),
      else: {:noreply, put_flash(socket, :error, "You can only read this vault.")}
  end

  defp put_blob(vault_id, path, hash, size) do
    case Vaults.create_entry(vault_id, %{path: path, kind: :blob, blob_hash: hash, size: size}) do
      {:error, {:exists, %Entry{kind: :blob} = entry}} ->
        Vaults.update_entry(entry, %{blob_hash: hash, size: size})

      other ->
        other
    end
  end

  defp track(socket, entries) do
    socket |> assign(:latest, Map.new(entries, &{&1.id, &1.seq})) |> put_entries(entries)
  end

  defp put_entries(socket, entries) do
    entries = Enum.sort_by(entries, & &1.path)
    socket |> assign(:entries, entries) |> assign(:tree, Tree.build(entries))
  end

  defp select(socket, entry) do
    previous = socket.assigns.entry

    if connected?(socket) do
      if match?(%Entry{kind: :doc}, previous) and (is_nil(entry) or previous.id != entry.id),
        do: Phoenix.PubSub.unsubscribe(BabelSync.PubSub, Sync.topic(previous.id))

      if match?(%Entry{kind: :doc}, entry) and (is_nil(previous) or previous.id != entry.id),
        do: Sync.subscribe(entry.id)
    end

    socket
    |> assign(:entry, entry)
    |> assign(
      :page_title,
      if(entry, do: Path.basename(entry.path), else: socket.assigns.vault.name)
    )
    |> assign(:versions, nil)
    |> assign(:version, nil)
    |> assign(:blob_versions, nil)
    |> assign(:rename_form, nil)
    |> render_preview()
  end

  defp render_preview(%{assigns: %{entry: %Entry{kind: :doc} = entry, mode: :read}} = socket) do
    html =
      Markdown.to_html(readable(entry, Sync.text(entry.id)), socket.assigns.entries, %{
        note: &Paths.entry/1,
        raw: &Paths.raw/1,
        text: &readable(&1, Sync.text(&1.id))
      })

    assign(socket, :preview, html)
  end

  defp render_preview(socket), do: assign(socket, :preview, nil)

  defp readable(%Entry{path: path}, text) do
    if Vaults.Path.markdown?(path),
      do: text,
      else: Enum.join([@fence <> language(path), text, @fence], "\n")
  end

  defp language(path) do
    case String.downcase(Path.extname(path)) do
      ".base" -> "yaml"
      ".canvas" -> "json"
      _plain -> ""
    end
  end

  defp current_folder(%{assigns: %{entry: %Entry{kind: :folder, path: path}}}), do: path

  defp current_folder(%{assigns: %{entry: %Entry{path: path}}}) do
    case Path.dirname(path) do
      "." -> ""
      folder -> folder
    end
  end

  defp current_folder(_socket), do: ""

  defp media(%Entry{path: path}) do
    extension = String.downcase(Path.extname(path))

    cond do
      extension in @image -> :image
      extension in @audio -> :audio
      extension in @video -> :video
      true -> :other
    end
  end

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp cursor_color(user_id), do: "hsl(#{:erlang.phash2(user_id, 360)} 70% 45%)"

  defp display_name(user), do: user.name || user.email || "Someone"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div
        id="vault"
        class="flex h-dvh pl-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)]"
      >
        <aside
          id="sidebar"
          class={[
            "flex-col border-line bg-sunken pt-[env(safe-area-inset-top)] md:flex md:w-72 md:shrink-0 md:border-r",
            if(@entry, do: "hidden", else: "flex w-full")
          ]}
        >
          <div class="px-4 pt-3">
            <Layouts.brand />
          </div>

          <div :if={@writable} class="px-2 pt-2.5">
            <div class="flex items-center gap-1">
              <.form
                for={@new_form}
                id="new-note"
                phx-submit="create_note"
                class="relative min-w-0 flex-1"
              >
                <button
                  class="absolute left-0 top-0 grid size-9 cursor-pointer place-items-center rounded-lg text-faint transition-colors duration-150 hover:text-ink md:size-8"
                  title="Create note"
                  aria-label="Create note"
                >
                  <.icon name="hero-plus-mini" class="size-[1.125rem]" />
                </button>
                <input
                  type="text"
                  id={"new-note-path-#{@notes_created}"}
                  name={@new_form[:path].name}
                  value=""
                  placeholder="New note"
                  aria-label="New note path"
                  autocapitalize="off"
                  autocomplete="off"
                  spellcheck="false"
                  required
                  class="block h-9 w-full min-w-0 rounded-lg bg-ink/5 pl-9 pr-3 text-sm text-ink outline-none transition-colors duration-150 hover:bg-ink/8 focus:bg-surface focus:ring-2 focus:ring-accent/60 md:h-8 md:pl-8"
                />
              </.form>
              <label
                class="grid size-9 shrink-0 cursor-pointer place-items-center rounded-lg text-muted transition-colors duration-150 hover:bg-ink/7 hover:text-ink has-focus-visible:ring-2 has-focus-visible:ring-accent/60 md:size-8"
                title="Upload files"
              >
                <.icon name="hero-arrow-up-tray" class="size-[1.125rem]" />
                <input
                  id="uploader"
                  type="file"
                  multiple
                  class="sr-only"
                  aria-label="Upload files"
                  phx-hook="Uploader"
                  data-vault-id={@vault.id}
                  data-token={@socket_token}
                />
              </label>
            </div>
            <progress
              id="upload-progress"
              phx-update="ignore"
              class="upload-meter mt-2"
              value="0"
              max="100"
              hidden
            ></progress>
          </div>

          <div :if={@tree != []} class="mt-2 flex items-center gap-0.5 pl-4 pr-2">
            <span class="flex-1 text-2xs font-semibold uppercase tracking-[0.1em] text-faint">
              Files
            </span>
            <.icon_button
              id="open-all-folders"
              phx-click={JS.dispatch("babelsync:folders", to: "#tree", detail: %{open: true})}
              icon="hero-arrows-pointing-out-mini"
              label="Open all folders"
            />
            <.icon_button
              id="close-all-folders"
              phx-click={JS.dispatch("babelsync:folders", to: "#tree", detail: %{open: false})}
              icon="hero-arrows-pointing-in-mini"
              label="Close all folders"
            />
          </div>

          <nav
            id="tree"
            aria-label="Files"
            phx-hook="Folders"
            data-vault-id={@vault.id}
            class="mt-1 flex-1 overflow-y-auto px-2 pb-6 text-base md:text-sm"
          >
            <div :if={@tree == []} class="px-3 py-10 text-center">
              <.icon name="hero-document-plus" class="size-7 text-faint" />
              <p class="mt-2 text-muted">This vault is empty.</p>
              <.link
                id="tree-connect"
                navigate={Paths.connect(@vault.id)}
                class="mt-1 inline-flex items-center gap-1 rounded-md px-1 py-0.5 font-medium text-accent transition-colors duration-150 hover:text-ink"
              >
                Connect Obsidian <.icon name="hero-arrow-right-mini" class="size-4" />
              </.link>
            </div>
            <.tree nodes={@tree} selected={@entry && @entry.path} vault_id={@vault.id} />
          </nav>

          <div class="flex items-center gap-0.5 border-t border-line px-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] pt-2">
            <form
              id="vault-switcher-form"
              phx-change="switch_vault"
              class="relative mr-1 min-w-0 flex-1"
            >
              <select
                id="vault-switcher"
                name="vault"
                aria-label="Vault"
                title="Switch vault"
                class="block h-9 w-full min-w-0 cursor-pointer appearance-none truncate rounded-lg bg-ink/5 pl-3 pr-8 text-sm font-semibold text-ink outline-none transition-colors duration-150 hover:bg-ink/8 focus-visible:ring-2 focus-visible:ring-accent/60 md:h-8"
              >
                <option :for={vault <- @vaults} value={vault.id} selected={vault.id == @vault.id}>
                  {vault.name}
                </option>
                <hr />
                <option value="connect">Connect Obsidian…</option>
                <option value="manage">Manage vaults…</option>
              </select>
              <.icon
                name="hero-chevron-up-down-mini"
                class="pointer-events-none absolute right-2 top-1/2 size-4 -translate-y-1/2 text-faint"
              />
            </form>
            <.icon_button
              navigate={Paths.trash(@vault.id)}
              id="vault-trash"
              icon="hero-trash"
              label="Trash"
            />
            <.icon_button
              :if={@admin}
              navigate={Paths.settings(@vault.id)}
              id="vault-settings"
              icon="hero-cog-6-tooth"
              label="Vault settings"
            />
            <.icon_button
              :if={@current_scope}
              id="account-link"
              navigate={~p"/account?#{[from: @vault.id]}"}
              icon="hero-user-circle"
              label="Your settings"
            />
          </div>
        </aside>

        <section class={[
          "min-w-0 flex-1 flex-col bg-surface pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:flex",
          if(@entry, do: "flex", else: "hidden")
        ]}>
          <div :if={is_nil(@entry)} id="empty" class="m-auto max-w-sm p-8 text-center">
            <.logo class="mx-auto size-14 text-line-strong" />
            <h2 class="mt-5 font-serif text-xl font-bold tracking-tight text-ink">
              {@vault.name}
            </h2>
            <p class="mt-2 text-muted">
              {if(@entries == [],
                do: "Nothing here yet. Connect Obsidian to bring your notes in, or create one.",
                else: "Select a note, or connect Obsidian on another device to keep it in sync."
              )}
            </p>
            <.button
              id="connect-obsidian"
              navigate={Paths.connect(@vault.id)}
              variant={if(@entries == [], do: "primary", else: "secondary")}
              class="mt-5"
            >
              <.icon name="hero-device-phone-mobile-mini" class="size-4" /> Connect Obsidian
            </.button>
          </div>

          <div
            :if={@entry}
            id="toolbar"
            class="flex h-12 shrink-0 items-center gap-0.5 border-b border-line pl-1.5 pr-1.5 md:gap-1 md:pl-5 md:pr-3"
          >
            <.icon_button
              patch={Paths.vault(@vault.id)}
              id="back-to-files"
              icon="hero-chevron-left"
              label="All files"
              class="md:hidden"
            />
            <span
              id="entry-path"
              class="path-tail min-w-0 flex-1 truncate pr-2 text-sm font-medium text-ink"
            ><bdi>{@entry.path}</bdi></span>
            <div
              :if={@entry.kind == :doc}
              class="mr-1 flex shrink-0 items-center gap-0.5 rounded-lg border border-line bg-sunken p-0.5"
              role="group"
              aria-label="Mode"
            >
              <button
                :if={@writable}
                phx-click="mode"
                phx-value-mode="edit"
                aria-pressed={to_string(@mode == :edit)}
                class={mode_class(@mode == :edit)}
              >Edit</button>
              <button
                phx-click="mode"
                phx-value-mode="read"
                aria-pressed={to_string(@mode == :read)}
                class={mode_class(@mode == :read)}
              >Read</button>
            </div>
            <.icon_button
              :if={@entry.kind in [:doc, :blob]}
              id="history-button"
              phx-click="history"
              icon="hero-clock"
              label="History"
            />
            <.icon_button
              :if={@writable}
              id="rename-button"
              phx-click="start_rename"
              icon="hero-pencil-square"
              label="Rename or move"
            />
            <.icon_button
              :if={@writable}
              id="delete-button"
              phx-click="delete"
              data-confirm={"Delete #{@entry.path}?"}
              icon="hero-trash"
              label="Delete"
              tone="danger"
            />
          </div>

          <.form
            :if={@rename_form}
            for={@rename_form}
            id="rename-form"
            phx-submit="rename"
            class="flex animate-rise flex-wrap items-center justify-end gap-2 border-b border-line bg-sunken px-3 py-2.5 md:px-5"
          >
            <input
              type="text"
              name={@rename_form[:path].name}
              value={@rename_form[:path].value}
              aria-label="New path"
              autocapitalize="off"
              autocomplete="off"
              spellcheck="false"
              class={[field_class(), "h-9 w-full basis-full text-sm sm:w-auto sm:flex-1 sm:basis-0"]}
              required
            />
            <.button type="button" phx-click="cancel_rename" variant="ghost" size="sm">
              Cancel
            </.button>
            <.button variant="primary" size="sm">Move</.button>
          </.form>

          <div :if={@entry && @entry.kind == :doc && @mode == :edit} class="min-h-0 flex-1">
            <div
              id={"editor-#{@entry.id}"}
              phx-hook="Editor"
              phx-update="ignore"
              data-entry-id={@entry.id}
              data-token={@socket_token}
              data-writable={to_string(@writable)}
              data-user-name={display_name(@current_scope.user)}
              data-user-color={cursor_color(@current_scope.user.id)}
              class="h-full"
            >
            </div>
          </div>

          <article
            :if={@entry && @entry.kind == :doc && @mode == :read}
            id="preview"
            class="flex-1 overflow-y-auto px-5 pb-24 pt-7 md:px-10 md:pt-12"
          >
            <div id="preview-body" phx-hook="Markdown" class="markdown mx-auto max-w-[42rem]">
              {raw(@preview)}
            </div>
          </article>

          <div
            :if={@entry && @entry.kind == :blob}
            id="attachment"
            class="flex flex-1 flex-col items-center gap-5 overflow-auto bg-sunken/60 p-4 md:p-10"
          >
            <img
              :if={media(@entry) == :image}
              src={Paths.raw(@entry)}
              alt={@entry.path}
              class="max-w-full rounded-lg border border-line bg-surface shadow-float"
            />
            <audio
              :if={media(@entry) == :audio}
              src={Paths.raw(@entry)}
              controls
              class="w-full max-w-xl"
            ></audio>
            <video
              :if={media(@entry) == :video}
              src={Paths.raw(@entry)}
              controls
              class="max-w-full rounded-lg border border-line shadow-float"
            ></video>
            <div
              :if={media(@entry) == :other}
              class="grid size-20 place-items-center rounded-2xl border border-line bg-surface text-faint shadow-raise"
            >
              <.icon name="hero-paper-clip" class="size-8" />
            </div>
            <p class="flex items-center gap-3 text-sm text-muted">
              <span class="tabular-nums">{size(@entry.size)}</span>
              <.button href={Paths.raw(@entry)} download={Path.basename(@entry.path)} size="sm">
                <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Download
              </.button>
            </p>
          </div>

          <div :if={@entry && @entry.kind == :folder} class="m-auto p-8 text-center text-muted">
            <.icon name="hero-folder-open" class="size-10 text-line-strong" />
            <p class="mt-2">Folder</p>
          </div>
        </section>

        <aside
          :if={@versions}
          id="history"
          class={[
            "fixed inset-0 z-20 flex flex-col border-line bg-canvas pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:static md:z-auto md:shrink-0 md:border-l",
            if(@version, do: "md:w-[30rem] lg:w-[36rem]", else: "md:w-96")
          ]}
        >
          <.history_heading />
          <div :if={@versions == []} class="px-6 py-12 text-center">
            <.icon name="hero-clock" class="size-7 text-faint" />
            <p class="mt-2 text-sm text-muted">No saved versions yet.</p>
          </div>
          <ul class={[
            "shrink-0 overflow-y-auto p-2",
            if(@version, do: "max-h-48", else: "min-h-0 flex-1")
          ]}>
            <li :for={version <- @versions}>
              <button
                id={"version-#{version.id}"}
                phx-click="show_version"
                phx-value-id={version.id}
                aria-current={to_string(chosen?(@version, version))}
                class={[
                  "group flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition duration-150",
                  if(chosen?(@version, version),
                    do: "bg-accent/14 text-ink",
                    else: "text-muted hover:bg-ink/6 hover:text-ink"
                  )
                ]}
              >
                <span class={[
                  "size-2 shrink-0 rounded-full border-[1.5px] transition",
                  if(chosen?(@version, version),
                    do: "border-accent bg-accent",
                    else: "border-line-strong group-hover:border-faint"
                  )
                ]}></span>
                <span class="min-w-0 flex-1">
                  <span class="block tabular-nums">
                    <span class="font-medium text-ink">
                      {Calendar.strftime(version.saved_at, "%d %b %Y")}
                    </span>
                    {Calendar.strftime(version.saved_at, "%H:%M:%S UTC")}
                  </span>
                  <span :if={version.author} class="block truncate text-xs text-faint">
                    {version.author}
                  </span>
                </span>
                <span class="shrink-0 text-xs tabular-nums">
                  <span :if={version.added && version.added > 0} class="text-added">
                    +{version.added}
                  </span>
                  <span :if={version.removed && version.removed > 0} class="text-danger">
                    −{version.removed}
                  </span>
                  <span
                    :if={version.added == 0 and version.removed == 0}
                    class="text-faint"
                  >
                    {size(version.bytes)}
                  </span>
                </span>
              </button>
            </li>
          </ul>
          <p
            :if={@versions != [] and is_nil(@version)}
            class="border-t border-line px-4 py-3 text-xs text-faint"
          >
            Choose a version to see what it changed.
          </p>
          <div :if={@version} class="flex min-h-0 flex-1 flex-col border-t border-line bg-surface">
            <div class="flex items-center gap-2 border-b border-line px-3 py-2">
              <div
                id="compare-modes"
                role="tablist"
                class="inline-flex rounded-lg bg-sunken p-0.5"
              >
                <button
                  :for={
                    {against, label} <- [
                      previous: "Changes",
                      now: "Since then",
                      text: "Text"
                    ]
                  }
                  id={"compare-#{against}"}
                  role="tab"
                  aria-selected={to_string(@against == against)}
                  phx-click="compare"
                  phx-value-against={against}
                  class={mode_class(@against == against)}
                >
                  {label}
                </button>
              </div>
              <span :if={@against != :text} class="ml-auto text-xs tabular-nums">
                <span class="text-added">+{@version.changes.added}</span>
                <span class="text-danger">−{@version.changes.removed}</span>
              </span>
            </div>
            <p :if={@against != :text} class="px-4 pt-3 text-xs text-faint">
              {compare_caption(@against, @version.version, @versions)}
            </p>
            <pre
              :if={@against == :text}
              id="version-content"
              class="flex-1 overflow-auto whitespace-pre-wrap break-words p-4 font-mono text-xs leading-relaxed text-ink"
            >{@version.text}</pre>
            <div
              :if={@against != :text}
              id="version-changes"
              class="min-h-0 flex-1 overflow-auto py-2 font-mono text-xs leading-relaxed"
            >
              <p :if={@version.changes.hunks == []} class="px-4 py-6 text-center text-muted">
                No differences.
              </p>
              <div
                :for={hunk <- @version.changes.hunks}
                class="mb-2 border-y border-line first:border-t-0"
              >
                <div class="bg-sunken px-3 py-0.5 font-sans text-2xs text-faint">
                  Line {hunk.new_start}
                </div>
                <div
                  :for={line <- hunk.lines}
                  class={[
                    "flex",
                    line.kind == :added && "bg-added/10",
                    line.kind == :removed && "bg-danger/10"
                  ]}
                >
                  <span class="w-9 shrink-0 select-none pr-2 text-right tabular-nums text-faint">
                    {line.new || line.old}
                  </span>
                  <span class={[
                    "w-4 shrink-0 select-none",
                    line.kind == :added && "text-added",
                    line.kind == :removed && "text-danger"
                  ]}>
                    {marker(line.kind)}
                  </span>
                  <span class={[
                    "min-w-0 flex-1 whitespace-pre-wrap break-words pr-3",
                    if(line.kind == :same, do: "text-muted", else: "text-ink")
                  ]}><span
                    :for={{kind, text} <- line.segments}
                    class={[
                      kind == :added && line.segments != [{:added, text}] &&
                        "rounded-sm bg-added/25",
                      kind == :removed && line.segments != [{:removed, text}] &&
                        "rounded-sm bg-danger/25 line-through decoration-danger/50"
                    ]}
                  >{text}</span><span :if={
                    line.segments in [[], [{:same, ""}], [{:added, ""}], [{:removed, ""}]]
                  }>&nbsp;</span></span>
                </div>
              </div>
            </div>
            <div :if={@writable} class="border-t border-line p-3">
              <.button
                id="restore-button"
                phx-click="restore"
                phx-value-id={@version.version.id}
                variant="primary"
                class="w-full"
              >
                <.icon name="hero-arrow-uturn-left-mini" class="size-4" /> Restore this version
              </.button>
            </div>
          </div>
        </aside>

        <aside
          :if={@blob_versions}
          id="blob-history"
          class="fixed inset-0 z-20 flex flex-col border-line bg-canvas pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:static md:z-auto md:w-96 md:shrink-0 md:border-l"
        >
          <.history_heading />
          <ul class="divide-y divide-line overflow-y-auto">
            <li
              :for={version <- @blob_versions}
              id={"blob-version-#{version.id}"}
              class="flex items-center gap-3 px-4 py-3 text-sm"
            >
              <div class="flex-1 tabular-nums">
                <div class="text-muted">
                  <span class="font-medium text-ink">
                    {Calendar.strftime(version.inserted_at, "%d %b %Y")}
                  </span>
                  {Calendar.strftime(version.inserted_at, "%H:%M:%S UTC")}
                </div>
                <div class="text-xs text-faint">{size(version.size)}</div>
              </div>
              <.badge :if={version.blob_hash == @entry.blob_hash}>current</.badge>
              <.button
                :if={@writable and version.blob_hash != @entry.blob_hash}
                phx-click="restore_blob"
                phx-value-id={version.id}
                size="sm"
              >
                Restore
              </.button>
            </li>
          </ul>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp mode_class(active) do
    [
      "h-7 cursor-pointer rounded-md px-3 text-sm font-medium transition duration-150",
      if(active,
        do: "bg-surface text-ink shadow-raise",
        else: "text-muted hover:text-ink"
      )
    ]
  end

  defp chosen?(nil, _summary), do: false
  defp chosen?(%{version: version}, summary), do: version.id == summary.id

  defp marker(:added), do: "+"
  defp marker(:removed), do: "−"
  defp marker(:same), do: ""

  defp compare_caption(:now, _version, _versions),
    do: "From this version to the note as it is now."

  defp compare_caption(:previous, version, versions) do
    if Enum.find(versions, &(&1.id == version.id))[:earliest],
      do: "The earliest kept version, compared with an empty note.",
      else: "What this version changed from the one before it."
  end

  defp history_heading(assigns) do
    ~H"""
    <div class="flex h-12 shrink-0 items-center justify-between border-b border-line pl-4 pr-1.5">
      <span class="text-xs font-semibold uppercase tracking-[0.1em] text-muted">History</span>
      <.icon_button phx-click="close_history" icon="hero-x-mark" label="Close history" />
    </div>
    """
  end

  defp unfolded?(node, selected) do
    is_binary(selected) and String.starts_with?(selected, node.path <> "/")
  end

  attr :nodes, :list, required: true
  attr :selected, :string, default: nil
  attr :vault_id, :string, required: true

  defp tree(assigns) do
    ~H"""
    <ul class="space-y-px">
      <li :for={node <- @nodes}>
        <details
          :if={Tree.folder?(node)}
          data-path={node.path}
          open={unfolded?(node, @selected)}
          phx-mounted={JS.ignore_attributes(["open", "data-seen"])}
        >
          <summary class="flex cursor-pointer items-center gap-1.5 rounded-md px-2 py-2 font-medium text-ink transition-colors duration-100 hover:bg-ink/6 md:py-1">
            <.icon name="hero-chevron-right-mini" class="tree-chevron size-4 shrink-0 text-faint" />
            <span class="truncate">{node.name}</span>
          </summary>
          <div class="ml-[0.9375rem] border-l border-line pl-1.5">
            <.tree nodes={node.children} selected={@selected} vault_id={@vault_id} />
          </div>
        </details>
        <.link
          :if={not Tree.folder?(node)}
          patch={Paths.entry(node.entry)}
          aria-current={@selected == node.path && "page"}
          class={[
            "flex items-center gap-1.5 rounded-md px-2 py-2 transition-colors duration-100 md:py-1",
            if(@selected == node.path,
              do: "bg-accent/14 font-medium text-ink",
              else: "text-muted hover:bg-ink/6 hover:text-ink"
            )
          ]}
        >
          <.icon
            name={if node.entry.kind == :doc, do: "hero-document-text", else: "hero-paper-clip"}
            class={[
              "size-4 shrink-0",
              if(@selected == node.path, do: "text-accent", else: "text-faint")
            ]}
          />
          <span class="truncate">{node.name}</span>
        </.link>
      </li>
    </ul>
    """
  end
end
