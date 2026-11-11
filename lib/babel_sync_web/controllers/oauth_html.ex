defmodule BabelSyncWeb.OAuthHTML do
  use BabelSyncWeb, :html

  attr :request, :map, required: true
  attr :params, :map, required: true
  attr :flash, :map, required: true
  attr :current_scope, :map, required: true

  def consent(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md px-4 py-16">
        <div class="rounded-2xl border border-base-300 bg-base-100 p-8 shadow-sm space-y-6">
          <div class="flex items-center gap-3">
            <span class="grid size-11 place-items-center rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-link" class="size-6" />
            </span>
            <div>
              <h1 id="consent-client" class="text-lg font-semibold leading-tight">
                {@request.client.name}
              </h1>
              <p class="text-sm text-base-content/60">wants to connect to BabelSync</p>
            </div>
          </div>

          <ul class="space-y-3 text-sm">
            <li class="flex gap-3">
              <.icon name="hero-user-circle" class="size-5 shrink-0 text-base-content/50" />
              <span>
                Acting as <strong>{@current_scope.user.email || @current_scope.user.name}</strong>
              </span>
            </li>
            <li id="consent-access" class="flex gap-3">
              <.icon
                name={if(@request.read_only, do: "hero-eye", else: "hero-pencil-square")}
                class="size-5 shrink-0 text-base-content/50"
              />
              <span :if={@request.read_only}>It can <strong>read</strong> every vault you can open.</span>
              <span :if={not @request.read_only}>
                It can <strong>read and change</strong> every vault you can open.
              </span>
            </li>
            <li class="flex gap-3">
              <.icon name="hero-arrow-uturn-right" class="size-5 shrink-0 text-base-content/50" />
              <span class="break-all">
                You will be sent back to <code class="text-xs">{@request.redirect_uri}</code>
              </span>
            </li>
          </ul>

          <.form for={%{}} id="consent-form" action={~p"/oauth/authorize"} class="flex gap-3">
            <input :for={{name, value} <- @params} type="hidden" name={name} value={value} />
            <button
              id="consent-deny"
              name="decision"
              value="deny"
              class="btn flex-1 transition hover:-translate-y-px"
            >
              Cancel
            </button>
            <button
              id="consent-approve"
              name="decision"
              value="approve"
              class="btn btn-primary flex-1 transition hover:-translate-y-px"
            >
              Allow
            </button>
          </.form>

          <p class="text-xs text-base-content/50">
            You can disconnect it again at any time from your account page.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :reason, :atom, required: true
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil

  def invalid(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md px-4 py-16 text-center space-y-3">
        <.icon name="hero-exclamation-triangle" class="size-10 text-warning" />
        <h1 id="oauth-invalid" class="text-lg font-semibold">This app could not be connected</h1>
        <p :if={@reason == :unknown_client} class="text-sm text-base-content/60">
          The app is not registered with this server. Start again from the app.
        </p>
        <p :if={@reason == :bad_redirect_uri} class="text-sm text-base-content/60">
          The app asked to be sent back to an address it did not register.
        </p>
        <p :if={@reason == :malformed_request} class="text-sm text-base-content/60">
          The app sent a request this server does not understand. Start again from the app.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
