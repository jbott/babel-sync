defmodule BabelSyncWeb.VaultLive.Settings do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts.Scope
  alias BabelSync.Auth.MagicLink
  alias BabelSync.Vaults
  alias BabelSync.Vaults.Vault
  alias BabelSyncWeb.Paths

  @impl true
  def mount(%{"vault_id" => vault_id}, _session, socket) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(socket.assigns.current_scope, vault_id, :admin),
         %Vault{} = vault <- Vaults.get_vault(vault_id) do
      {:ok,
       socket
       |> assign(:page_title, "#{vault.name} settings")
       |> assign(:sharing, BabelSync.mode() == :multi)
       |> assign(:vault, vault)
       |> assign(:name_form, to_form(Vault.changeset(vault, %{})))
       |> assign(:member_form, to_form(%{"email" => "", "role" => "editor"}, as: :member))
       |> assign(:members, Vaults.list_members(vault))
       |> assign(:invitations, Vaults.list_invitations(vault))}
    else
      _denied ->
        {:ok,
         socket
         |> put_flash(:error, "Only an owner can change vault settings.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("rename", %{"vault" => params}, socket) do
    case Vaults.update_vault(socket.assigns.vault, params) do
      {:ok, vault} ->
        {:noreply,
         socket
         |> assign(:vault, vault)
         |> assign(:name_form, to_form(Vault.changeset(vault, %{})))
         |> put_flash(:info, "Vault renamed.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :name_form, to_form(changeset))}
    end
  end

  def handle_event("set_agent_access", params, socket) do
    open = params["agents_see_config"] == "true"
    {:ok, vault} = Vaults.update_vault(socket.assigns.vault, %{agents_see_config: open})
    {:noreply, assign(socket, :vault, vault)}
  end

  def handle_event("add_member", %{"member" => %{"email" => email, "role" => role}}, socket)
      when role in ["owner", "editor", "viewer"] do
    vault = socket.assigns.vault

    case Vaults.invite(vault, email, String.to_existing_atom(role)) do
      {:ok, :added} ->
        {:noreply, reload(socket)}

      {:ok, :invited} ->
        if BabelSync.Auth.enabled?(:magic_link),
          do: MagicLink.announce_invitation(email, vault.name, url(~p"/login"))

        {:noreply,
         socket
         |> put_flash(:info, "#{String.trim(email)} will join when they first sign in.")
         |> reload()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That is not an email address.")}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: Vaults.revoke_invitation(socket.assigns.vault, id)
    {:noreply, reload(socket)}
  end

  def handle_event("set_role", %{"user_id" => user_id, "role" => role}, socket)
      when role in ["owner", "editor", "viewer"] do
    change_member(socket, user_id, fn user ->
      {:ok, _member} =
        Vaults.put_member(socket.assigns.vault, user, String.to_existing_atom(role))
    end)
  end

  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    change_member(socket, user_id, fn user ->
      :ok = Vaults.remove_member(socket.assigns.vault, user)
    end)
  end

  def handle_event("delete_vault", _params, socket) do
    {:ok, _vault} = Vaults.delete_vault(socket.assigns.vault)
    {:noreply, socket |> put_flash(:info, "Vault deleted.") |> push_navigate(to: ~p"/")}
  end

  defp change_member(socket, user_id, change) do
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))

    cond do
      is_nil(member) ->
        {:noreply, socket}

      last_owner?(socket.assigns.members, member) ->
        {:noreply, put_flash(socket, :error, "A vault needs at least one owner.")}

      true ->
        change.(member.user)
        {:noreply, reload(socket)}
    end
  end

  defp last_owner?(members, member) do
    member.role == :owner and Enum.count(members, &(&1.role == :owner)) == 1
  end

  defp reload(socket) do
    socket
    |> assign(:members, Vaults.list_members(socket.assigns.vault))
    |> assign(:invitations, Vaults.list_invitations(socket.assigns.vault))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-10 pb-12 pt-7 md:pb-20 md:pt-10">
        <.header>
          <:trail>
            <.back_link navigate={Paths.vault(@vault.id)}>Back to the vault</.back_link>
          </:trail>
          {@vault.name}
          <:subtitle>Vault settings</:subtitle>
        </.header>

        <.panel title="Name">
          <.form
            for={@name_form}
            id="rename-vault"
            phx-submit="rename"
            class="flex items-start gap-2.5"
          >
            <div class="flex-1"><.input field={@name_form[:name]} aria-label="Name" /></div>
            <.button>Save</.button>
          </.form>
        </.panel>

        <.panel id="agents" title="Agents">
          <form id="agent-access" phx-change="set_agent_access" phx-auto-recover="ignore">
            <label class="flex cursor-pointer items-start gap-3 rounded-xl border border-line bg-surface p-4 transition hover:border-line-strong">
              <input type="hidden" name="agents_see_config" value="false" />
              <input
                type="checkbox"
                id="agents-see-config"
                name="agents_see_config"
                value="true"
                checked={@vault.agents_see_config}
                class="mt-0.5 size-4 shrink-0 rounded accent-accent"
              />
              <span class="min-w-0">
                <span class="block font-medium text-ink">Let agents into the .obsidian folder</span>
                <span class="mt-1 block text-sm text-muted">
                  Off, agents connected over MCP cannot see or change Obsidian's settings and
                  plugins in this vault. On, an agent that may write can install or replace a
                  plugin, which then runs on every device that syncs the vault.
                </span>
              </span>
            </label>
          </form>
        </.panel>

        <.panel :if={BabelSync.Sources.enabled?()} id="sources" title="Sources">
          <div class="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-line bg-surface p-4">
            <p class="min-w-0 flex-1 basis-64 text-sm text-muted">
              Scripts kept as notes that the server runs to bring outside data into the vault,
              each only once you have approved it.
            </p>
            <.button id="open-sources" navigate={~p"/v/#{@vault.id}/sources"}>
              <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Sources
            </.button>
          </div>
        </.panel>

        <.panel :if={@sharing} id="members" title="People">
          <.rows>
            <li
              :for={member <- @members}
              id={"member-#{member.user_id}"}
              class="flex items-center gap-2 py-2 pl-4 pr-2"
            >
              <span class="min-w-0 flex-1 truncate text-ink">
                {member.user.email || member.user.name}
              </span>
              <form
                id={"role-#{member.user_id}"}
                phx-change="set_role"
                phx-auto-recover="ignore"
                class="relative"
              >
                <input type="hidden" name="user_id" value={member.user_id} />
                <select
                  name="role"
                  aria-label="Role"
                  class={[field_class(), "h-8 appearance-none pl-2.5 pr-8 text-sm capitalize"]}
                >
                  <option
                    :for={role <- ~w(owner editor viewer)}
                    value={role}
                    selected={to_string(member.role) == role}
                  >
                    {role}
                  </option>
                </select>
                <.icon
                  name="hero-chevron-up-down-mini"
                  class="pointer-events-none absolute right-2 top-1/2 size-4 -translate-y-1/2 text-faint"
                />
              </form>
              <.icon_button
                phx-click="remove_member"
                phx-value-user_id={member.user_id}
                icon="hero-x-mark"
                label="Remove"
                tone="danger"
              />
            </li>
            <li
              :for={invitation <- @invitations}
              id={"invitation-#{invitation.id}"}
              class="flex items-center gap-2 py-2 pl-4 pr-2"
            >
              <span class="min-w-0 flex-1">
                <span class="block truncate text-ink">{invitation.email}</span>
                <span class="block text-xs text-faint">
                  Invited as {invitation.role}; joins at first sign-in
                </span>
              </span>
              <.icon_button
                id={"revoke-invitation-#{invitation.id}"}
                phx-click="revoke_invitation"
                phx-value-id={invitation.id}
                icon="hero-x-mark"
                label="Withdraw invitation"
                tone="danger"
              />
            </li>
          </.rows>
          <.form
            for={@member_form}
            id="add-member"
            phx-submit="add_member"
            class="flex flex-wrap items-end gap-2.5"
          >
            <div class="min-w-0 flex-1 basis-56">
              <.input
                field={@member_form[:email]}
                type="email"
                label="Share with"
                placeholder="person@example.com"
              />
            </div>
            <div class="flex flex-1 items-end gap-2.5 sm:flex-none">
              <div class="flex-1 sm:w-28">
                <.input
                  field={@member_form[:role]}
                  type="select"
                  label="Role"
                  class="capitalize"
                  options={~w(editor viewer owner)}
                />
              </div>
              <.button variant="primary">Share</.button>
            </div>
          </.form>
        </.panel>

        <.panel id="export" title="Copy">
          <div class="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-line bg-surface p-4">
            <p class="min-w-0 flex-1 basis-64 text-sm text-muted">
              Download every note, attachment and folder as a ZIP. Unzipped, it opens in Obsidian as a vault.
            </p>
            <.button id="export-vault" href={~p"/v/#{@vault.id}/export"} download>
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download
            </.button>
          </div>
        </.panel>

        <.panel title="Delete vault" tone="danger">
          <div class="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-danger/30 bg-danger/5 p-4">
            <p class="min-w-0 flex-1 basis-64 text-sm text-muted">
              Removes the vault, its notes, attachments and history from the server. Copies in Obsidian are not touched.
            </p>
            <.button
              id="delete-vault"
              phx-click="delete_vault"
              data-confirm={"Delete #{@vault.name} from the server?"}
              variant="danger"
            >
              Delete vault
            </.button>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
