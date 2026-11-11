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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm px-4 py-20">
        <div class="rounded-2xl border border-base-300 bg-base-100 p-8 shadow-sm space-y-6">
          <div class="space-y-1 text-center">
            <.icon name="hero-square-3-stack-3d" class="size-9 text-primary" />
            <h1 class="text-xl font-semibold">{heading(@stage)}</h1>
          </div>

          <%= case @stage do %>
            <% :locked -> %>
              <p id="setup-locked" class="text-sm text-base-content/70 text-center">
                This server has no passkey yet. Open the setup link printed in the server log to
                register the first one.
              </p>
            <% :setup -> %>
              <p class="text-sm text-base-content/70 text-center">
                Register a passkey on this device. It becomes the way to sign in.
              </p>
              <button
                id="passkey-setup"
                phx-hook="Passkey"
                class="btn btn-primary w-full transition hover:-translate-y-px"
              >
                <.icon name="hero-finger-print" class="size-5" /> Create passkey
              </button>
            <% :expired -> %>
              <p id="link-expired" class="text-sm text-base-content/70 text-center">
                That link has expired or was already used.
              </p>
              <.link navigate={~p"/login"} class="btn w-full">Back to sign in</.link>
            <% :confirm -> %>
              <p class="text-sm text-base-content/70 text-center">
                Continue as <strong>{elem(@link, 1)}</strong>
              </p>
              <.form for={%{}} id="link-confirm" action={~p"/login/link"}>
                <input type="hidden" name="token" value={elem(@link, 0)} />
                <button class="btn btn-primary w-full transition hover:-translate-y-px">
                  Sign in
                </button>
              </.form>
            <% :sign_in -> %>
              <div class="space-y-3">
                <.link
                  :if={:oidc in @methods}
                  id="oidc-sign-in"
                  href={~p"/login/oidc"}
                  class="btn btn-primary w-full transition hover:-translate-y-px"
                >
                  <.icon name="hero-building-office-2" class="size-5" /> Continue with {@oidc_label}
                </.link>

                <button
                  :if={:passkey in @methods}
                  id="passkey-sign-in"
                  phx-hook="Passkey"
                  class={[
                    "btn w-full transition hover:-translate-y-px",
                    :oidc not in @methods && "btn-primary"
                  ]}
                >
                  <.icon name="hero-finger-print" class="size-5" /> Use a passkey
                </button>
              </div>

              <div :if={:magic_link in @methods} class="space-y-3">
                <div
                  :if={@methods != [:magic_link]}
                  class="flex items-center gap-3 text-xs text-base-content/40"
                >
                  <span class="h-px flex-1 bg-base-300"></span>
                  or <span class="h-px flex-1 bg-base-300"></span>
                </div>

                <p :if={@sent_to} id="link-sent" class="rounded-lg bg-success/10 p-3 text-sm">
                  If <strong>{@sent_to}</strong> can sign in here, a link is on its way.
                </p>

                <.form
                  :if={!@sent_to}
                  for={@email_form}
                  id="link-form"
                  phx-submit="request_link"
                  class="space-y-2"
                >
                  <.input
                    field={@email_form[:email]}
                    type="email"
                    placeholder="you@example.com"
                    autocomplete="email"
                    required
                  />
                  <button class="btn w-full transition hover:-translate-y-px">
                    <.icon name="hero-envelope" class="size-5" /> Email me a link
                  </button>
                </.form>
              </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp heading(:setup), do: "Set up BabelSync"
  defp heading(:locked), do: "Set up BabelSync"
  defp heading(_stage), do: "Sign in to BabelSync"
end
