defmodule BabelSyncWeb.VaultLive.Show do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Blobs, Markdown, Sync, Vaults}
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths
  alias BabelSyncWeb.VaultLive.Tree

  @image ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  @audio ~w(.mp3 .wav .ogg .m4a .flac)
  @video ~w(.mp4 .webm .mov .mkv)
  @preview_delay 250

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
       |> assign(:writable, writable)
       |> assign(:admin, Scope.authorize(scope, vault_id, :admin) == :ok)
       |> assign(:mode, if(writable, do: :edit, else: :read))
       |> assign(:socket_token, Auth.socket_token(scope))
       |> assign(:entry, nil)
       |> assign(:preview, nil)
       |> assign(:versions, nil)
       |> assign(:version, nil)
       |> assign(:blob_versions, nil)
       |> assign(:preview_timer, nil)
       |> assign(:new_form, to_form(%{"path" => ""}, as: :note))
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
        {:ok, entry} -> {:noreply, push_patch(socket, to: Paths.entry(entry))}
        {:error, {:exists, entry}} -> {:noreply, push_patch(socket, to: Paths.entry(entry))}
        {:error, _changeset} -> {:noreply, put_flash(socket, :error, "That is not a valid path.")}
      end
    end)
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
    :ok = Sync.flush(entry.id)
    {:noreply, socket |> assign(:versions, Sync.list_versions(entry.id)) |> assign(:version, nil)}
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

  def handle_event("show_version", %{"id" => id}, %{assigns: %{entry: %Entry{} = entry}} = socket) do
    {:noreply, assign(socket, :version, Sync.get_version(entry.id, String.to_integer(id)))}
  end

  def handle_event("restore", %{"id" => id}, %{assigns: %{entry: %Entry{} = entry}} = socket) do
    write(socket, fn ->
      author = socket.assigns.current_scope.user.id
      :ok = Sync.restore_version(entry.id, String.to_integer(id), author_id: author)

      {:noreply,
       socket
       |> assign(:versions, nil)
       |> assign(:version, nil)
       |> put_flash(:info, "Restored. The previous text is still in the history.")
       |> render_preview()}
    end)
  end

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
      Markdown.to_html(Sync.text(entry.id), socket.assigns.entries, %{
        note: &Paths.entry/1,
        raw: &Paths.raw/1
      })

    assign(socket, :preview, html)
  end

  defp render_preview(socket), do: assign(socket, :preview, nil)

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
      <div id="vault" class="flex h-[calc(100dvh-3.5rem)]">
        <aside
          id="sidebar"
          class="w-72 shrink-0 border-r border-base-300 flex flex-col bg-base-200/40"
        >
          <div class="flex items-center justify-between gap-2 px-4 py-3">
            <.link patch={Paths.vault(@vault.id)} class="font-semibold truncate">{@vault.name}</.link>
            <div class="flex items-center">
              <.link
                navigate={Paths.trash(@vault.id)}
                id="vault-trash"
                class="btn btn-ghost btn-xs"
                title="Trash"
              >
                <.icon name="hero-trash" class="size-4" />
              </.link>
              <.link
                :if={@admin}
                navigate={Paths.settings(@vault.id)}
                id="vault-settings"
                class="btn btn-ghost btn-xs"
                title="Vault settings"
              >
                <.icon name="hero-cog-6-tooth" class="size-4" />
              </.link>
            </div>
          </div>

          <div :if={@writable} class="px-3 pb-3 space-y-2">
            <.form for={@new_form} id="new-note" phx-submit="create_note" class="join w-full">
              <input
                type="text"
                name={@new_form[:path].name}
                value=""
                placeholder="New note path"
                required
                class="input input-sm join-item w-full"
              />
              <button class="btn btn-sm btn-primary join-item" title="Create note"><.icon
                name="hero-plus"
                class="size-4"
              /></button>
            </.form>
            <label class="btn btn-sm btn-block">
              <.icon name="hero-arrow-up-tray" class="size-4" /> Upload files
              <input
                id="uploader"
                type="file"
                multiple
                class="hidden"
                phx-hook="Uploader"
                data-vault-id={@vault.id}
                data-token={@socket_token}
              />
            </label>
            <progress
              id="upload-progress"
              phx-update="ignore"
              class="progress progress-primary w-full"
              value="0"
              max="100"
              hidden
            ></progress>
          </div>

          <nav id="tree" class="flex-1 overflow-y-auto px-2 pb-4 text-sm">
            <p :if={@tree == []} class="px-2 py-4 text-base-content/60">This vault is empty.</p>
            <.tree nodes={@tree} selected={@entry && @entry.path} vault_id={@vault.id} />
          </nav>
        </aside>

        <section class="flex-1 min-w-0 flex flex-col">
          <div
            :if={is_nil(@entry)}
            id="empty"
            class="m-auto text-center text-base-content/60 space-y-2 p-8"
          >
            <.icon name="hero-document-text" class="size-10" />
            <p>Select a note, or connect Obsidian to this vault to start syncing.</p>
          </div>

          <div
            :if={@entry}
            id="toolbar"
            class="flex items-center gap-2 border-b border-base-300 px-4 h-12 shrink-0"
          >
            <span id="entry-path" class="font-medium truncate flex-1">{@entry.path}</span>
            <div :if={@entry.kind == :doc} class="join">
              <button
                :if={@writable}
                phx-click="mode"
                phx-value-mode="edit"
                class={["btn btn-xs join-item", @mode == :edit && "btn-active"]}
              >Edit</button>
              <button
                phx-click="mode"
                phx-value-mode="read"
                class={["btn btn-xs join-item", @mode == :read && "btn-active"]}
              >Read</button>
            </div>
            <button
              :if={@entry.kind in [:doc, :blob]}
              id="history-button"
              phx-click="history"
              class="btn btn-ghost btn-xs"
              title="History"
            >
              <.icon name="hero-clock" class="size-4" />
            </button>
            <button
              :if={@writable}
              id="rename-button"
              phx-click="start_rename"
              class="btn btn-ghost btn-xs"
              title="Rename or move"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              :if={@writable}
              id="delete-button"
              phx-click="delete"
              data-confirm={"Delete #{@entry.path}?"}
              class="btn btn-ghost btn-xs text-error"
              title="Delete"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>

          <.form
            :if={@rename_form}
            for={@rename_form}
            id="rename-form"
            phx-submit="rename"
            class="flex items-center gap-2 border-b border-base-300 px-4 py-2"
          >
            <input
              type="text"
              name={@rename_form[:path].name}
              value={@rename_form[:path].value}
              class="input input-sm flex-1"
              required
            />
            <button class="btn btn-sm btn-primary">Move</button>
            <button type="button" phx-click="cancel_rename" class="btn btn-sm btn-ghost">Cancel</button>
          </.form>

          <div :if={@entry && @entry.kind == :doc && @mode == :edit} class="flex-1 min-h-0">
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
            class="flex-1 overflow-y-auto px-8 py-6"
          >
            <div class="markdown mx-auto max-w-3xl">{raw(@preview)}</div>
          </article>

          <div
            :if={@entry && @entry.kind == :blob}
            id="attachment"
            class="flex-1 overflow-auto p-8 space-y-4"
          >
            <img
              :if={media(@entry) == :image}
              src={Paths.raw(@entry)}
              alt={@entry.path}
              class="max-w-full rounded-box border border-base-300"
            />
            <audio :if={media(@entry) == :audio} src={Paths.raw(@entry)} controls class="w-full"></audio>
            <video
              :if={media(@entry) == :video}
              src={Paths.raw(@entry)}
              controls
              class="max-w-full rounded-box"
            ></video>
            <p class="text-sm text-base-content/70">
              {size(@entry.size)} ·
              <a href={Paths.raw(@entry)} download={Path.basename(@entry.path)} class="link">Download</a>
            </p>
          </div>

          <div :if={@entry && @entry.kind == :folder} class="m-auto text-base-content/60">Folder</div>
        </section>

        <aside
          :if={@versions}
          id="history"
          class="w-96 shrink-0 border-l border-base-300 flex flex-col"
        >
          <div class="flex items-center justify-between px-4 h-12 border-b border-base-300">
            <span class="font-medium">History</span>
            <button phx-click="close_history" class="btn btn-ghost btn-xs"><.icon
              name="hero-x-mark"
              class="size-4"
            /></button>
          </div>
          <p :if={@versions == []} class="p-4 text-sm text-base-content/60">No saved versions yet.</p>
          <ul class="menu w-full overflow-y-auto max-h-56 shrink-0 flex-nowrap">
            <li :for={version <- @versions}>
              <button
                phx-click="show_version"
                phx-value-id={version.id}
                class={@version && @version.id == version.id && "menu-active"}
              >
                {Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
                <span class="text-xs text-base-content/60">{size(byte_size(version.content))}</span>
              </button>
            </li>
          </ul>
          <div :if={@version} class="flex-1 min-h-0 flex flex-col border-t border-base-300">
            <pre id="version-content" class="flex-1 overflow-auto p-4 text-xs whitespace-pre-wrap">{@version.content}</pre>
            <button
              :if={@writable}
              id="restore-button"
              phx-click="restore"
              phx-value-id={@version.id}
              class="btn btn-primary btn-sm m-3"
            >
              Restore this version
            </button>
          </div>
        </aside>

        <aside
          :if={@blob_versions}
          id="blob-history"
          class="w-96 shrink-0 border-l border-base-300 flex flex-col"
        >
          <div class="flex items-center justify-between px-4 h-12 border-b border-base-300">
            <span class="font-medium">History</span>
            <button phx-click="close_history" class="btn btn-ghost btn-xs"><.icon
              name="hero-x-mark"
              class="size-4"
            /></button>
          </div>
          <ul class="divide-y divide-base-300 overflow-y-auto">
            <li
              :for={version <- @blob_versions}
              id={"blob-version-#{version.id}"}
              class="flex items-center gap-3 px-4 py-3 text-sm"
            >
              <div class="flex-1">
                <div>{Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}</div>
                <div class="text-xs text-base-content/60">{size(version.size)}</div>
              </div>
              <span :if={version.blob_hash == @entry.blob_hash} class="badge badge-sm">current</span>
              <button
                :if={@writable and version.blob_hash != @entry.blob_hash}
                phx-click="restore_blob"
                phx-value-id={version.id}
                class="btn btn-xs transition hover:-translate-y-px"
              >
                Restore
              </button>
            </li>
          </ul>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :nodes, :list, required: true
  attr :selected, :string, default: nil
  attr :vault_id, :string, required: true

  defp tree(assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={node <- @nodes}>
        <details :if={Tree.folder?(node)} open>
          <summary class="flex items-center gap-1.5 rounded px-2 py-1 cursor-pointer hover:bg-base-300/60">
            <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/60" />
            <span class="truncate">{node.name}</span>
          </summary>
          <div class="ml-3 border-l border-base-300 pl-1">
            <.tree nodes={node.children} selected={@selected} vault_id={@vault_id} />
          </div>
        </details>
        <.link
          :if={not Tree.folder?(node)}
          patch={Paths.entry(node.entry)}
          class={[
            "flex items-center gap-1.5 rounded px-2 py-1 hover:bg-base-300/60",
            @selected == node.path && "bg-primary/15 font-medium"
          ]}
        >
          <.icon
            name={if node.entry.kind == :doc, do: "hero-document-text", else: "hero-paper-clip"}
            class="size-4 shrink-0 text-base-content/60"
          />
          <span class="truncate">{node.name}</span>
        </.link>
      </li>
    </ul>
    """
  end
end
