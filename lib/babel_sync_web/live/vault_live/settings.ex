defmodule BabelSyncWeb.VaultLive.Settings do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts
  alias BabelSync.Accounts.Scope
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
       |> assign(:members, Vaults.list_members(vault))}
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
    case Accounts.get_user_by_email(email) do
      nil ->
        {:noreply,
         put_flash(socket, :error, "No account uses #{email}. They need to sign in once first.")}

      user ->
        {:ok, _member} =
          Vaults.put_member(socket.assigns.vault, user, String.to_existing_atom(role))

        {:noreply, reload(socket)}
    end
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

  defp reload(socket), do: assign(socket, :members, Vaults.list_members(socket.assigns.vault))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl px-4 py-10 space-y-10">
        <.header>
          {@vault.name}
          <:subtitle>
            <.link navigate={Paths.vault(@vault.id)} class="link">Back to the vault</.link>
          </:subtitle>
        </.header>

        <.form for={@name_form} id="rename-vault" phx-submit="rename" class="flex items-end gap-3">
          <div class="flex-1"><.input field={@name_form[:name]} label="Name" /></div>
          <.button class="mb-2">Save</.button>
        </.form>

        <section id="agents" class="space-y-3">
          <h2 class="font-semibold">Agents</h2>
          <form id="agent-access" phx-change="set_agent_access">
            <label class="flex items-start gap-3 cursor-pointer">
              <input type="hidden" name="agents_see_config" value="false" />
              <input
                type="checkbox"
                id="agents-see-config"
                name="agents_see_config"
                value="true"
                checked={@vault.agents_see_config}
                class="checkbox checkbox-sm mt-0.5"
              />
              <span>
                <span class="block font-medium">Let agents into the .obsidian folder</span>
                <span class="block text-sm text-base-content/60">
                  Off, agents connected over MCP cannot see or change Obsidian's settings and
                  plugins in this vault. On, an agent that may write can install or replace a
                  plugin, which then runs on every device that syncs the vault.
                </span>
              </span>
            </label>
          </form>
        </section>

        <section :if={@sharing} id="members" class="space-y-4">
          <h2 class="font-semibold">People</h2>
          <ul class="divide-y divide-base-300 border border-base-300 rounded-box">
            <li
              :for={member <- @members}
              id={"member-#{member.user_id}"}
              class="flex items-center gap-3 px-4 py-2"
            >
              <span class="flex-1 truncate">{member.user.email || member.user.name}</span>
              <form id={"role-#{member.user_id}"} phx-change="set_role">
                <input type="hidden" name="user_id" value={member.user_id} />
                <select name="role" class="select select-sm">
                  <option
                    :for={role <- ~w(owner editor viewer)}
                    value={role}
                    selected={to_string(member.role) == role}
                  >
                    {role}
                  </option>
                </select>
              </form>
              <button
                phx-click="remove_member"
                phx-value-user_id={member.user_id}
                class="btn btn-ghost btn-xs"
                title="Remove"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </li>
          </ul>
          <.form
            for={@member_form}
            id="add-member"
            phx-submit="add_member"
            class="flex items-end gap-3"
          >
            <div class="flex-1">
              <.input
                field={@member_form[:email]}
                type="email"
                label="Share with"
                placeholder="person@example.com"
              />
            </div>
            <.input
              field={@member_form[:role]}
              type="select"
              label="Role"
              options={~w(editor viewer owner)}
            />
            <.button class="mb-2">Share</.button>
          </.form>
        </section>

        <section class="space-y-3">
          <h2 class="font-semibold text-error">Delete vault</h2>
          <p class="text-sm text-base-content/70">
            Removes the vault, its notes, attachments and history from the server. Copies in Obsidian are not touched.
          </p>
          <button
            id="delete-vault"
            phx-click="delete_vault"
            data-confirm={"Delete #{@vault.name} from the server?"}
            class="btn btn-error btn-outline btn-sm"
          >
            Delete vault
          </button>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
