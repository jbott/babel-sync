defmodule BabelSyncWeb.AuthLive.Account do
  use BabelSyncWeb, :live_view

  alias BabelSync.{Accounts, Auth, OAuth}
  alias BabelSync.Auth.Passkeys

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Account")
     |> assign(:passkeys?, Auth.enabled?(:passkey))
     |> assign(:signed_in?, not Auth.open?())
     |> assign(:challenge, nil)
     |> assign(:profile, to_form(Accounts.change_user(user)))
     |> load()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:passkeys, Passkeys.list(user))
    |> assign(:grants, OAuth.list_grants(user))
  end

  @impl true
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-10 py-8 md:py-14">
        <.header>
          Account
          <:subtitle>{@current_scope.user.email}</:subtitle>
        </.header>

        <.panel title="Profile">
          <.form
            for={@profile}
            id="profile-form"
            phx-submit="save_profile"
            class="flex items-end gap-2.5"
          >
            <div class="flex-1">
              <.input field={@profile[:name]} label="Name shown to collaborators" />
            </div>
            <.button>Save</.button>
          </.form>
        </.panel>

        <.panel :if={@passkeys?} id="passkeys" title="Passkeys">
          <.rows>
            <li :if={@passkeys == []} class="px-4 py-4 text-sm text-muted">
              No passkeys yet.
            </li>
            <li
              :for={passkey <- @passkeys}
              id={"passkey-#{passkey.id}"}
              class="flex items-center gap-3 py-2.5 pl-4 pr-2.5"
            >
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/12 text-accent">
                <.icon name="hero-finger-print" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <div class="truncate font-medium text-ink">{passkey.name}</div>
                <div class="text-xs tabular-nums text-faint">
                  Added {Calendar.strftime(passkey.inserted_at, "%d %b %Y")}
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
          </.rows>
          <div class="flex flex-wrap gap-2.5">
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
              class="flex-1 sm:flex-none"
            >
              <.icon name="hero-plus-mini" class="size-4" /> Add passkey
            </.button>
          </div>
        </.panel>

        <.panel id="grants" title="Connected devices and agents">
          <.rows>
            <li :if={@grants == []} class="px-4 py-4 text-sm text-muted">
              Nothing is connected. Sign in from the Obsidian plugin or add this server to an agent
              as an MCP server at <code class="rounded border border-line bg-sunken px-1 py-px font-mono text-xs text-ink">/mcp</code>.
            </li>
            <li
              :for={grant <- @grants}
              id={"grant-#{grant.id}"}
              class="flex items-center gap-3 py-2.5 pl-4 pr-2.5"
            >
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-ink/6 text-muted">
                <.icon name="hero-link" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <div class="truncate font-medium text-ink">
                  {grant.client.name}
                  <.badge :if={grant.read_only} class="ml-1">read only</.badge>
                </div>
                <div class="text-xs tabular-nums text-faint">
                  Last active {Calendar.strftime(grant.last_used_at, "%d %b %Y %H:%M")} UTC
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
          </.rows>
        </.panel>

        <div :if={@signed_in?} class="border-t border-line pt-6">
          <.button id="sign-out" href={~p"/logout"} method="delete" variant="ghost" class="-ml-4">
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> Sign out
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp only_passkeys?, do: Auth.methods() == [:passkey]
end
