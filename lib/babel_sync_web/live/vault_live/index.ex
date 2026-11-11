defmodule BabelSyncWeb.VaultLive.Index do
  use BabelSyncWeb, :live_view

  alias BabelSync.Vaults
  alias BabelSync.Vaults.Vault
  alias BabelSyncWeb.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Vaults")
     |> assign(:form, to_form(Vault.changeset(%Vault{}, %{})))
     |> stream(:vaults, Vaults.list_vaults(socket.assigns.current_scope.user))}
  end

  @impl true
  def handle_event("create", %{"vault" => params}, socket) do
    case Vaults.create_vault(socket.assigns.current_scope.user, params) do
      {:ok, vault} -> {:noreply, push_navigate(socket, to: Paths.vault(vault.id))}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl px-4 py-10 space-y-8">
        <.header>
          Vaults
          <:subtitle>Each vault syncs with one Obsidian vault folder.</:subtitle>
        </.header>

        <ul id="vaults" phx-update="stream" class="menu bg-base-200 rounded-box w-full">
          <li id="vaults-empty" class="hidden only:block px-4 py-3 text-base-content/60">
            No vaults yet. Create the first one below.
          </li>
          <li :for={{id, vault} <- @streams.vaults} id={id}>
            <.link navigate={Paths.vault(vault.id)} class="flex items-center gap-3">
              <.icon name="hero-archive-box" class="size-5" />
              <span class="font-medium">{vault.name}</span>
            </.link>
          </li>
        </ul>

        <.form for={@form} id="new-vault" phx-submit="create" class="flex items-end gap-3">
          <div class="flex-1">
            <.input field={@form[:name]} label="New vault" placeholder="Personal notes" />
          </div>
          <.button variant="primary" class="mb-2">Create</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
