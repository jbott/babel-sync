defmodule BabelSyncWeb.AuthLive.Login do
  use BabelSyncWeb, :live_view

  alias BabelSync.Accounts
  alias BabelSync.Auth
  alias BabelSync.Auth.{MagicLink, OIDC, Passkeys, Setup}
  alias BabelSync.RateLimit

  on_mount {BabelSyncWeb.LiveScope, :signed_out}

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:methods, Auth.methods())
     |> assign(:challenge, nil)
     |> assign(:address, BabelSyncWeb.ClientAddress.of_socket(socket))
     |> assign(:sent_to, nil)
     |> assign(:email_form, to_form(%{"email" => ""}, as: :link))
     |> assign(:oidc_label, if(Auth.enabled?(:oidc), do: OIDC.label()))
     |> assign_stage(params)}
  end

  defp request_link(address, email) do
    case RateLimit.allow(:sign_in_link, address) do
      :ok -> MagicLink.request(email, &url(~p"/login/link/#{&1}"))
      {:error, _retry_after} -> {:error, :busy}
    end
  end

  defp assign_stage(socket, %{"token" => token}) do
    case Auth.enabled?(:magic_link) && MagicLink.peek(token) do
      {:ok, email} -> socket |> assign(:stage, :confirm) |> assign(:link, {token, email})
      _expired -> assign(socket, :stage, :expired)
    end
  end

  defp assign_stage(socket, :not_mounted_at_router), do: assign_stage(socket, %{})

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
      case request_link(socket.assigns.address, email) do
        :ok ->
          {:noreply, assign(socket, :sent_to, String.trim(email))}

        {:error, :busy} ->
          {:noreply,
           put_flash(socket, :error, "Too many sign-in links were sent. Try again in an hour.")}

        {:error, :unsent} ->
          {:noreply,
           put_flash(socket, :error, "The sign-in email could not be sent. Try again later.")}
      end
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
      case {socket.assigns.stage, RateLimit.allow(:sign_in, socket.assigns.address)} do
        {_stage, {:error, _retry_after}} -> {:error, :too_many}
        {:setup, :ok} -> register_owner(challenge, response)
        {:sign_in, :ok} -> Passkeys.authenticate(challenge, response)
      end

    case result do
      {:ok, user} ->
        {:noreply, redirect(socket, to: ~p"/login/complete?token=#{Auth.handoff_token(user)}")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, "That passkey was not accepted.")}

      {:error, :too_many} ->
        {:noreply,
         put_flash(socket, :error, "Too many attempts from this address. Try again in a minute.")}
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
    <Layouts.app flash={@flash} current_scope={@current_scope} column="max-w-6xl">
      <:aside :if={@stage == :sign_in}>
        <a
          id="header-log-in"
          href="#sign-in"
          class="inline-flex h-8 items-center rounded-lg border border-line-strong bg-surface px-3 text-sm font-semibold text-ink shadow-raise transition duration-150 hover:border-accent hover:text-accent active:translate-y-px"
        >
          Log in
        </a>
      </:aside>
      <div :if={@stage != :sign_in} class="mx-auto max-w-sm py-12 md:py-24">
        <.entry {shown(assigns)} />
        <p class="mt-6 text-center text-xs text-faint">
          A self-hosted home for your Obsidian vaults.
        </p>
      </div>

      <div :if={@stage == :sign_in} id="landing" class="mx-auto max-w-6xl">
        <section class="grid items-start gap-9 pb-14 pt-9 lg:grid-cols-12 lg:gap-14 lg:pb-20 lg:pt-16">
          <div class="animate-rise lg:col-span-7 lg:pt-6">
            <h1 class="font-serif text-[2.25rem] font-bold leading-[1.08] tracking-tight text-ink sm:text-[3rem] lg:text-[3.75rem]">
              Your vault, working together.
            </h1>
            <p class="mt-5 max-w-xl text-lg text-muted lg:mt-7 lg:text-xl lg:leading-8">
              Sync Obsidian across your devices. Edit with other people, or let an AI agent
              work alongside you.
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
            <.mac
              id="landing-desktop"
              src={~p"/images/landing/editor-desktop.png"}
              alt="A trip note open in Obsidian on a Mac, with Maya's cursor on a checklist line"
              class="w-full sm:w-[88%]"
            />
            <.iphone
              id="landing-phone"
              src={~p"/images/landing/editor-phone.png"}
              height="2340"
              alt="The same note in Obsidian on an iPhone, with Sam's cursor on another line"
              class="relative -mt-[13%] ml-auto w-[46%] sm:absolute sm:bottom-0 sm:right-0 sm:mt-0 sm:w-[19%]"
            />
          </div>
        </section>

        <section
          id="landing-devices"
          class="grid items-center gap-8 pb-14 sm:grid-cols-2 lg:gap-14 lg:pb-20"
        >
          <div class="max-w-xl">
            <h2 class="font-serif text-2xl font-bold tracking-tight text-ink lg:text-3xl">
              Pick up on another device.
            </h2>
            <p class="mt-3 text-base text-muted lg:text-lg">
              Notes and attachments sync between desktop and mobile. Turn on settings sync to
              bring your themes, hotkeys and plugins along.
            </p>
          </div>
          <.iphone
            id="landing-settings-phone"
            src={~p"/images/landing/sync-settings-phone.png"}
            height="2280"
            alt="The Babel Sync settings in Obsidian on an iPhone, showing the vault is up to date"
            class="mx-auto w-[15rem] lg:w-[17rem]"
          />
        </section>

        <section id="landing-agents" class="pb-14 lg:pb-20">
          <div class="max-w-xl">
            <h2 class="font-serif text-2xl font-bold tracking-tight text-ink lg:text-3xl">
              Ask Claude or ChatGPT about your notes.
            </h2>
            <p class="mt-3 text-base text-muted lg:text-lg">
              Babel Sync works with the Claude and ChatGPT apps. Add this server as a connector
              and the assistant can search, read and edit your vault from your phone or desktop.
              Its edits merge with what you are typing and show up in each note's history.
            </p>
          </div>
          <div class="mt-8 flex items-start justify-center pb-[2%]">
            <.chat
              id="landing-claude"
              app="Claude"
              light
              ask="Add the Sintra train times to the Lisbon note."
              calls={[
                {"Search files", "Lisbon"},
                {"Edit file", "Trips/Lisbon in May.md"}
              ]}
              answer="Done. The times are under Booked, next to the train to Sintra."
              prompt="Reply to Claude"
              class="w-[54%] sm:w-[15rem] lg:w-[17rem]"
            />
            <.chat
              id="landing-chatgpt"
              app="ChatGPT"
              ask="What is left to book for Lisbon?"
              calls={[{"Read file", "Trips/Lisbon in May.md"}]}
              answer="Two things are still open: the train to Sintra on Sunday, and dinner at Prado."
              prompt="Ask anything"
              class="relative -ml-[10%] mt-[16%] w-[54%] sm:-ml-14 sm:mt-24 sm:w-[15rem] lg:w-[17rem]"
            />
          </div>
        </section>

        <section id="landing-more" class="border-t border-line pb-16 lg:pb-24">
          <dl class="grid lg:grid-cols-3 lg:gap-x-12">
            <div
              :for={
                {icon, title, text} <- [
                  {"hero-globe-alt", "Open your vault in a browser.",
                   "Read and edit notes without opening Obsidian."},
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

  attr :id, :string, required: true
  attr :src, :string, required: true
  attr :alt, :string, required: true
  attr :class, :any, default: nil

  defp mac(assigns) do
    ~H"""
    <figure id={@id} class={["@container", @class]}>
      <div class="mx-[6%] rounded-t-[2.2cqw] border border-b-0 border-[#48484a] bg-[#1c1c1e] p-[1.1cqw] pb-[1.4cqw] shadow-float">
        <div class="relative overflow-hidden rounded-[0.9cqw]">
          <span class="absolute left-[1.7cqw] top-[1.15cqw] flex gap-[0.7cqw]" aria-hidden="true">
            <i class="size-[1.05cqw] rounded-full bg-[#ff5f57]"></i>
            <i class="size-[1.05cqw] rounded-full bg-[#febc2e]"></i>
            <i class="size-[1.05cqw] rounded-full bg-[#28c840]"></i>
          </span>
          <img src={@src} width="2048" height="1230" loading="lazy" alt={@alt} class="block w-full" />
        </div>
      </div>
      <div
        class="relative h-[1.7cqw] rounded-b-[1.6cqw] rounded-t-[0.3cqw] border border-[#8e8e93] bg-linear-to-b from-[#d1d1d6] to-[#a1a1a6] shadow-float"
        aria-hidden="true"
      >
        <span class="absolute left-1/2 top-0 h-[0.6cqw] w-[13cqw] -translate-x-1/2 rounded-b-[0.6cqw] bg-[#8e8e93]"></span>
      </div>
    </figure>
    """
  end

  attr :id, :string, required: true
  attr :src, :string, default: nil
  attr :alt, :string, default: nil
  attr :height, :string, default: nil
  attr :light, :boolean, default: false
  attr :screen, :string, default: "bg-[#000]"
  attr :class, :any, default: nil
  slot :inner_block

  defp iphone(assigns) do
    ~H"""
    <figure id={@id} class={["@container", @class]}>
      <div class="rounded-[15cqw] border border-[#48484a] bg-[#1c1c1e] p-[2.6cqw] shadow-float">
        <div class={[
          "relative flex aspect-[390/844] flex-col overflow-hidden rounded-[12.4cqw]",
          @screen,
          if(@light, do: "text-[#141413]", else: "text-[#fff]")
        ]}>
          <div class="relative h-[13cqw] shrink-0" aria-hidden="true">
            <span class="absolute left-[9cqw] top-[5cqw] text-[4.4cqw] font-semibold leading-none">
              9:41
            </span>
            <span class="absolute left-1/2 top-[3.2cqw] h-[8cqw] w-[27cqw] -translate-x-1/2 rounded-full bg-[#1c1c1e]"></span>
            <span class="absolute right-[8cqw] top-[5.2cqw] h-[3.6cqw] w-[7.4cqw] rounded-[1.1cqw] border border-current/45 p-px">
              <i class="block h-full w-4/5 rounded-[0.7cqw] bg-current"></i>
            </span>
          </div>
          <img
            :if={@src}
            src={@src}
            width="1170"
            height={@height}
            loading="lazy"
            alt={@alt}
            class="block min-h-0 w-full flex-1 object-cover object-top"
          />
          {render_slot(@inner_block)}
          <span
            class="absolute bottom-[2.2cqw] left-1/2 h-[1.3cqw] w-[36cqw] -translate-x-1/2 rounded-full bg-current/85"
            aria-hidden="true"
          ></span>
        </div>
      </div>
    </figure>
    """
  end

  attr :id, :string, required: true
  attr :app, :string, required: true
  attr :light, :boolean, default: false
  attr :ask, :string, required: true
  attr :calls, :list, required: true
  attr :answer, :string, required: true
  attr :prompt, :string, required: true
  attr :class, :any, default: nil

  defp chat(assigns) do
    ~H"""
    <.iphone
      id={@id}
      light={@light}
      screen={if(@light, do: "bg-[#faf9f5]", else: "bg-[#212121]")}
      class={@class}
    >
      <div
        class="flex min-h-0 flex-1 flex-col px-[5cqw] pb-[7cqw] text-[4.8cqw] leading-[1.45]"
        role="img"
        aria-label={"A conversation in the #{@app} app: asked “#{@ask}”, the assistant uses Babel Sync and answers “#{@answer}”"}
      >
        <div class="flex items-center justify-between pb-[3cqw] pt-[1cqw]">
          <.icon name="hero-bars-2" class="size-[6cqw] opacity-70" />
          <span class="text-[4.8cqw] font-semibold">{@app}</span>
          <.icon name="hero-pencil-square" class="size-[5.6cqw] opacity-70" />
        </div>

        <div class="flex min-h-0 flex-1 flex-col gap-[4cqw] pt-[3cqw]">
          <p class={[
            "ml-auto max-w-[82%] px-[4cqw] py-[2.6cqw]",
            if(@light,
              do: "rounded-[4cqw] bg-[#f0eee6]",
              else: "rounded-[6cqw] bg-[#303030]"
            )
          ]}>
            {@ask}
          </p>

          <ul class="space-y-[1.6cqw]">
            <li
              :for={{tool, target} <- @calls}
              class={[
                "flex items-center gap-[2cqw] rounded-[3cqw] border px-[3cqw] py-[2.6cqw] text-[3.9cqw] leading-tight",
                if(@light, do: "border-[#141413]/12", else: "border-[#fff]/14")
              ]}
            >
              <.logo class="size-[4.4cqw] shrink-0 text-[#2f8f83]" />
              <span class="min-w-0 flex-1">
                <span class="block font-semibold">Babel Sync · {tool}</span>
                <span class="block truncate opacity-60">{target}</span>
              </span>
              <.icon name="hero-check-mini" class="size-[4cqw] shrink-0 opacity-60" />
            </li>
          </ul>

          <p class={[@light && "font-serif"]}>{@answer}</p>
        </div>

        <div class={[
          "flex items-center gap-[2.5cqw] px-[4cqw] py-[3.4cqw] text-[4.4cqw]",
          if(@light,
            do: "rounded-[5cqw] border border-[#141413]/12 bg-[#fff]",
            else: "rounded-full bg-[#303030]"
          )
        ]}>
          <.icon name="hero-plus" class="size-[5cqw] opacity-60" />
          <span class="flex-1 opacity-50">{@prompt}</span>
          <span class={[
            "grid size-[7cqw] place-items-center rounded-full",
            if(@light, do: "bg-[#d97757] text-[#fff]", else: "bg-[#fff] text-[#000]")
          ]}>
            <.icon name="hero-arrow-up-mini" class="size-[4.4cqw]" />
          </span>
        </div>
      </div>
    </.iphone>
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
      class="animate-rise scroll-mt-20 space-y-6 rounded-2xl border border-line bg-surface p-6 shadow-float sm:p-8"
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
