defmodule BabelSyncWeb.VaultLive.Source do
  use BabelSyncWeb, :live_view

  import BabelSyncWeb.SourceComponents

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Sources, Vaults}
  alias BabelSync.Sources.{Items, Script, Secrets, Source}
  alias BabelSync.Vaults.{Entry, Vault}
  alias BabelSyncWeb.Paths

  @impl true
  def mount(%{"vault_id" => vault_id, "entry_id" => entry_id}, _session, socket) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         true <- Sources.enabled?(),
         :ok <- Scope.authorize(socket.assigns.current_scope, vault_id, :admin),
         %Vault{} = vault <- Vaults.get_vault(vault_id) do
      if connected?(socket) do
        :ok = Sources.subscribe(vault.id)
        :ok = Vaults.subscribe(vault.id)
      end

      {:ok,
       socket
       |> assign(:vault, vault)
       |> assign(:entry_id, entry_id)
       |> assign(:may_approve, Sources.browser_admin?(socket.assigns.current_scope, vault.id))
       |> load()}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, "Only an owner can look after a vault's sources.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("approve", %{"entry" => entry_id, "hash" => hash}, socket) do
    case Sources.approve(socket.assigns.current_scope, entry_id, hash) do
      {:ok, _source} ->
        {:noreply, load(socket)}

      {:error, :changed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "The file changed while you were reading it. Look again, then approve."
         )
         |> load()}

      {:error, _refused} ->
        {:noreply,
         put_flash(socket, :error, "Approving takes an owner signed in here in the browser.")}
    end
  end

  def handle_event("run", %{"source" => id}, socket),
    do: change(socket, id, &Sources.run_now(socket.assigns.current_scope, &1))

  def handle_event("pause", %{"source" => id}, socket),
    do: change(socket, id, &Sources.set_enabled(socket.assigns.current_scope, &1, false))

  def handle_event("resume", %{"source" => id}, socket),
    do: change(socket, id, &Sources.set_enabled(socket.assigns.current_scope, &1, true))

  def handle_event("revoke", %{"source" => id}, socket),
    do: change(socket, id, &Sources.revoke(socket.assigns.current_scope, &1))

  def handle_event("save_secret", %{"source" => id, "name" => name, "value" => value}, socket)
      when value != "" do
    change(socket, id, &Sources.put_secret(socket.assigns.current_scope, &1, name, value))
  end

  def handle_event("save_secret", _params, socket), do: {:noreply, socket}

  def handle_event("forget_secret", %{"source" => id, "name" => name}, socket),
    do: change(socket, id, &Sources.delete_secret(socket.assigns.current_scope, &1, name))

  defp change(socket, id, change) do
    with %Source{vault_id: vault_id, entry_id: entry_id} = source <- Sources.get(id),
         true <- vault_id == socket.assigns.vault.id and entry_id == socket.assigns.entry_id,
         :ok <- change.(source) do
      {:noreply, load(socket)}
    else
      _refused ->
        {:noreply,
         put_flash(socket, :error, "That takes an owner signed in here in the browser.")}
    end
  end

  @impl true
  def handle_info({:source_changed, _id}, socket), do: {:noreply, load(socket)}

  def handle_info({:entry_changed, %Entry{id: id}}, socket) do
    if id == socket.assigns.entry_id, do: {:noreply, load(socket)}, else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load(socket) do
    item =
      case Enum.find(
             Sources.drafts(socket.assigns.vault.id),
             &(&1.entry.id == socket.assigns.entry_id)
           ) do
        nil ->
          nil

        draft ->
          Map.merge(draft, %{
            runs: if(draft.source, do: Sources.runs(draft.source, 20), else: []),
            saved: if(draft.source, do: Secrets.names(draft.source), else: []),
            current: if(draft.source, do: Items.counts(draft.source, "").current, else: 0)
          })
      end

    socket
    |> assign(:item, item)
    |> assign(:page_title, if(item, do: item.name, else: "#{socket.assigns.vault.name} sources"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl space-y-8 pb-12 pt-7 md:pb-20 md:pt-10">
        <.header>
          <:trail>
            <.back_link navigate={~p"/v/#{@vault.id}/settings"} />
          </:trail>
          {if @item, do: @item.name, else: "Source"}
          <:subtitle :if={@item}>
            <.link
              navigate={Paths.vault(@vault.id) <> "/f/" <> @item.entry.path}
              class="text-ink hover:underline"
            >
              {@item.entry.path}
            </.link>
            in {@vault.name}. The server runs it to bring outside data into the folder beside it.
          </:subtitle>
          <:actions :if={@item && @item.source}>
            <.button
              id="source-notes"
              size="sm"
              navigate={~p"/v/#{@vault.id}/sources/#{@entry_id}/notes"}
            >
              <.icon name="hero-document-text-mini" class="size-4" /> Notes
              <span class="tabular-nums text-faint">{@item.current}</span>
            </.button>
          </:actions>
        </.header>

        <p
          :if={not @may_approve}
          id="sources-read-only"
          class="rounded-xl border border-warn/40 bg-warn/10 p-4 text-sm text-ink"
        >
          Approving and changing sources takes an owner signed in here in the browser.
        </p>

        <p
          :if={is_nil(@item)}
          id="source-gone"
          class="rounded-xl border border-dashed border-line-strong p-8 text-center text-sm text-muted"
        >
          There is no source here any more. Its file was deleted, moved out of the sources
          folder, or no longer opens with a
          <code class="font-mono text-[0.9em] text-ink">/* source</code>
          comment.
        </p>

        <div :if={@item} id="sources" class="space-y-6">
          <article
            id={"source-#{@item.entry.id}"}
            class="overflow-hidden rounded-xl border border-line bg-surface shadow-raise"
          >
            <header class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-line px-4 py-3">
              <.badge class={status_class(@item)}>{status_label(@item)}</.badge>
              <span class="flex-1"></span>
              <div :if={@item.source && @may_approve} class="flex items-center gap-1.5">
                <.button
                  id={"run-#{@item.entry.id}"}
                  size="sm"
                  phx-click="run"
                  phx-value-source={@item.source.id}
                >
                  <.icon name="hero-play-mini" class="size-4" /> Run now
                </.button>
                <.button
                  :if={@item.source.enabled}
                  id={"pause-#{@item.entry.id}"}
                  size="sm"
                  variant="ghost"
                  phx-click="pause"
                  phx-value-source={@item.source.id}
                >
                  Pause
                </.button>
                <.button
                  :if={not @item.source.enabled}
                  id={"resume-#{@item.entry.id}"}
                  size="sm"
                  variant="ghost"
                  phx-click="resume"
                  phx-value-source={@item.source.id}
                >
                  Resume
                </.button>
                <.button
                  id={"revoke-#{@item.entry.id}"}
                  size="sm"
                  variant="danger-ghost"
                  phx-click="revoke"
                  phx-value-source={@item.source.id}
                  data-confirm={"Stop running #{@item.name} and forget its secrets and which notes are its own?"}
                >
                  Revoke
                </.button>
              </div>
            </header>

            <div
              :if={attention = @item.source && attention(@item.source)}
              id={"attention-#{@item.entry.id}"}
              class="flex flex-wrap items-center gap-3 border-b border-line bg-warn/10 px-4 py-3 text-sm text-ink"
            >
              <.icon name="hero-bell-alert-mini" class="size-4 text-warn" />
              <span class="min-w-0 flex-1">{attention["message"]}</span>
              <a
                :if={attention["url"]}
                href={attention["url"]}
                target="_blank"
                rel="noopener noreferrer"
                class="inline-flex h-8 items-center rounded-lg border border-line-strong bg-surface px-3 text-sm font-medium text-ink shadow-raise transition-colors hover:border-faint hover:bg-canvas"
              >
                Open {URI.parse(attention["url"]).host}
              </a>
            </div>

            <ul
              :if={match?({:error, _}, @item.script)}
              class="space-y-1 px-4 py-3 text-sm text-danger"
            >
              <li :for={problem <- elem(@item.script, 1)}>{problem}</li>
            </ul>

            <div
              :if={@item.status in [:new, :changed]}
              class="space-y-3 border-b border-line px-4 py-4"
            >
              <p class="text-sm text-muted">
                {if @item.status == :new,
                  do: "This script has not been approved. It asks for:",
                  else:
                    "This differs from what you approved. Until you approve it, the script keeps running as it was. It now asks for:"}
              </p>
              <.asks script={elem(@item.script, 1)} />
              <pre
                id={"code-#{@item.entry.id}"}
                class="max-h-96 overflow-auto rounded-lg border border-line bg-sunken p-3 font-mono text-xs leading-relaxed"
                phx-no-curly-interpolation
              ><%= for {kind, line} <- lines(@item) do %><span class={line_class(kind)}><%= mark(kind) %><%= line %>
    </span><% end %></pre>
              <.button
                :if={@may_approve}
                id={"approve-#{@item.entry.id}"}
                variant="primary"
                phx-click="approve"
                phx-value-entry={@item.entry.id}
                phx-value-hash={Script.hash(elem(@item.script, 1))}
              >
                Approve what is shown
              </.button>
            </div>

            <div :if={@item.source} class="divide-y divide-line">
              <div :if={@item.status == :approved} class="space-y-3 px-4 py-3">
                <.asks script={elem(@item.script, 1)} />
                <details class="group">
                  <summary class="inline-flex cursor-pointer list-none items-center gap-1 text-sm text-muted transition hover:text-ink [&::-webkit-details-marker]:hidden">
                    Script
                    <.icon
                      name="hero-chevron-down-mini"
                      class="size-4 transition group-open:rotate-180"
                    />
                  </summary>
                  <pre
                    id={"code-#{@item.entry.id}"}
                    class="mt-2 max-h-96 overflow-auto rounded-lg border border-line bg-sunken p-3 font-mono text-xs leading-relaxed"
                    phx-no-curly-interpolation
                  ><%= elem(@item.script, 1).code %></pre>
                </details>
              </div>

              <div
                :for={{name, secret} <- secrets(@item)}
                class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3"
              >
                <div class="min-w-0 flex-1 basis-48">
                  <p class="text-sm font-medium text-ink">Secret: {name}</p>
                  <p class="text-xs text-faint">
                    Sent to {secret.host} as {secret.header}. {if name in @item.saved,
                      do: "Saved; it cannot be shown again.",
                      else: "Not saved yet."}
                  </p>
                </div>
                <form
                  :if={@may_approve}
                  id={"secret-#{@item.entry.id}-#{name}"}
                  phx-submit="save_secret"
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="source" value={@item.source.id} />
                  <input type="hidden" name="name" value={name} />
                  <input
                    type="password"
                    name="value"
                    autocomplete="off"
                    aria-label={"Secret #{name}"}
                    placeholder={if name in @item.saved, do: "Replace", else: "Paste it here"}
                    class={[field_class(), "h-8 w-44 px-2.5 text-sm"]}
                  />
                  <.button size="sm">Save</.button>
                  <.icon_button
                    :if={name in @item.saved}
                    type="button"
                    phx-click="forget_secret"
                    phx-value-source={@item.source.id}
                    phx-value-name={name}
                    icon="hero-x-mark"
                    label="Forget"
                    tone="danger"
                  />
                </form>
              </div>

              <div class="px-4 py-3">
                <div class="flex items-baseline justify-between gap-x-3">
                  <p class="text-xs font-semibold uppercase tracking-[0.1em] text-muted">Runs</p>
                  <p
                    :if={@item.source.enabled and @item.source.next_run_at}
                    id={"next-run-line-#{@item.entry.id}"}
                    class="text-xs text-faint"
                  >
                    Next run
                    <.local_time id={"next-run-#{@item.entry.id}"} at={@item.source.next_run_at} />
                  </p>
                </div>
                <p :if={@item.runs == []} class="mt-2 text-sm text-faint">
                  Has not run yet.
                  <span :if={is_nil(@item.source.next_run_at)}>It has no schedule; use Run now.</span>
                </p>
                <ul class="mt-2 space-y-2">
                  <li :for={run <- @item.runs} id={"run-#{run.id}"} class="text-sm">
                    <details
                      id={"run-details-#{run.id}"}
                      class="group"
                      phx-mounted={JS.ignore_attributes("open")}
                    >
                      <summary class={[
                        "flex list-none items-center gap-x-3 [&::-webkit-details-marker]:hidden",
                        logged?(run) && "cursor-pointer"
                      ]}>
                        <span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-3 gap-y-1">
                          <span class={["size-2 shrink-0 rounded-full", run_dot(run.status)]}></span>
                          <span class="text-ink">{run_label(run)}</span>
                          <.local_time
                            id={"run-time-#{run.id}"}
                            at={run.finished_at || run.started_at || run.inserted_at}
                          />
                          <span :if={run.error} class="min-w-0 basis-full truncate text-danger">
                            {first_line(run.error)}
                          </span>
                        </span>
                        <span
                          :if={run.status == :done}
                          id={"outcome-#{run.id}"}
                          class="shrink-0 text-right tabular-nums text-muted"
                        >
                          {outcome(run)}
                        </span>
                        <.icon
                          name="hero-chevron-right-mini"
                          class={[
                            "size-4 shrink-0 text-faint transition-transform duration-200 ease-out group-open:rotate-90 group-hover:text-ink",
                            not logged?(run) && "invisible"
                          ]}
                        />
                      </summary>
                      <pre
                        :if={logged?(run)}
                        class="mt-2 max-h-64 overflow-auto rounded-lg border border-line bg-sunken p-3 font-mono text-xs"
                        phx-no-curly-interpolation
                      ><%= run.error && run.error <> "\n" %><%= run.log %></pre>
                    </details>
                  </li>
                </ul>
              </div>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :script, Script, required: true

  defp asks(assigns) do
    ~H"""
    <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
      <dt class="text-muted">Runs</dt>
      <dd class="text-ink">{every(@script.schedule)}</dd>
      <dt class="text-muted">Fetches from</dt>
      <dd class="text-ink">{listed(@script.hosts, "nowhere")}</dd>
      <dt class="text-muted">Writes notes in</dt>
      <dd class="text-ink">{listed(@script.writes, "nowhere")}</dd>
      <dt :if={@script.reads != []} class="text-muted">Also reads</dt>
      <dd :if={@script.reads != []} class="text-ink">{listed(@script.reads, "")}</dd>
      <dt :if={@script.secrets != %{}} class="text-muted">Secrets</dt>
      <dd :if={@script.secrets != %{}} class="text-ink">
        {Enum.map_join(@script.secrets, ", ", fn {name, secret} -> "#{name} to #{secret.host}" end)}
      </dd>
    </dl>
    """
  end

  defp every(nil), do: "only when you press Run now"
  defp every(seconds) when rem(seconds, 86_400) == 0, do: "every #{div(seconds, 86_400)} d"
  defp every(seconds) when rem(seconds, 3600) == 0, do: "every #{div(seconds, 3600)} h"
  defp every(seconds), do: "every #{div(seconds, 60)} min"

  defp listed([], none), do: none
  defp listed(items, _none), do: Enum.join(items, ", ")

  defp secrets(%{status: :invalid}), do: []

  defp secrets(%{source: %Source{} = source}),
    do: Script.from_manifest(source.manifest, source.code).secrets

  defp attention(%Source{attention: nil}), do: nil
  defp attention(%Source{attention: attention}), do: Jason.decode!(attention)

  defp lines(%{status: :changed, source: source, script: {:ok, script}}) do
    before =
      String.split(
        Script.manifest(Script.from_manifest(source.manifest, source.code)) <>
          "\n\n" <> source.code,
        "\n"
      )

    now = String.split(Script.manifest(script) <> "\n\n" <> script.code, "\n")

    for {kind, lines} <- List.myers_difference(before, now), line <- lines, do: {kind, line}
  end

  defp lines(%{script: {:ok, script}}),
    do: for(line <- String.split(script.code, "\n"), do: {:eq, line})

  defp mark(:ins), do: "+ "
  defp mark(:del), do: "- "
  defp mark(:eq), do: "  "

  defp line_class(:ins), do: "block bg-added/15 text-ink"
  defp line_class(:del), do: "block bg-danger/10 text-danger"
  defp line_class(:eq), do: "block text-muted"

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()
end
