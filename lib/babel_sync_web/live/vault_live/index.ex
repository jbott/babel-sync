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
      <div class="mx-auto max-w-2xl space-y-8 py-8 md:py-14">
        <.header>
          Vaults
          <:subtitle>Each vault syncs with one Obsidian vault folder.</:subtitle>
        </.header>

        <.rows id="vaults" phx-update="stream">
          <li id="vaults-empty" class="hidden px-6 py-10 text-center only:block">
            <.logo class="mx-auto size-10 text-line-strong" />
            <p class="mt-3 text-muted">No vaults yet. Create the first one below.</p>
          </li>
          <li :for={{id, vault} <- @streams.vaults} id={id}>
            <.link
              navigate={Paths.vault(vault.id)}
              class="group flex items-center gap-3.5 px-4 py-3.5 transition-colors duration-150 hover:bg-canvas"
            >
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/12 text-accent transition-colors duration-150 group-hover:bg-accent group-hover:text-accent-ink">
                <.logo class="size-5" />
              </span>
              <span class="min-w-0 flex-1 truncate font-serif text-lg font-bold tracking-tight text-ink">
                {vault.name}
              </span>
              <.icon
                name="hero-arrow-right-mini"
                class="size-4 shrink-0 text-faint transition duration-150 group-hover:translate-x-0.5 group-hover:text-ink"
              />
            </.link>
          </li>
        </.rows>

        <.panel title="New vault">
          <.form for={@form} id="new-vault" phx-submit="create" class="flex items-start gap-2.5">
            <div class="flex-1">
              <.input field={@form[:name]} aria-label="New vault" placeholder="Personal notes" />
            </div>
            <.button variant="primary">
              <.icon name="hero-plus-mini" class="size-4" /> Create
            </.button>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
