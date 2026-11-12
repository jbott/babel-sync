defmodule BabelSyncWeb.VaultLive.Connect do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.Obsidian.Plugin
  alias BabelSync.Vaults
  alias BabelSync.Vaults.Vault
  alias BabelSyncWeb.Paths

  @plugin_choices [
    {"ready", "hero-check-circle", "Obsidian already has Babel Sync"},
    {"install", "hero-arrow-down-tray", "Install it first"}
  ]

  @devices [
    {"iphone", "iPhone or iPad"},
    {"android", "Android"},
    {"computer", "Computer"}
  ]

  @impl true
  def mount(%{"vault_id" => vault_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         %Vault{} = vault <- Vaults.get_vault(vault_id) do
      server_url = BabelSyncWeb.Endpoint.url()

      {:ok,
       socket
       |> assign(:page_title, "Connect Obsidian to #{vault.name}")
       |> assign(:vault, vault)
       |> assign(:folder, Plugin.folder_name(vault.name))
       |> assign(:available?, Plugin.available?())
       |> assign(:version, plugin_label())
       |> assign(:server_url, server_url)
       |> assign(:deep_link, deep_link(server_url, vault))
       |> assign(:plugin_choices, @plugin_choices)
       |> assign(:devices, @devices)
       |> assign(:detected, detect(get_connect_info(socket, :user_agent)))}
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
    {:noreply,
     socket
     |> assign(:plugin, known(params["plugin"], @plugin_choices, "ready"))
     |> assign(:device, known(params["device"], @devices, socket.assigns.detected))}
  end

  defp known(value, choices, fallback) do
    if Enum.any?(choices, &(elem(&1, 0) == value)), do: value, else: fallback
  end

  defp deep_link(server_url, vault) do
    "obsidian://babelsync-connect?" <>
      URI.encode_query(%{"server" => server_url, "id" => vault.id, "name" => vault.name})
  end

  defp detect(agent) when is_binary(agent) do
    cond do
      agent =~ ~r/iPhone|iPad|iPod/ -> "iphone"
      agent =~ "Android" -> "android"
      true -> "computer"
    end
  end

  defp detect(_agent), do: "iphone"

  defp choose(vault, plugin, device),
    do: ~p"/v/#{vault.id}/connect?#{[plugin: plugin, device: device]}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-9 pb-12 pt-6 md:pb-20 md:pt-9">
        <.header>
          <:trail>
            <.back_link id="connect-back" navigate={Paths.vault(@vault.id)}>
              Back to {@vault.name}
            </.back_link>
          </:trail>
          Connect Obsidian
          <:subtitle>
            <span id="connect-vault" class="font-medium text-ink">{@vault.name}</span>
            can live in Obsidian on each of your devices and stay in sync as you type.
          </:subtitle>
        </.header>

        <ol id="steps">
          <.step number={1} title="Get the plugin">
            <nav
              id="plugin-choice"
              aria-label="Plugin"
              class="grid gap-1 rounded-xl border border-line bg-sunken p-1 sm:grid-cols-2"
            >
              <.link
                :for={{key, icon, label} <- @plugin_choices}
                id={"plugin-#{key}"}
                patch={choose(@vault, key, @device)}
                aria-current={key == @plugin && "true"}
                class={[
                  "flex min-h-11 items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition-colors duration-150",
                  if(key == @plugin,
                    do: "bg-surface text-ink shadow-raise",
                    else: "text-muted hover:text-ink"
                  )
                ]}
              >
                <.icon name={icon} class="size-[1.125rem] shrink-0" /> {label}
              </.link>
            </nav>

            <p :if={@plugin == "ready"} id="plugin-ready-note" class="text-sm leading-6 text-muted">
              Then there is nothing to do here. That is the case when the vault came from another
              device that already syncs it, or you installed the plugin before.
            </p>

            <div :if={@plugin == "install"} id="install" class="space-y-4">
              <p class="text-sm leading-6 text-muted">
                Obsidian can only install a plugin from a link once it is in its community
                directory, and Babel Sync is not there yet. Until then it goes in by hand, once per
                device.
              </p>

              <p
                :if={not @available?}
                id="plugin-unavailable"
                class="flex gap-2.5 rounded-lg border border-line bg-sunken px-3 py-2.5 text-sm text-muted"
              >
                <.icon name="hero-wrench-screwdriver-mini" class="mt-0.5 size-4 shrink-0" />
                <span>
                  This server was built without the plugin, so there is nothing to download. Build
                  it with <code class="font-mono text-xs text-ink">mix plugin.build</code>.
                </span>
              </p>

              <.group id="install-new">
                <div class="space-y-3 px-4 py-4">
                  <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
                    <h3 class="text-base font-medium text-ink">Start a new Obsidian vault</h3>
                    <nav id="devices" aria-label="Device" class="flex gap-1 text-xs font-medium">
                      <.link
                        :for={{key, label} <- @devices}
                        id={"device-#{key}"}
                        patch={choose(@vault, @plugin, key)}
                        aria-current={key == @device && "true"}
                        class={[
                          "flex h-8 items-center rounded-full border px-2.5 transition-colors duration-150",
                          if(key == @device,
                            do: "border-line-strong bg-canvas text-ink",
                            else: "border-transparent text-muted hover:text-ink"
                          )
                        ]}
                      >
                        {label}
                      </.link>
                    </nav>
                  </div>
                  <.download
                    :if={@available?}
                    id="download-vault"
                    href={~p"/v/#{@vault.id}/obsidian/vault.zip"}
                    label="Download the vault folder"
                    version={@version}
                  />
                  <ol id="install-new-steps" class="space-y-2">
                    <.placement device={@device} folder={@folder} />
                  </ol>
                  <p class="text-sm leading-6 text-muted">
                    This folder is already pointed at {@vault.name}, so step 2 comes down to
                    <.ui>Sign in</.ui>
                    in
                    <.ui>Settings</.ui>
                    › <.ui>Babel Sync</.ui>. The button below does the same.
                  </p>
                </div>
              </.group>

              <.group id="install-existing">
                <div class="space-y-3 px-4 py-4">
                  <h3 class="text-base font-medium text-ink">Add it to a vault you already have</h3>
                  <p :if={@device != "computer"} class="text-sm leading-6 text-muted">
                    Do this on a computer. A phone's file browser does not show the hidden folder
                    the plugin goes in.
                  </p>
                  <.download
                    :if={@available?}
                    id="download-plugin"
                    href={~p"/obsidian/plugin.zip"}
                    label="Download the plugin"
                    version={@version}
                    variant="secondary"
                  />
                  <ol id="install-existing-steps" class="space-y-2">
                    <.instruction letter="a">
                      Unzip <.ui>babelsync-plugin.zip</.ui>. You get a folder named <.ui>babelsync</.ui>.
                    </.instruction>
                    <.instruction letter="b">
                      Move it into the vault's
                      <.ui>.obsidian/plugins</.ui>
                      folder; create
                      <.ui>plugins</.ui>
                      if it is missing.
                      <:note>
                        <.ui>.obsidian</.ui>
                        is hidden. Show it with
                        <.ui>Cmd</.ui>
                        <.ui>Shift</.ui>
                        <.ui>.</.ui>
                        in Finder,
                        <.ui>View › Hidden items</.ui>
                        on Windows, or
                        <.ui>Ctrl</.ui>
                        <.ui>H</.ui>
                        on Linux.
                      </:note>
                    </.instruction>
                    <.instruction letter="c">
                      In Obsidian, open
                      <.ui>Settings</.ui>
                      › <.ui>Community plugins</.ui>, turn on community plugins if it asks, and switch on <.ui>Babel Sync</.ui>.
                    </.instruction>
                  </ol>
                </div>
              </.group>
            </div>
          </.step>

          <.step number={2} title="Connect">
            <p class="text-base leading-7 text-ink">
              Open the vault you want to sync in Obsidian on this device, then tap the button.
            </p>
            <div>
              <a
                id="connect-open-obsidian"
                href={@deep_link}
                class="inline-flex h-12 w-full cursor-pointer items-center justify-center gap-2 rounded-xl bg-accent px-6 text-base font-semibold text-accent-ink shadow-raise transition-colors duration-150 hover:bg-accent/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent sm:w-auto"
              >
                <.logo class="size-5" /> Open in Obsidian
              </a>
            </div>
            <p class="text-sm leading-6 text-muted">
              Obsidian opens and asks whether to sync that vault with {@vault.name}. Choose <.ui>Connect</.ui>, approve the sign-in page that follows, and you are returned to
              Obsidian with your notes arriving.
            </p>
            <p
              id="merge-caution"
              class="flex gap-2.5 rounded-xl border border-warn/40 bg-warn/8 px-4 py-3 text-sm leading-6 text-ink"
            >
              <.icon name="hero-exclamation-triangle-mini" class="mt-1 size-4 shrink-0 text-warn" />
              <span>
                Obsidian connects whichever vault it has open. Notes already in it are uploaded
                into {@vault.name} and merged with what is here.
              </span>
            </p>
          </.step>
        </ol>

        <.panel id="expect" title="What to expect">
          <.group>
            <.fact icon="hero-bolt">
              Notes sync as you type, in both directions, with no button to press.
            </.fact>
            <.fact icon="hero-users">
              When someone else has the same note open, you see their cursor in it.
            </.fact>
            <.fact icon="hero-check-circle">
              On a computer the status bar reads
              <.ui>Babel Sync: synced</.ui>
              when everything is up to date.
            </.fact>
            <.fact icon="hero-swatch">
              Themes, snippets, hotkeys and plugins sync too, unless you turn off
              <.ui>Obsidian settings</.ui>
              in the plugin.
            </.fact>
            <.fact icon="hero-link-slash">
              Every connected device is listed under
              <.link
                id="connect-devices-link"
                navigate={~p"/account?#{[from: @vault.id]}" <> "#grants"}
                class="font-medium text-accent underline decoration-accent/40 underline-offset-2 transition-colors duration-150 hover:text-ink"
              >
                Devices and agents
              </.link>
              in your settings, where you can disconnect it.
            </.fact>
          </.group>
        </.panel>

        <.panel id="trouble" title="If something is not working">
          <.group>
            <.remedy problem="Nothing happens when I tap Open in Obsidian">
              The plugin is not installed or switched on in the vault that opened, or it is an old
              build. You can also connect by hand: in
              <.ui>Settings</.ui>
              › <.ui>Babel Sync</.ui>, enter the server address below, tap <.ui>Sign in</.ui>, then choose
              <.ui>{@vault.name}</.ui>
              under <.ui>Vault</.ui>.
              <:extra>
                <div class="flex max-w-md items-center gap-2">
                  <input
                    id="server-address"
                    type="text"
                    readonly
                    value={@server_url}
                    aria-label="Server address"
                    class={[field_class(), "font-mono"]}
                  />
                  <.button
                    id="copy-server-address"
                    type="button"
                    phx-hook=".Copy"
                    data-copy={@server_url}
                    class="group flex-none"
                  >
                    <.icon
                      name="hero-clipboard-document-mini"
                      class="size-4 group-data-copied:hidden"
                    />
                    <.icon name="hero-check-mini" class="hidden size-4 group-data-copied:block" />
                    <span class="group-data-copied:hidden">Copy</span>
                    <span class="hidden group-data-copied:inline">Copied</span>
                  </.button>
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
                    export default {
                      mounted() {
                        this.el.addEventListener("click", async () => {
                          try {
                            await navigator.clipboard.writeText(this.el.dataset.copy)
                          } catch (_refused) {
                            const field = document.getElementById("server-address")
                            field.focus()
                            field.select()
                            return
                          }
                          this.el.dataset.copied = ""
                          clearTimeout(this.timer)
                          this.timer = setTimeout(() => delete this.el.dataset.copied, 1600)
                        })
                      },
                      destroyed() {
                        clearTimeout(this.timer)
                      }
                    }
                  </script>
                </div>
              </:extra>
            </.remedy>
            <.remedy problem="Sign in does nothing">
              Make sure the plugin is up to date, then tap
              <.ui>Sign in</.ui>
              and then <.ui>Open sign-in page</.ui>.
            </.remedy>
            <.remedy problem="The plugin is not listed in Obsidian">
              The folder must be
              <.ui>.obsidian/plugins/babelsync</.ui>
              with
              <.ui>main.js</.ui>
              and
              <.ui>manifest.json</.ui>
              directly inside it.
            </.remedy>
            <.remedy problem="Still stuck">
              In
              <.ui>Settings</.ui>
              › <.ui>Babel Sync</.ui>, under Troubleshooting, try <.ui>Reconnect</.ui>, then <.ui>Compare everything again</.ui>.
            </.remedy>
          </.group>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :device, :string, required: true
  attr :folder, :string, required: true

  defp placement(%{device: "iphone"} = assigns) do
    ~H"""
    <.instruction letter="a">
      In the
      <.ui>Files</.ui>
      app, find
      <.ui>{@folder}.zip</.ui>
      in
      <.ui>Downloads</.ui>
      and tap it. It unzips into a folder named <.ui>{@folder}</.ui>.
    </.instruction>
    <.instruction letter="b">
      Touch and hold that folder, tap <.ui>Move</.ui>, and put it in <.ui>On My iPhone › Obsidian</.ui>.
      <:note>
        No Obsidian folder there? Install Obsidian and open it once. If Obsidian keeps its vaults
        in iCloud, the folder goes in
        <.ui>iCloud Drive › Obsidian</.ui>
        instead, but a vault should sync through Babel Sync or iCloud, not both, so On My iPhone is
        the better place.
      </:note>
    </.instruction>
    <.instruction letter="c">
      Open Obsidian and pick <.ui>{@folder}</.ui>. When it asks, choose <.ui>Trust author and enable plugins</.ui>.
    </.instruction>
    """
  end

  defp placement(%{device: "android"} = assigns) do
    ~H"""
    <.instruction letter="a">
      In the
      <.ui>Files</.ui>
      app, find
      <.ui>{@folder}.zip</.ui>
      in
      <.ui>Downloads</.ui>
      and extract it. You get a folder named <.ui>{@folder}</.ui>.
    </.instruction>
    <.instruction letter="b">
      Move that folder to where Obsidian keeps its vaults, for example <.ui>Documents › Obsidian</.ui>.
    </.instruction>
    <.instruction letter="c">
      Open Obsidian, choose
      <.ui>Open folder as vault</.ui>
      and pick <.ui>{@folder}</.ui>. When it asks, choose <.ui>Trust author and enable plugins</.ui>.
    </.instruction>
    """
  end

  defp placement(%{device: "computer"} = assigns) do
    ~H"""
    <.instruction letter="a">
      Unzip
      <.ui>{@folder}.zip</.ui>
      and move the folder
      <.ui>{@folder}</.ui>
      to where you keep your notes, for example <.ui>Documents</.ui>.
    </.instruction>
    <.instruction letter="b">
      In Obsidian, choose
      <.ui>Open folder as vault</.ui>
      and pick that folder.
    </.instruction>
    <.instruction letter="c">
      When it asks, choose <.ui>Trust author and enable plugins</.ui>.
    </.instruction>
    """
  end

  attr :number, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <li id={"step-#{@number}"} class="group relative flex gap-3.5 pb-9 last:pb-0 sm:gap-5">
      <span
        aria-hidden="true"
        class="absolute bottom-2 left-[1.125rem] top-11 w-px -translate-x-1/2 bg-line group-last:hidden"
      ></span>
      <span
        aria-hidden="true"
        class="grid size-9 flex-none place-items-center rounded-full border border-line-strong bg-surface font-serif text-lg font-bold tabular-nums text-ink shadow-raise"
      >
        {@number}
      </span>
      <div class="min-w-0 flex-1 space-y-3.5">
        <h2 class="pt-1 font-serif text-xl font-bold leading-7 tracking-tight text-ink">
          {@title}
        </h2>
        {render_slot(@inner_block)}
      </div>
    </li>
    """
  end

  attr :letter, :string, required: true
  slot :inner_block, required: true
  slot :note

  defp instruction(assigns) do
    ~H"""
    <li class="flex gap-2.5">
      <span
        aria-hidden="true"
        class="w-4 flex-none pt-px text-right font-serif text-base font-bold leading-7 text-faint"
      >
        {@letter}
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-base leading-7 text-ink">{render_slot(@inner_block)}</p>
        <p :for={note <- @note} class="mt-1 text-sm leading-6 text-muted">{render_slot(note)}</p>
      </div>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :version, :string, default: nil
  attr :variant, :string, default: "secondary"

  defp download(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5">
      <.button id={@id} href={@href} download variant={@variant}>
        <.icon name="hero-arrow-down-tray-mini" class="size-4" /> {@label}
      </.button>
      <span :if={@version} class="text-xs tabular-nums text-faint">Plugin {@version}</span>
    </div>
    """
  end

  attr :class, :string,
    default:
      "rounded-md border border-line bg-sunken box-decoration-clone px-1.5 py-0.5 text-[0.875em] font-medium text-ink"

  slot :inner_block, required: true

  defp ui(assigns) do
    ~H|<span class={@class}>{render_slot(@inner_block)}</span>|
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="flex gap-3 px-4 py-3">
      <.icon name={@icon} class="mt-1 size-5 shrink-0 text-muted" />
      <p class="min-w-0 flex-1 text-base leading-7 text-ink">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :problem, :string, required: true
  slot :inner_block, required: true
  slot :extra

  defp remedy(assigns) do
    ~H"""
    <div class="space-y-2.5 px-4 py-3">
      <div>
        <h3 class="text-base font-medium text-ink">{@problem}</h3>
        <p class="mt-0.5 text-base leading-7 text-muted">{render_slot(@inner_block)}</p>
      </div>
      <div :if={@extra != []}>{render_slot(@extra)}</div>
    </div>
    """
  end

  defp plugin_label do
    case {Plugin.version(), Plugin.build()} do
      {nil, _build} -> nil
      {version, nil} -> version
      {version, build} -> "#{version}, build #{build}"
    end
  end
end
