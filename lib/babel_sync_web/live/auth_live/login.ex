defmodule BabelSyncWeb.AuthLive.Login do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts
  alias BabelSync.Auth
  alias BabelSync.Auth.{MagicLink, OIDC, Passkeys, Setup}

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:methods, Auth.methods())
     |> assign(:challenge, nil)
     |> assign(:sent_to, nil)
     |> assign(:email_form, to_form(%{"email" => ""}, as: :link))
     |> assign(:oidc_label, if(Auth.enabled?(:oidc), do: OIDC.label()))
     |> assign_stage(params)}
  end

  defp assign_stage(socket, %{"token" => token}) do
    case Auth.enabled?(:magic_link) && MagicLink.peek(token) do
      {:ok, email} -> socket |> assign(:stage, :confirm) |> assign(:link, {token, email})
      _expired -> assign(socket, :stage, :expired)
    end
  end

  defp assign_stage(socket, params) do
    cond do
      not Setup.needed?() -> assign(socket, :stage, :sign_in)
      Setup.valid?(params["setup"]) -> assign(socket, :stage, :setup)
      true -> assign(socket, :stage, :locked)
    end
  end

  @impl true
  def handle_event("request_link", %{"link" => %{"email" => email}}, socket) do
    if Auth.enabled?(:magic_link) do
      :ok = MagicLink.request(email, &url(~p"/login/link/#{&1}"))
      {:noreply, assign(socket, :sent_to, String.trim(email))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("passkey_options", _params, %{assigns: %{stage: :setup}} = socket) do
    {challenge, options} = Passkeys.registration(Accounts.single_user!())
    {:reply, %{create: options}, assign(socket, :challenge, challenge)}
  end

  def handle_event("passkey_options", _params, %{assigns: %{stage: :sign_in}} = socket) do
    if Auth.enabled?(:passkey) do
      {challenge, options} = Passkeys.authentication()
      {:reply, %{get: options}, assign(socket, :challenge, challenge)}
    else
      {:reply, %{}, socket}
    end
  end

  def handle_event("passkey_options", _params, socket), do: {:reply, %{}, socket}

  def handle_event("passkey_result", response, %{assigns: %{challenge: challenge}} = socket)
      when not is_nil(challenge) do
    socket = assign(socket, :challenge, nil)

    result =
      case socket.assigns.stage do
        :setup -> register_owner(challenge, response)
        :sign_in -> Passkeys.authenticate(challenge, response)
      end

    case result do
      {:ok, user} ->
        {:noreply, redirect(socket, to: ~p"/login/complete?token=#{Auth.handoff_token(user)}")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, "That passkey was not accepted.")}
    end
  end

  def handle_event("passkey_result", _response, socket), do: {:noreply, socket}

  def handle_event("passkey_failed", _params, socket) do
    {:noreply,
     socket
     |> assign(:challenge, nil)
     |> put_flash(:error, "The passkey prompt was dismissed or is not available here.")}
  end

  defp register_owner(challenge, response) do
    owner = Accounts.single_user!()

    with true <- Setup.needed?(),
         {:ok, _passkey} <- Passkeys.register(owner, challenge, response, "First passkey") do
      {:ok, owner}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} masthead={false}>
      <div :if={@stage != :sign_in} class="mx-auto max-w-sm py-12 md:py-24">
        <.entry {shown(assigns)} />
        <p class="mt-6 text-center text-xs text-faint">
          A self-hosted home for your Obsidian vaults.
        </p>
      </div>

      <div :if={@stage == :sign_in} id="landing" class="mx-auto max-w-6xl">
        <header class="flex items-center gap-2 pt-5 text-muted md:pt-8">
          <.logo class="size-5 text-accent" />
          <span class="font-serif text-base font-semibold tracking-tight">Babel Sync</span>
        </header>

        <section class="grid items-start gap-9 pb-14 pt-9 lg:grid-cols-12 lg:gap-14 lg:pb-20 lg:pt-16">
          <div class="animate-rise lg:col-span-7 lg:pt-6">
            <p class="font-mono text-2xs font-medium uppercase tracking-[0.18em] text-accent">
              Obsidian · self-hosted
            </p>
            <h1 class="mt-4 font-serif text-[2.25rem] font-bold leading-[1.08] tracking-tight text-ink sm:text-[3rem] lg:text-[3.75rem]">
              Your vault, working together.
            </h1>
            <p class="mt-5 max-w-xl text-lg text-muted lg:mt-7 lg:text-xl lg:leading-8">
              Sync Obsidian across your devices. Edit with other people, or let an AI agent
              work alongside you.
            </p>
            <p class="mt-4 flex items-center gap-2 text-sm text-faint lg:mt-6">
              <.icon name="hero-server-mini" class="size-4" />
              Notes and attachments stay on this server.
            </p>
          </div>
          <div class="lg:col-span-5">
            <.entry {shown(assigns)} />
          </div>
        </section>

        <section id="landing-editing" class="pb-14 lg:pb-20">
          <div class="max-w-xl">
            <h2 class="font-serif text-2xl font-bold tracking-tight text-ink lg:text-3xl">
              See each other's edits in Obsidian.
            </h2>
            <p class="mt-3 text-base text-muted lg:text-lg">
              Changes appear as you type, with a cursor showing who is editing where. Work
              offline and your edits merge when you reconnect.
            </p>
          </div>
          <div class="relative mt-8 sm:pb-[6%]">
            <img
              id="landing-desktop"
              src={~p"/images/landing/editor-desktop.png"}
              width="2048"
              height="1230"
              loading="lazy"
              alt="A trip note open in Obsidian on a desktop, with Maya's cursor on a checklist line"
              class="hidden w-[86%] rounded-2xl border border-line-strong shadow-float sm:block"
            />
            <img
              id="landing-phone"
              src={~p"/images/landing/editor-phone.png"}
              width="1170"
              height="1930"
              loading="lazy"
              alt="The same note in Obsidian on a phone, with Maya's cursor on another line"
              class="mx-auto w-[17.5rem] rounded-[1.75rem] border border-line-strong shadow-float sm:absolute sm:bottom-0 sm:right-0 sm:w-[23%] sm:rounded-2xl lg:rounded-[1.75rem]"
            />
          </div>
        </section>

        <section
          id="landing-devices"
          class="grid items-center gap-8 pb-14 lg:grid-cols-12 lg:gap-14 lg:pb-20"
        >
          <div class="lg:col-span-5">
            <h2 class="font-serif text-2xl font-bold tracking-tight text-ink lg:text-3xl">
              Pick up on another device.
            </h2>
            <p class="mt-3 text-base text-muted lg:text-lg">
              Notes and attachments sync between desktop and mobile. Turn on settings sync to
              bring your themes, hotkeys and plugins along.
            </p>
          </div>
          <img
            id="landing-settings"
            src={~p"/images/landing/sync-settings.png"}
            width="1275"
            height="650"
            loading="lazy"
            alt="The Babel Sync settings in Obsidian, showing the vault is up to date"
            class="hidden w-full rounded-2xl border border-line-strong shadow-float sm:block lg:col-span-7"
          />
          <img
            id="landing-settings-phone"
            src={~p"/images/landing/sync-settings-phone.png"}
            width="1170"
            height="1790"
            loading="lazy"
            alt="The Babel Sync settings in Obsidian on a phone, showing the vault is up to date"
            class="mx-auto w-[17.5rem] rounded-[1.75rem] border border-line-strong shadow-float sm:hidden"
          />
        </section>

        <section id="landing-more" class="border-t border-line pb-16 lg:pb-24">
          <dl class="grid sm:grid-cols-2 sm:gap-x-14">
            <div
              :for={
                {icon, title, text} <- [
                  {"hero-globe-alt", "Open your vault in a browser.",
                   "Read and edit notes without opening Obsidian."},
                  {"hero-sparkles", "Work with an agent in your vault.",
                   "Connect Claude or ChatGPT through MCP to read and edit your notes."},
                  {"hero-clock", "Recover an earlier version.",
                   "Deleted notes wait in the trash, and every note keeps its history."},
                  {"hero-server-stack", "Run it yourself.",
                   "SQLite on one machine, or PostgreSQL with S3 storage."}
                ]
              }
              class="flex gap-4 border-b border-line py-6"
            >
              <.icon name={icon} class="mt-0.5 size-5 shrink-0 text-accent" />
              <div>
                <dt class="font-semibold text-ink">{title}</dt>
                <dd class="mt-1 text-muted">{text}</dd>
              </div>
            </div>
          </dl>
        </section>

        <footer class="flex items-center justify-between gap-4 pb-10 text-xs text-faint">
          <span>A self-hosted home for your Obsidian vaults.</span>
          <a
            href="#sign-in"
            class="font-medium text-muted transition-colors duration-150 hover:text-ink"
          >
            Sign in <.icon name="hero-arrow-up-mini" class="size-3.5" />
          </a>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp shown(assigns) do
    Map.take(assigns, [:stage, :methods, :oidc_label, :sent_to, :email_form, :link])
  end

  attr :stage, :atom, required: true
  attr :methods, :list, required: true
  attr :oidc_label, :string, default: nil
  attr :sent_to, :string, default: nil
  attr :email_form, :any, required: true
  attr :link, :any, default: nil

  defp entry(assigns) do
    ~H"""
    <div
      id="sign-in"
      class="animate-rise scroll-mt-6 space-y-6 rounded-2xl border border-line bg-surface p-6 shadow-float sm:p-8"
    >
      <div class="space-y-4 text-center">
        <span
          :if={@stage != :sign_in}
          class="mx-auto grid size-14 place-items-center rounded-2xl bg-accent/12 text-accent"
        >
          <.logo class="size-8" />
        </span>
        <.dynamic_tag
          tag_name={if(@stage == :sign_in, do: "h2", else: "h1")}
          class="font-serif text-xl font-bold tracking-tight text-ink"
        >
          {heading(@stage)}
        </.dynamic_tag>
      </div>

      <%= case @stage do %>
        <% :locked -> %>
          <p id="setup-locked" class="text-center text-muted">
            This server has no passkey yet. Open the setup link printed in the server log to
            register the first one.
          </p>
        <% :setup -> %>
          <p class="text-center text-muted">
            Register a passkey on this device. It becomes the way to sign in.
          </p>
          <.button
            id="passkey-setup"
            phx-hook="Passkey"
            variant="primary"
            size="lg"
            class="w-full"
          >
            <.icon name="hero-finger-print" class="size-5" /> Create passkey
          </.button>
        <% :expired -> %>
          <p id="link-expired" class="text-center text-muted">
            That link has expired or was already used.
          </p>
          <.button navigate={~p"/login"} size="lg" class="w-full">Back to sign in</.button>
        <% :confirm -> %>
          <p class="text-center text-muted">
            Continue as <strong class="font-semibold text-ink">{elem(@link, 1)}</strong>
          </p>
          <.form for={%{}} id="link-confirm" action={~p"/login/link"}>
            <input type="hidden" name="token" value={elem(@link, 0)} />
            <.button variant="primary" size="lg" class="w-full">Sign in</.button>
          </.form>
        <% :sign_in -> %>
          <div class="space-y-2.5">
            <.button
              :if={:oidc in @methods}
              id="oidc-sign-in"
              href={~p"/login/oidc"}
              variant="primary"
              size="lg"
              class="w-full"
            >
              <.icon name="hero-building-office-2" class="size-5" /> Continue with {@oidc_label}
            </.button>

            <.button
              :if={:passkey in @methods}
              id="passkey-sign-in"
              phx-hook="Passkey"
              variant={if(:oidc in @methods, do: "secondary", else: "primary")}
              size="lg"
              class="w-full"
            >
              <.icon name="hero-finger-print" class="size-5" /> Use a passkey
            </.button>
          </div>

          <div :if={:magic_link in @methods} class="space-y-4">
            <div
              :if={@methods != [:magic_link]}
              class="flex items-center gap-3 text-2xs font-medium uppercase tracking-[0.14em] text-faint"
            >
              <span class="h-px flex-1 bg-line"></span> or <span class="h-px flex-1 bg-line"></span>
            </div>

            <p
              :if={@sent_to}
              id="link-sent"
              class="flex gap-3 rounded-xl border border-accent/30 bg-accent/8 p-3.5 text-sm text-ink"
            >
              <.icon name="hero-envelope-open" class="mt-0.5 size-5 shrink-0 text-accent" />
              <span>
                If <strong class="font-semibold">{@sent_to}</strong>
                can sign in here, a link is on its way.
              </span>
            </p>

            <.form
              :if={!@sent_to}
              for={@email_form}
              id="link-form"
              phx-submit="request_link"
              class="space-y-2.5"
            >
              <.input
                field={@email_form[:email]}
                type="email"
                placeholder="you@example.com"
                autocomplete="email"
                aria-label="Email address"
                class="h-11"
                required
              />
              <.button
                variant={if(@methods == [:magic_link], do: "primary", else: "secondary")}
                size="lg"
                class="w-full"
              >
                <.icon name="hero-envelope" class="size-5" /> Email me a link
              </.button>
            </.form>
          </div>
      <% end %>
    </div>
    """
  end

  defp heading(:setup), do: "Set up Babel Sync"
  defp heading(:locked), do: "Set up Babel Sync"
  defp heading(_stage), do: "Sign in to Babel Sync"
end
