defmodule BabelSyncWeb.VaultLive.Show do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Auth, Blobs, Canvas, History, Markdown, Sync, Vaults}
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths

  alias BabelSyncWeb.VaultLive.{
    BaseView,
    DetailsPanel,
    Finder,
    HistoryPanel,
    Reader,
    Sidebar,
    Tree
  }

  @preview_delay 250
  @tree_delay 150

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
       |> assign(:note_mode, if(writable, do: :edit, else: :read))
       |> assign(:socket_token, Auth.socket_token(scope))
       |> assign(:entry, nil)
       |> assign(:preview, nil)
       |> assign(:shown_as, :markdown)
       |> assign(:base, nil)
       |> assign(:base_view, nil)
       |> assign(:versions, nil)
       |> assign(:version, nil)
       |> assign(:against, :previous)
       |> assign(:blob_versions, nil)
       |> assign(:preview_timer, nil)
       |> assign(:tree_timer, nil)
       |> assign(:tree_stale, false)
       |> assign(:open_folders, MapSet.new())
       |> assign(:finder, nil)
       |> assign(:details, nil)
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

    {:noreply, socket |> close_finder() |> select(entry)}
  end

  defp ensure_known(socket, path) do
    known = Enum.find(socket.assigns.entries, &(&1.path == path))

    case known || Vaults.get_entry_by_path(socket.assigns.vault.id, path) do
      nil ->
        socket

      ^known ->
        socket

      fresh ->
        socket |> assign(:known, Map.put(socket.assigns.known, fresh.id, fresh)) |> list_entries()
    end
  end

  @impl true
  def handle_event("create_note", %{"note" => %{"path" => path}}, socket) when is_binary(path) do
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

  def handle_event("switch_vault", %{"vault" => id}, %{assigns: %{vault: %{id: id}}} = socket),
    do: {:noreply, socket}

  def handle_event("switch_vault", %{"vault" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.vaults, &(&1.id == id)) do
      %Vaults.Vault{id: ^id} -> {:noreply, push_navigate(socket, to: Paths.vault(id))}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("open_folders", %{"paths" => paths}, socket) when is_list(paths) do
    {:noreply, assign(socket, :open_folders, MapSet.new(Enum.filter(paths, &is_binary/1)))}
  end

  def handle_event("toggle_folder", %{"path" => path, "open" => open?}, socket)
      when is_binary(path) do
    change = if open? == true, do: &MapSet.put/2, else: &MapSet.delete/2
    {:noreply, update(socket, :open_folders, &change.(&1, path))}
  end

  def handle_event("all_folders", %{"open" => open?}, socket) do
    paths = if open? == true, do: Tree.folders(socket.assigns.tree), else: []
    {:reply, %{open: paths}, assign(socket, :open_folders, MapSet.new(paths))}
  end

  def handle_event("open_finder", _params, socket) do
    {:noreply, assign(socket, :finder, Finder.open(socket.assigns.entries))}
  end

  def handle_event("close_finder", _params, socket), do: {:noreply, close_finder(socket)}

  def handle_event("find", %{"q" => query}, %{assigns: %{finder: %{} = finder}} = socket)
      when is_binary(query) do
    %{current_scope: scope, vault: vault, entries: entries} = socket.assigns

    socket =
      socket |> cancel_async(:search) |> assign(:finder, Finder.typed(finder, entries, query))

    if Finder.searchable?(query) do
      {:noreply,
       start_async(socket, :search, fn ->
         {query, Agent.search_files(scope, vault.id, String.trim(query))}
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("attach", %{"name" => name, "hash" => hash}, socket)
      when is_binary(name) and is_binary(hash) do
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

  def handle_event("upload_failed", %{"name" => name}, socket) when is_binary(name) do
    {:noreply, put_flash(socket, :error, "Uploading #{name} failed.")}
  end

  def handle_event("mode", %{"mode" => mode}, socket) when mode in ["edit", "read"] do
    mode = if mode == "edit" and socket.assigns.writable, do: :edit, else: :read

    socket =
      if drawn?(socket.assigns.entry), do: socket, else: assign(socket, :note_mode, mode)

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
      )
      when is_binary(path) do
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
    {:noreply,
     socket
     |> close_details()
     |> assign(:versions, History.versions(entry.id))
     |> assign(:version, nil)}
  end

  def handle_event("history", _params, %{assigns: %{entry: %Entry{kind: :blob} = entry}} = socket) do
    {:noreply, assign(socket, :blob_versions, Vaults.list_blob_versions(entry.id))}
  end

  def handle_event("details", _params, %{assigns: %{details: %{}}} = socket) do
    {:noreply, close_details(socket)}
  end

  def handle_event("details", _params, %{assigns: %{entry: %Entry{kind: :doc}}} = socket) do
    {:noreply,
     socket
     |> assign(:versions, nil)
     |> assign(:version, nil)
     |> assign(:details, %{headings: [], linked_from: :looking})
     |> show_details()}
  end

  def handle_event("close_details", _params, socket), do: {:noreply, close_details(socket)}

  def handle_event("reveal", %{"line" => line}, %{assigns: %{mode: :edit}} = socket)
      when is_integer(line) do
    {:noreply, push_event(socket, "reveal-line", %{line: line})}
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
      case Vaults.restore_blob_version(entry, version_id(id)) do
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
    {:noreply, socket |> assign(:against, :previous) |> compare(version_id(id))}
  end

  def handle_event("compare", %{"against" => against}, %{assigns: %{version: version}} = socket)
      when against in ~w(previous now text) and not is_nil(version) do
    {:noreply,
     socket |> assign(:against, String.to_existing_atom(against)) |> compare(version.version.id)}
  end

  def handle_event("restore", %{"id" => id}, %{assigns: %{entry: %Entry{} = entry}} = socket) do
    write(socket, fn ->
      author = socket.assigns.current_scope.user.id

      case Sync.restore_version(entry.id, version_id(id), author_id: author) do
        :ok ->
          {:noreply,
           socket
           |> assign(:versions, History.versions(entry.id))
           |> assign(:version, nil)
           |> put_flash(:info, "Restored. The previous text is still in the history.")
           |> render_preview()}

        {:error, _gone} ->
          {:noreply, put_flash(socket, :error, "That version is no longer available.")}
      end
    end)
  end

  def handle_event("base_view", %{"view" => view}, %{assigns: %{base: %{}}} = socket)
      when is_binary(view) do
    {:noreply, socket |> assign(:base_view, view) |> render_preview()}
  end

  def handle_event(_event_for_an_entry_no_longer_open, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:base, {:ok, {entry_id, result}}, socket) do
    case {socket.assigns.entry, result} do
      {%Entry{id: ^entry_id}, {:ok, base}} ->
        {:noreply, assign(socket, :base, base)}

      {%Entry{id: ^entry_id} = entry, {:error, problem}} ->
        notice = "> [!warning] This base could not be run: #{problem}\n\n"
        {:noreply, show_markdown(socket, entry, Sync.text(entry.id), notice)}

      _moved_on ->
        {:noreply, socket}
    end
  end

  def handle_async(:base, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:search, {:ok, {query, result}}, socket) do
    case {socket.assigns.finder, result} do
      {%{query: ^query} = finder, {:ok, found}} ->
        hits = Finder.hits(found, socket.assigns.entries)
        {:noreply, assign(socket, :finder, %{finder | hits: hits})}

      {%{query: ^query} = finder, {:error, _slow_or_invalid}} ->
        {:noreply, assign(socket, :finder, %{finder | hits: []})}

      _typed_more_or_closed ->
        {:noreply, socket}
    end
  end

  def handle_async(:search, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:linked_from, {:ok, {entry_id, notes}}, socket) do
    case socket.assigns do
      %{entry: %Entry{id: ^entry_id}, details: %{} = details} ->
        {:noreply, assign(socket, :details, %{details | linked_from: notes})}

      _moved_on_or_closed ->
        {:noreply, socket}
    end
  end

  def handle_async(:linked_from, {:exit, _reason}, socket), do: {:noreply, socket}

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
    {:noreply, socket |> assign(:preview_timer, nil) |> render_preview() |> outline()}
  end

  def handle_info(:list_entries, socket) do
    socket = assign(socket, :tree_timer, nil)
    {:noreply, if(socket.assigns.tree_stale, do: entries_changed(socket), else: socket)}
  end

  def handle_info({:awareness, _state}, socket), do: {:noreply, socket}

  defp entry_changed(changed, socket) do
    known =
      if changed.deleted_at,
        do: Map.delete(socket.assigns.known, changed.id),
        else: Map.put(socket.assigns.known, changed.id, changed)

    socket =
      socket
      |> assign(:latest, Map.put(socket.assigns.latest, changed.id, changed.seq))
      |> assign(:known, known)
      |> entries_changed()
      |> rerun_base()

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

  defp rerun_base(%{assigns: %{shown_as: :base, mode: :read, preview_timer: nil}} = socket),
    do:
      assign(socket, :preview_timer, Process.send_after(self(), :render_preview, @preview_delay))

  defp rerun_base(socket), do: socket

  defp close_details(%{assigns: %{details: nil}} = socket), do: socket
  defp close_details(socket), do: socket |> cancel_async(:linked_from) |> assign(:details, nil)

  defp show_details(%{assigns: %{details: %{}, entry: %Entry{kind: :doc} = entry}} = socket) do
    if Vaults.Path.markdown?(entry.path) do
      entries = socket.assigns.entries

      socket
      |> assign(:details, DetailsPanel.open(Sync.text(entry.id)))
      |> cancel_async(:linked_from)
      |> start_async(:linked_from, fn -> {entry.id, DetailsPanel.linked_from(entry, entries)} end)
    else
      close_details(socket)
    end
  end

  defp show_details(socket), do: close_details(socket)

  defp outline(%{assigns: %{details: %{} = details, entry: %Entry{kind: :doc} = entry}} = socket) do
    assign(socket, :details, %{
      details
      | headings: DetailsPanel.open(Sync.text(entry.id)).headings
    })
  end

  defp outline(socket), do: socket

  defp close_finder(%{assigns: %{finder: nil}} = socket), do: socket
  defp close_finder(socket), do: socket |> cancel_async(:search) |> assign(:finder, nil)

  defp open_created(socket, entry) do
    socket |> update(:notes_created, &(&1 + 1)) |> push_patch(to: Paths.entry(entry))
  end

  defp compare(%{assigns: %{entry: %Entry{} = entry, against: against}} = socket, version_id) do
    case History.compare(entry.id, version_id, if(against == :now, do: :now, else: :previous)) do
      {:ok, comparison} -> assign(socket, :version, comparison)
      {:error, :not_found} -> put_flash(socket, :error, "That version is no longer available.")
    end
  end

  defp version_id(sent) when is_binary(sent) do
    case Integer.parse(sent) do
      {id, ""} -> id
      _not_a_number -> 0
    end
  end

  defp version_id(sent) when is_integer(sent), do: sent
  defp version_id(_sent), do: 0

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
    socket
    |> assign(:latest, Map.new(entries, &{&1.id, &1.seq}))
    |> assign(:known, Map.new(entries, &{&1.id, &1}))
    |> list_entries()
  end

  defp entries_changed(%{assigns: %{tree_timer: nil}} = socket) do
    socket
    |> assign(:tree_timer, Process.send_after(self(), :list_entries, @tree_delay))
    |> list_entries()
  end

  defp entries_changed(socket), do: assign(socket, :tree_stale, true)

  defp list_entries(socket) do
    entries = socket.assigns.known |> Map.values() |> Enum.sort_by(& &1.path)

    socket
    |> assign(:tree_stale, false)
    |> assign(:entries, entries)
    |> assign(:link_index, Markdown.index(entries))
    |> assign(:tree, Tree.build(entries))
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
    |> assign(:mode, opening_mode(socket, previous, entry))
    |> assign(:entry, entry)
    |> assign(
      :page_title,
      if(entry, do: Path.basename(entry.path), else: socket.assigns.vault.name)
    )
    |> assign(:versions, nil)
    |> assign(:version, nil)
    |> assign(:blob_versions, nil)
    |> assign(:rename_form, nil)
    |> assign(:base_view, nil)
    |> render_preview()
    |> show_details_for(previous, entry)
  end

  defp show_details_for(socket, %Entry{id: id}, %Entry{id: id}), do: socket
  defp show_details_for(%{assigns: %{details: nil}} = socket, _previous, _entry), do: socket
  defp show_details_for(socket, _previous, _entry), do: show_details(socket)

  defp opening_mode(socket, %Entry{id: id}, %Entry{id: id}), do: socket.assigns.mode

  defp opening_mode(socket, _previous, entry),
    do: if(drawn?(entry), do: :read, else: socket.assigns.note_mode)

  defp drawn?(%Entry{kind: :doc, path: path}),
    do: String.downcase(Path.extname(path)) in ~w(.canvas .base)

  defp drawn?(_entry), do: false

  defp render_preview(%{assigns: %{entry: %Entry{kind: :doc} = entry, mode: :read}} = socket) do
    text = Sync.text(entry.id)

    case String.downcase(Path.extname(entry.path)) do
      ".canvas" -> show_canvas(socket, entry, text)
      ".base" -> show_base(socket, entry, text)
      _note -> show_markdown(socket, entry, text)
    end
  end

  defp render_preview(socket), do: socket |> assign(:preview, nil) |> assign(:base, nil)

  defp show_markdown(socket, entry, text, notice \\ "") do
    html = Markdown.to_html(notice <> readable(entry, text), socket.assigns.link_index, links())
    socket |> assign(:shown_as, :markdown) |> assign(:base, nil) |> assign(:preview, html)
  end

  defp show_canvas(socket, entry, text) do
    case Canvas.to_html(text, socket.assigns.link_index, links()) do
      {:ok, html} ->
        socket |> assign(:shown_as, :canvas) |> assign(:base, nil) |> assign(:preview, html)

      :error ->
        show_markdown(socket, entry, text, "> [!warning] This canvas is not valid JSON.\n\n")
    end
  end

  defp show_base(socket, entry, text) do
    socket = socket |> assign(:shown_as, :base) |> assign(:preview, nil)

    socket =
      if match?(%{entry_id: id} when id == entry.id, socket.assigns.base),
        do: socket,
        else: assign(socket, :base, nil)

    if connected?(socket) do
      %{current_scope: scope, vault: vault, base_view: wanted, entries: entries} = socket.assigns

      socket
      |> cancel_async(:base)
      |> start_async(:base, fn ->
        {entry.id, BaseView.run(scope, vault.id, entry, text, wanted, entries)}
      end)
    else
      socket
    end
  end

  defp links do
    %{note: &Paths.entry/1, raw: &Paths.raw/1, text: &readable(&1, Sync.text(&1.id))}
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div
        id="vault"
        class="flex h-dvh pl-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)]"
      >
        <Sidebar.sidebar
          entry={@entry}
          writable={@writable}
          admin={@admin}
          new_form={@new_form}
          notes_created={@notes_created}
          vault={@vault}
          vaults={@vaults}
          socket_token={@socket_token}
          tree={@tree}
          open_folders={@open_folders}
          current_scope={@current_scope}
        />

        <section class={[
          "min-w-0 flex-1 flex-col bg-surface pb-[env(safe-area-inset-bottom)] pt-[env(safe-area-inset-top)] md:flex",
          if(@entry, do: "flex", else: "hidden")
        ]}>
          <Reader.welcome entry={@entry} vault={@vault} empty={@entries == []} />
          <Reader.toolbar
            entry={@entry}
            vault={@vault}
            writable={@writable}
            mode={@mode}
            rename_form={@rename_form}
          />
          <Reader.editor
            entry={@entry}
            mode={@mode}
            writable={@writable}
            socket_token={@socket_token}
            user={@current_scope.user}
          />
          <Reader.note entry={@entry} mode={@mode} shown_as={@shown_as} preview={@preview} />
          <Reader.base entry={@entry} mode={@mode} shown_as={@shown_as} base={@base} />
          <Reader.attachment entry={@entry} />
        </section>

        <HistoryPanel.note_history
          versions={@versions}
          version={@version}
          against={@against}
          writable={@writable}
        />
        <DetailsPanel.details details={@details} entry={@entry} />
        <Finder.finder finder={@finder} />
        <HistoryPanel.attachment_history
          blob_versions={@blob_versions}
          entry={@entry}
          writable={@writable}
        />
      </div>
    </Layouts.app>
    """
  end
end
