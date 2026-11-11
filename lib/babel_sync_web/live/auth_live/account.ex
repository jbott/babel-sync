defmodule BabelSyncWeb.AuthLive.Account do
  use BabelSyncWeb, :live_view

  alias BabelSync.{Accounts, Auth, OAuth, Vaults}
  alias BabelSync.Auth.Passkeys
  alias BabelSync.Vaults.Vault
  alias BabelSyncWeb.Paths

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_scope.user
    vaults = Vaults.list_vaults(user)
    multi? = BabelSync.mode() == :multi

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:back, back(vaults, params["from"]))
     |> assign(
       :connect_vault,
       Enum.find(vaults, &(&1.id == params["from"])) || List.first(vaults)
     )
     |> assign(:no_vaults?, vaults == [])
     |> assign(:multi?, multi?)
     |> assign(:passkeys?, Auth.enabled?(:passkey))
     |> assign(:signed_in?, not Auth.open?())
     |> assign(:challenge, nil)
     |> assign(:profile, to_form(Accounts.change_user(user)))
     |> assign(:vault_form, to_form(Vault.changeset(%Vault{}, %{})))
     |> assign(:roles, roles(user, vaults, multi?))
     |> stream(:vaults, vaults)
     |> load()}
  end

  defp back([], _from), do: nil

  defp back(vaults, from) do
    case Enum.find(vaults, &(&1.id == from)) do
      nil -> %{to: ~p"/", label: "Back to notes"}
      vault -> %{to: Paths.vault(vault.id), label: "Back to #{vault.name}"}
    end
  end

  defp roles(user, vaults, true), do: Map.new(vaults, &{&1.id, Vaults.role(user, &1.id)})
  defp roles(_user, _vaults, false), do: %{}

  defp load(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:passkeys, Passkeys.list(user))
    |> assign(:grants, OAuth.list_grants(user))
  end

  @impl true
  def handle_event("create", %{"vault" => params}, socket) do
    case Vaults.create_vault(socket.assigns.current_scope.user, params) do
      {:ok, vault} -> {:noreply, push_navigate(socket, to: Paths.vault(vault.id))}
      {:error, changeset} -> {:noreply, assign(socket, :vault_form, to_form(changeset))}
    end
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.update_user(scope.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | user: user})
         |> assign(:profile, to_form(Accounts.change_user(user)))
         |> put_flash(:info, "Saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile, to_form(changeset))}
    end
  end

  def handle_event("passkey_options", _params, %{assigns: %{passkeys?: true}} = socket) do
    {challenge, options} = Passkeys.registration(socket.assigns.current_scope.user)
    {:reply, %{create: options}, assign(socket, :challenge, challenge)}
  end

  def handle_event("passkey_result", response, %{assigns: %{challenge: challenge}} = socket)
      when not is_nil(challenge) do
    user = socket.assigns.current_scope.user
    socket = assign(socket, :challenge, nil)

    case Passkeys.register(user, challenge, response, response["name"] || "") do
      {:ok, _passkey} ->
        {:noreply, socket |> load() |> put_flash(:info, "Passkey added.")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, "That passkey was not accepted.")}
    end
  end

  def handle_event("passkey_options", _params, socket), do: {:reply, %{}, socket}
  def handle_event("passkey_result", _response, socket), do: {:noreply, socket}

  def handle_event("passkey_failed", _params, socket) do
    {:noreply,
     socket
     |> assign(:challenge, nil)
     |> put_flash(:error, "The passkey prompt was dismissed or is not available here.")}
  end

  def handle_event("remove_passkey", %{"id" => id}, socket) do
    :ok = Passkeys.delete(socket.assigns.current_scope.user, id)
    {:noreply, load(socket)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    :ok = OAuth.revoke_grant(socket.assigns.current_scope.user, id)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      account_link={false}
      column="max-w-4xl"
    >
      <div class="mx-auto max-w-4xl pb-12 pt-6 md:pb-20 md:pt-9">
        <.header>
          <:trail :if={@back}>
            <.back_link id="account-back" navigate={@back.to}>{@back.label}</.back_link>
          </:trail>
          Settings
        </.header>

        <div class="mt-7 lg:mt-9 lg:grid lg:grid-cols-[10rem_minmax(0,1fr)] lg:gap-12">
          <nav
            id="settings-sections"
            aria-label="Sections"
            class="sticky top-8 hidden self-start lg:block"
          >
            <a
              :for={{anchor, label} <- sections(assigns)}
              href={"##{anchor}"}
              class="-ml-2.5 flex h-8 items-center rounded-lg px-2.5 text-sm font-medium text-muted transition-colors duration-150 hover:bg-ink/7 hover:text-ink"
            >
              {label}
            </a>
          </nav>

          <div class="min-w-0 space-y-9">
            <.group id="identity">
              <div class="flex items-center gap-3.5 px-4 py-3.5">
                <span
                  aria-hidden="true"
                  class="grid size-11 shrink-0 place-items-center rounded-full bg-accent/12 font-serif text-xl font-bold text-accent"
                >
                  {initial(@current_scope.user)}
                </span>
                <div class="min-w-0 flex-1">
                  <div class="truncate font-serif text-lg font-bold leading-tight tracking-tight text-ink">
                    {display_name(@current_scope.user)}
                  </div>
                  <div class="flex flex-wrap gap-x-1.5 text-sm text-muted">
                    <span :for={part <- standing(assigns)} class="min-w-0 truncate">{part}</span>
                  </div>
                </div>
                <.button
                  :if={@signed_in?}
                  id="sign-out"
                  href={~p"/logout"}
                  method="delete"
                  variant="secondary"
                  size="sm"
                  class="flex-none"
                >
                  <.icon name="hero-arrow-right-start-on-rectangle-mini" class="size-4" /> Sign out
                </.button>
              </div>
              <p :if={not @signed_in?} id="open-mode" class="px-4 py-3 text-sm text-muted">
                Sign-in is off on this server, so anyone who can reach it reads and edits as the
                owner. Set
                <code class="rounded border border-line bg-sunken px-1 py-px font-mono text-xs text-ink">BABELSYNC_AUTH</code>
                to require a passkey or an emailed link.
              </p>
            </.group>

            <.panel id="your-vaults" title="Vaults" class="scroll-mt-8">
              <.group>
                <ul id="vaults" phx-update="stream" class="divide-y divide-line">
                  <li id="vaults-empty" class="hidden px-6 py-8 text-center only:block">
                    <.logo class="mx-auto size-9 text-line-strong" />
                    <p class="mt-3 font-serif text-lg font-bold tracking-tight text-ink">
                      No vaults yet
                    </p>
                    <p class="mx-auto mt-1 max-w-sm text-sm text-muted">
                      A vault is one folder of notes, kept in step between this server and the
                      Obsidian vaults you connect to it. Name the first one to begin.
                    </p>
                  </li>
                  <li
                    :for={{id, vault} <- @streams.vaults}
                    id={id}
                    class="relative flex items-center gap-1 pr-2.5 transition-colors duration-150 hover:bg-canvas"
                  >
                    <.link
                      navigate={Paths.vault(vault.id)}
                      class="flex min-h-12 min-w-0 flex-1 items-center gap-3 py-2 pl-4 after:absolute after:inset-0"
                    >
                      <.logo class="size-5 shrink-0 text-accent" />
                      <span class="truncate font-serif text-base font-semibold tracking-tight text-ink">
                        {vault.name}
                      </span>
                      <.badge :if={@roles[vault.id]}>{@roles[vault.id]}</.badge>
                    </.link>
                    <.icon_button
                      :if={admin?(assigns, vault)}
                      navigate={Paths.settings(vault.id)}
                      icon="hero-cog-6-tooth"
                      label={"Settings for #{vault.name}"}
                      class="relative z-10"
                    />
                    <.icon name="hero-chevron-right-mini" class="size-4 shrink-0 text-faint" />
                  </li>
                </ul>
                <.form
                  for={@vault_form}
                  id="new-vault"
                  phx-submit="create"
                  class={["flex items-start gap-2.5 px-4 py-3", not @no_vaults? && "bg-canvas/60"]}
                >
                  <div class="flex-1">
                    <.input
                      field={@vault_form[:name]}
                      aria-label="New vault"
                      placeholder={if(@no_vaults?, do: "Vault name", else: "New vault")}
                    />
                  </div>
                  <.button variant={if(@no_vaults?, do: "primary", else: "secondary")}>
                    <.icon name="hero-plus-mini" class="size-4" />
                    {if(@no_vaults?, do: "Create vault", else: "Create")}
                  </.button>
                </.form>
              </.group>
            </.panel>

            <.panel id="profile" title="Profile" class="scroll-mt-8">
              <.group>
                <.form for={@profile} id="profile-form" phx-submit="save_profile">
                  <.setting label="Name" for={@profile[:name].id} stack>
                    <:hint>Shown to collaborators</:hint>
                    <div class="flex-1"><.input field={@profile[:name]} /></div>
                    <.button variant="secondary">Save</.button>
                  </.setting>
                </.form>
                <.setting :if={@current_scope.user.email} label="Email">
                  <span id="profile-email" class="truncate text-base text-muted">
                    {@current_scope.user.email}
                  </span>
                </.setting>
              </.group>
            </.panel>

            <.panel id="appearance" title="Appearance" class="scroll-mt-8">
              <.group>
                <.setting label="Theme" stack>
                  <:hint>Kept in this browser</:hint>
                  <Layouts.theme_toggle class="w-full sm:w-auto" />
                </.setting>
              </.group>
            </.panel>

            <.panel :if={@passkeys?} id="passkeys" title="Passkeys" class="scroll-mt-8">
              <.group>
                <p :if={@passkeys == []} class="px-4 py-4 text-sm text-muted">
                  No passkeys yet. Add one to sign in with a fingerprint, a face or a security key.
                </p>
                <ul :if={@passkeys != []} class="divide-y divide-line">
                  <li
                    :for={passkey <- @passkeys}
                    id={"passkey-#{passkey.id}"}
                    class="flex min-h-14 items-center gap-3 py-2 pl-4 pr-2.5"
                  >
                    <.icon name="hero-finger-print" class="size-5 shrink-0 text-muted" />
                    <div class="min-w-0 flex-1">
                      <div class="truncate text-base font-medium text-ink">{passkey.name}</div>
                      <div class="truncate text-xs tabular-nums text-faint">
                        Added {day(passkey.inserted_at)}
                        <span :if={passkey.last_used_at}>
                          · last used {day(passkey.last_used_at)}
                        </span>
                      </div>
                    </div>
                    <.button
                      :if={length(@passkeys) > 1 or not only_passkeys?()}
                      phx-click="remove_passkey"
                      phx-value-id={passkey.id}
                      data-confirm="Remove this passkey?"
                      variant="danger-ghost"
                      size="sm"
                    >
                      Remove
                    </.button>
                  </li>
                </ul>
                <div class="flex flex-wrap items-center gap-2.5 bg-canvas/60 px-4 py-3">
                  <input
                    id="passkey-name"
                    type="text"
                    placeholder="Name, for example Laptop"
                    aria-label="Name for the new passkey"
                    class={[field_class(), "w-auto flex-1 basis-full sm:basis-48"]}
                  />
                  <.button
                    id="passkey-add"
                    phx-hook="Passkey"
                    data-name-from="passkey-name"
                    variant="secondary"
                    class="flex-1 sm:flex-none"
                  >
                    <.icon name="hero-plus-mini" class="size-4" /> Add passkey
                  </.button>
                </div>
              </.group>
            </.panel>

            <.panel id="grants" title="Devices and agents" class="scroll-mt-8">
              <.group>
                <div :if={@grants == []} class="px-4 py-4 text-sm text-muted">
                  <p class="font-medium text-ink">Nothing is connected</p>
                  <p class="mt-0.5 max-w-prose">
                    {if(@connect_vault,
                      do: "Connect a device below to sync a vault with Obsidian,",
                      else: "Create a vault to sync it with Obsidian,"
                    )} or add this server to an agent as an MCP server at <code class="rounded border border-line bg-sunken px-1 py-px font-mono text-xs text-ink">/mcp</code>.
                  </p>
                </div>
                <ul :if={@grants != []} class="divide-y divide-line">
                  <li
                    :for={grant <- @grants}
                    id={"grant-#{grant.id}"}
                    class="flex min-h-14 items-center gap-3 py-2 pl-4 pr-2.5"
                  >
                    <.icon name={kind_icon(grant)} class="size-5 shrink-0 text-muted" />
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <span class="truncate text-base font-medium text-ink">
                          {grant.client.name}
                        </span>
                        <.badge class="flex-none">{kind(grant)}</.badge>
                      </div>
                      <div class="flex flex-wrap gap-x-1.5 text-xs tabular-nums text-faint">
                        <span>{if(grant.read_only, do: "Read only", else: "Reads and edits")}</span>
                        <span>Last active {minute(grant.last_used_at)}</span>
                      </div>
                    </div>
                    <.button
                      phx-click="revoke"
                      phx-value-id={grant.id}
                      data-confirm={"Disconnect #{grant.client.name}?"}
                      variant="danger-ghost"
                      size="sm"
                    >
                      Disconnect
                    </.button>
                  </li>
                </ul>
                <.link
                  :if={@connect_vault}
                  id="connect-device"
                  navigate={Paths.connect(@connect_vault.id)}
                  class="flex min-h-12 items-center gap-3 bg-canvas/60 py-2 pl-4 pr-2.5 transition-colors duration-150 hover:bg-canvas"
                >
                  <.icon name="hero-plus-mini" class="size-5 shrink-0 text-muted" />
                  <span class="min-w-0 flex-1">
                    <span class="block text-base font-medium text-ink">Connect a device</span>
                    <span class="block truncate text-xs text-faint">
                      Set up Obsidian with {@connect_vault.name}
                    </span>
                  </span>
                  <.icon name="hero-chevron-right-mini" class="mr-1.5 size-4 shrink-0 text-faint" />
                </.link>
              </.group>
            </.panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp sections(assigns) do
    [
      {"your-vaults", "Vaults"},
      {"profile", "Profile"},
      {"appearance", "Appearance"},
      assigns.passkeys? && {"passkeys", "Passkeys"},
      {"grants", "Devices and agents"}
    ]
    |> Enum.filter(& &1)
  end

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email), do: email
  defp display_name(_user), do: "Owner"

  defp initial(user), do: user |> display_name() |> String.first() |> String.upcase()

  defp standing(%{signed_in?: false}), do: ["Owner of this server"]

  defp standing(%{multi?: multi?, current_scope: %{user: user}}) do
    role = if multi?, do: "Member of this server", else: "Owner of this server"
    if display_name(user) == user.email, do: [role], else: Enum.filter([user.email, role], & &1)
  end

  defp admin?(%{multi?: false}, _vault), do: true
  defp admin?(%{roles: roles}, vault), do: roles[vault.id] == :owner

  defp obsidian?(grant),
    do: Enum.any?(grant.client.redirect_uris, &String.starts_with?(&1, "obsidian:"))

  defp kind(grant), do: if(obsidian?(grant), do: "Obsidian", else: "Agent")

  defp kind_icon(grant),
    do: if(obsidian?(grant), do: "hero-device-phone-mobile", else: "hero-cpu-chip")

  defp day(at), do: Calendar.strftime(at, "%-d %b %Y")
  defp minute(at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")

  defp only_passkeys?, do: Auth.methods() == [:passkey]
end
