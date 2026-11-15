defmodule BabelSyncWeb.VaultLive.Sources do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Sources, Vaults}
  alias BabelSync.Sources.{Script, Secrets, Source}
  alias BabelSync.Vaults.{Entry, Vault}
  alias BabelSyncWeb.Paths

  @impl true
  def mount(%{"vault_id" => vault_id}, _session, socket) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         true <- Sources.enabled?(),
         :ok <- Scope.authorize(socket.assigns.current_scope, vault_id, :admin),
         %Vault{} = vault <- Vaults.get_vault(vault_id) do
      if connected?(socket) do
        :ok = Sources.subscribe(vault.id)
        :ok = Vaults.subscribe(vault.id)
      end

      {:ok,
       socket
       |> assign(:page_title, "#{vault.name} sources")
       |> assign(:vault, vault)
       |> assign(:may_approve, Sources.browser_admin?(socket.assigns.current_scope, vault.id))
       |> stream_configure(:sources, dom_id: &"source-#{&1.entry.id}")
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
    with %Source{vault_id: vault_id} = source <- Sources.get(id),
         true <- vault_id == socket.assigns.vault.id,
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
    if MapSet.member?(socket.assigns.shown, id),
      do: {:noreply, load(socket)},
      else: {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load(socket) do
    sources =
      for draft <- Sources.drafts(socket.assigns.vault.id) do
        Map.merge(draft, %{
          runs: if(draft.source, do: Sources.runs(draft.source, 5), else: []),
          saved: if(draft.source, do: Secrets.names(draft.source), else: [])
        })
      end

    socket
    |> assign(:shown, MapSet.new(sources, & &1.entry.id))
    |> assign(:none, sources == [])
    |> stream(:sources, sources, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl space-y-8 pb-12 pt-7 md:pb-20 md:pt-10">
        <.header>
          <:trail>
            <.back_link navigate={~p"/v/#{@vault.id}/settings"}>Back to settings</.back_link>
          </:trail>
          Sources
          <:subtitle>
            Scripts in {@vault.name} that the server runs to bring outside data in. A
            <code class="font-mono text-[0.9em] text-ink">.js</code>
            file in the sources folder that opens with a
            <code class="font-mono text-[0.9em] text-ink">/* source</code>
            comment shows up here, and writes in the folder beside it that has its name. Nothing
            runs until you approve what it asks for. After that the script can be edited freely,
            unless it is given a secret.
          </:subtitle>
        </.header>

        <p
          :if={not @may_approve}
          id="sources-read-only"
          class="rounded-xl border border-warn/40 bg-warn/10 p-4 text-sm text-ink"
        >
          Approving and changing sources takes an owner signed in here in the browser.
        </p>

        <p
          :if={@none}
          id="sources-empty"
          class="rounded-xl border border-dashed border-line-strong p-8 text-center text-sm text-muted"
        >
          <%= if @vault.sources_folder do %>
            No file in <span class="text-ink">{@vault.sources_folder}</span>
            opens with a <code class="font-mono text-[0.9em] text-ink">/* source</code>
            comment yet.
          <% else %>
            This vault has no sources folder yet.
            <.link navigate={~p"/v/#{@vault.id}/settings#sources"} class="text-ink underline">
              Pick one in settings
            </.link>
          <% end %>
        </p>

        <div id="sources" phx-update="stream" class="space-y-6">
          <article
            :for={{id, item} <- @streams.sources}
            id={id}
            class="overflow-hidden rounded-xl border border-line bg-surface shadow-raise"
          >
            <header class="flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-line px-4 py-3">
              <h2 class="min-w-0 flex-1 basis-full break-words font-medium text-ink sm:basis-0">
                <.link
                  navigate={Paths.vault(@vault.id) <> "/f/" <> item.entry.path}
                  class="hover:underline"
                >
                  {item.name}
                </.link>
              </h2>
              <.badge class={status_class(item)}>{status_label(item)}</.badge>
              <div :if={item.source && @may_approve} class="flex items-center gap-1.5">
                <.button
                  id={"run-#{item.entry.id}"}
                  size="sm"
                  phx-click="run"
                  phx-value-source={item.source.id}
                >
                  <.icon name="hero-play-mini" class="size-4" /> Run now
                </.button>
                <.button
                  :if={item.source.enabled}
                  id={"pause-#{item.entry.id}"}
                  size="sm"
                  variant="ghost"
                  phx-click="pause"
                  phx-value-source={item.source.id}
                >
                  Pause
                </.button>
                <.button
                  :if={not item.source.enabled}
                  id={"resume-#{item.entry.id}"}
                  size="sm"
                  variant="ghost"
                  phx-click="resume"
                  phx-value-source={item.source.id}
                >
                  Resume
                </.button>
                <.button
                  id={"revoke-#{item.entry.id}"}
                  size="sm"
                  variant="danger-ghost"
                  phx-click="revoke"
                  phx-value-source={item.source.id}
                  data-confirm={"Stop running #{item.name} and forget its secrets and which notes are its own?"}
                >
                  Revoke
                </.button>
              </div>
            </header>

            <div
              :if={attention = item.source && attention(item.source)}
              id={"attention-#{item.entry.id}"}
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

            <ul :if={match?({:error, _}, item.script)} class="space-y-1 px-4 py-3 text-sm text-danger">
              <li :for={problem <- elem(item.script, 1)}>{problem}</li>
            </ul>

            <div
              :if={item.status in [:new, :changed]}
              class="space-y-3 border-b border-line px-4 py-4"
            >
              <p class="text-sm text-muted">
                {if item.status == :new,
                  do: "This script has not been approved. It asks for:",
                  else:
                    "This differs from what you approved. Until you approve it, the script keeps running as it was. It now asks for:"}
              </p>
              <.asks script={elem(item.script, 1)} />
              <pre
                id={"code-#{item.entry.id}"}
                class="max-h-96 overflow-auto rounded-lg border border-line bg-sunken p-3 font-mono text-xs leading-relaxed"
                phx-no-curly-interpolation
              ><%= for {kind, line} <- lines(item) do %><span class={line_class(kind)}><%= mark(kind) %><%= line %>
    </span><% end %></pre>
              <.button
                :if={@may_approve}
                id={"approve-#{item.entry.id}"}
                variant="primary"
                phx-click="approve"
                phx-value-entry={item.entry.id}
                phx-value-hash={Script.hash(elem(item.script, 1))}
              >
                Approve what is shown
              </.button>
            </div>

            <div :if={item.source} class="divide-y divide-line">
              <div :if={item.status == :approved} class="px-4 py-3">
                <.asks script={elem(item.script, 1)} />
              </div>

              <div
                :for={{name, secret} <- secrets(item)}
                class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3"
              >
                <div class="min-w-0 flex-1 basis-48">
                  <p class="text-sm font-medium text-ink">Secret: {name}</p>
                  <p class="text-xs text-faint">
                    Sent to {secret.host} as {secret.header}. {if name in item.saved,
                      do: "Saved; it cannot be shown again.",
                      else: "Not saved yet."}
                  </p>
                </div>
                <form
                  :if={@may_approve}
                  id={"secret-#{item.entry.id}-#{name}"}
                  phx-submit="save_secret"
                  class="flex items-center gap-2"
                >
                  <input type="hidden" name="source" value={item.source.id} />
                  <input type="hidden" name="name" value={name} />
                  <input
                    type="password"
                    name="value"
                    autocomplete="off"
                    aria-label={"Secret #{name}"}
                    placeholder={if name in item.saved, do: "Replace", else: "Paste it here"}
                    class={[field_class(), "h-8 w-44 px-2.5 text-sm"]}
                  />
                  <.button size="sm">Save</.button>
                  <.icon_button
                    :if={name in item.saved}
                    type="button"
                    phx-click="forget_secret"
                    phx-value-source={item.source.id}
                    phx-value-name={name}
                    icon="hero-x-mark"
                    label="Forget"
                    tone="danger"
                  />
                </form>
              </div>

              <div class="px-4 py-3">
                <p class="text-xs font-semibold uppercase tracking-[0.1em] text-muted">Runs</p>
                <p :if={item.runs == []} class="mt-2 text-sm text-faint">
                  {if item.source.next_run_at,
                    do: "First run due #{at(item.source.next_run_at)}.",
                    else: "Has not run. It has no schedule; use Run now."}
                </p>
                <ul class="mt-2 space-y-2">
                  <li :for={run <- item.runs} id={"run-#{run.id}"} class="text-sm">
                    <details class="group">
                      <summary class={[
                        "flex list-none flex-wrap items-center gap-x-3 gap-y-1 [&::-webkit-details-marker]:hidden",
                        logged?(run) && "cursor-pointer"
                      ]}>
                        <span class={["size-2 shrink-0 rounded-full", run_dot(run.status)]}></span>
                        <span class="text-ink">{run_label(run)}</span>
                        <.local_time
                          id={"run-time-#{run.id}"}
                          at={run.finished_at || run.started_at || run.inserted_at}
                        />
                        <span
                          :if={logged?(run)}
                          class="ml-auto inline-flex items-center gap-1 text-xs text-muted transition group-hover:text-ink"
                        >
                          Log
                          <.icon
                            name="hero-chevron-down-mini"
                            class="size-4 transition group-open:rotate-180"
                          />
                        </span>
                        <span
                          :if={run.status == :done}
                          id={"outcome-#{run.id}"}
                          class="basis-full text-muted"
                        >
                          {outcome(run)}
                        </span>
                        <span :if={run.error} class="min-w-0 basis-full truncate text-danger">
                          {first_line(run.error)}
                        </span>
                      </summary>
                      <pre
                        :if={logged?(run)}
                        class="mt-2 max-h-64 overflow-auto rounded-lg border border-line bg-sunken p-3 font-mono text-xs"
                        phx-no-curly-interpolation
                      ><%= run.error && run.error <> "\n" %><%= run.log %></pre>
                    </details>
                  </li>
                </ul>
                <p
                  :if={item.runs != [] and item.source.enabled and item.source.next_run_at}
                  class="mt-2 text-xs text-faint"
                >
                  Next run
                  <.local_time id={"next-run-#{item.entry.id}"} at={item.source.next_run_at} />.
                </p>
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

  defp status_label(%{status: :invalid}), do: "Cannot be read"
  defp status_label(%{status: :new}), do: "Not approved"
  defp status_label(%{status: :changed}), do: "Changed since approval"
  defp status_label(%{source: %Source{enabled: false}}), do: "Paused"
  defp status_label(%{status: :approved}), do: "Approved"

  defp status_class(%{status: :invalid}), do: "border-danger/50 text-danger"

  defp status_class(%{status: status}) when status in [:new, :changed],
    do: "border-warn/60 text-ink"

  defp status_class(%{source: %Source{enabled: false}}), do: nil
  defp status_class(_approved), do: "border-added/60 text-ink"

  defp run_dot(:done), do: "bg-added"
  defp run_dot(:failed), do: "bg-danger"
  defp run_dot(_waiting), do: "animate-pulse bg-warn"

  defp run_label(%{status: :queued}), do: "Waiting to run"
  defp run_label(%{status: :running}), do: "Running"
  defp run_label(%{status: :done, trigger: trigger}), do: "Ran #{started_by(trigger)}"
  defp run_label(%{status: :failed, trigger: trigger}), do: "Failed #{started_by(trigger)}"

  defp started_by("schedule"), do: "on schedule"
  defp started_by("manual"), do: "by hand"
  defp started_by(other), do: "(#{other})"

  defp logged?(run), do: is_binary(run.error) or run.log != ""

  defp outcome(%{created: 0, changed: 0, unchanged: 0}), do: "Looked at no notes."

  defp outcome(%{created: created, changed: changed, unchanged: unchanged}) do
    looked = created + changed + unchanged

    changes =
      for {count, what} <- [{created, "new"}, {changed, "updated"}],
          count > 0,
          do: "#{count} #{what}"

    "Looked at #{looked} #{if looked == 1, do: "note", else: "notes"}: " <>
      case changes do
        [] -> "nothing to change."
        some -> Enum.join(some, ", ") <> ", #{unchanged} left as they were."
      end
  end

  attr :id, :string, required: true
  attr :at, DateTime, required: true

  defp local_time(assigns) do
    ~H"""
    <time id={@id} datetime={DateTime.to_iso8601(@at)} phx-hook=".LocalTime" class="text-faint">
      {at(@at)}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() { this.show() },
        updated() { this.show() },
        show() {
          const at = new Date(this.el.dateTime)
          if (Number.isNaN(at.getTime())) return
          this.el.textContent = at.toLocaleString(undefined, {
            day: "numeric", month: "short", hour: "numeric", minute: "2-digit"
          })
        }
      }
    </script>
    """
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp at(%DateTime{} = time), do: Calendar.strftime(time, "%-d %b %H:%M UTC")
end
