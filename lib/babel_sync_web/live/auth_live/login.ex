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
      <div class="mx-auto max-w-sm py-12 md:py-24">
        <div class="animate-rise space-y-6 rounded-2xl border border-line bg-surface p-6 shadow-float sm:p-8">
          <div class="space-y-4 text-center">
            <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-accent/12 text-accent">
              <.logo class="size-8" />
            </span>
            <h1 class="font-serif text-xl font-bold tracking-tight text-ink">{heading(@stage)}</h1>
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
                  <span class="h-px flex-1 bg-line"></span>
                  or <span class="h-px flex-1 bg-line"></span>
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
        <p class="mt-6 text-center text-xs text-faint">
          A self-hosted home for your Obsidian vaults.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp heading(:setup), do: "Set up BabelSync"
  defp heading(:locked), do: "Set up BabelSync"
  defp heading(_stage), do: "Sign in to BabelSync"
end
