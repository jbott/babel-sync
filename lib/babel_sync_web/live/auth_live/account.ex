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
      <div class="mx-auto max-w-2xl px-4 py-10 space-y-10">
        <.header>
          Account
          <:subtitle>{@current_scope.user.email}</:subtitle>
        </.header>

        <section class="space-y-3">
          <h2 class="font-semibold">Profile</h2>
          <.form
            for={@profile}
            id="profile-form"
            phx-submit="save_profile"
            class="flex items-end gap-3"
          >
            <div class="flex-1">
              <.input field={@profile[:name]} label="Name shown to collaborators" />
            </div>
            <.button class="mb-2">Save</.button>
          </.form>
        </section>

        <section :if={@passkeys?} id="passkeys" class="space-y-3">
          <h2 class="font-semibold">Passkeys</h2>
          <ul class="divide-y divide-base-300 rounded-box border border-base-300">
            <li :if={@passkeys == []} class="px-4 py-3 text-sm text-base-content/60">
              No passkeys yet.
            </li>
            <li
              :for={passkey <- @passkeys}
              id={"passkey-#{passkey.id}"}
              class="flex items-center gap-3 px-4 py-3"
            >
              <.icon name="hero-finger-print" class="size-5 text-base-content/50" />
              <div class="flex-1">
                <div class="font-medium">{passkey.name}</div>
                <div class="text-xs text-base-content/50">
                  Added {Calendar.strftime(passkey.inserted_at, "%d %b %Y")}
                </div>
              </div>
              <button
                :if={length(@passkeys) > 1 or not only_passkeys?()}
                phx-click="remove_passkey"
                phx-value-id={passkey.id}
                data-confirm="Remove this passkey?"
                class="btn btn-ghost btn-sm text-error"
              >
                Remove
              </button>
            </li>
          </ul>
          <div class="flex gap-3">
            <input
              id="passkey-name"
              type="text"
              placeholder="Name, for example Laptop"
              class="input flex-1"
            />
            <button
              id="passkey-add"
              phx-hook="Passkey"
              data-name-from="passkey-name"
              class="btn transition hover:-translate-y-px"
            >
              <.icon name="hero-plus" class="size-4" /> Add passkey
            </button>
          </div>
        </section>

        <section id="grants" class="space-y-3">
          <h2 class="font-semibold">Connected devices and agents</h2>
          <ul class="divide-y divide-base-300 rounded-box border border-base-300">
            <li :if={@grants == []} class="px-4 py-3 text-sm text-base-content/60">
              Nothing is connected. Sign in from the Obsidian plugin or add this server to an agent
              as an MCP server at <code>/mcp</code>.
            </li>
            <li
              :for={grant <- @grants}
              id={"grant-#{grant.id}"}
              class="flex items-center gap-3 px-4 py-3"
            >
              <.icon name="hero-device-phone-mobile" class="size-5 text-base-content/50" />
              <div class="flex-1">
                <div class="font-medium">
                  {grant.client.name}
                  <span :if={grant.read_only} class="badge badge-sm ml-1">read only</span>
                </div>
                <div class="text-xs text-base-content/50">
                  Last active {Calendar.strftime(grant.last_used_at, "%d %b %Y %H:%M")} UTC
                </div>
              </div>
              <button
                phx-click="revoke"
                phx-value-id={grant.id}
                data-confirm={"Disconnect #{grant.client.name}?"}
                class="btn btn-ghost btn-sm text-error"
              >
                Disconnect
              </button>
            </li>
          </ul>
        </section>

        <.link
          :if={@signed_in?}
          id="sign-out"
          href={~p"/logout"}
          method="delete"
          class="btn btn-ghost"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> Sign out
        </.link>
      </div>
    </Layouts.app>
    """
  end

  defp only_passkeys?, do: Auth.methods() == [:passkey]
end
