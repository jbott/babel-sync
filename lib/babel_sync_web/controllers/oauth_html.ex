defmodule BabelSyncWeb.OAuthHTML do
  use BabelSyncWeb, :html

  attr :request, :map, required: true
  attr :params, :map, required: true
  attr :flash, :map, required: true
  attr :current_scope, :map, required: true

  def consent(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} column="max-w-md">
      <div class="mx-auto max-w-md pb-12 pt-7 md:pb-20 md:pt-12">
        <div class="animate-rise overflow-hidden rounded-2xl border border-line bg-surface shadow-float">
          <div class="space-y-5 p-6 sm:p-8">
            <div class="flex items-center gap-2 text-faint" aria-hidden="true">
              <span class="grid size-11 place-items-center rounded-xl border border-line bg-canvas text-muted">
                <.icon name="hero-puzzle-piece" class="size-5" />
              </span>
              <span class="h-px w-5 bg-line-strong"></span>
              <.icon name="hero-arrows-right-left-mini" class="size-4" />
              <span class="h-px w-5 bg-line-strong"></span>
              <span class="grid size-11 place-items-center rounded-xl bg-accent/12 text-accent">
                <.logo class="size-6" />
              </span>
            </div>
            <div>
              <h1
                id="consent-client"
                class="break-words font-serif text-xl font-bold tracking-tight text-ink"
              >
                {@request.client.name}
              </h1>
              <p class="mt-0.5 text-muted">wants to connect to BabelSync</p>
            </div>
            <p id="consent-destination" class="text-ink">
              Access will be handed to
              <strong class="wrap-anywhere font-semibold">{destination(@request.redirect_uri)}</strong>
            </p>
            <p
              :if={is_nil(@request.client.approved_at)}
              id="consent-first-time"
              class="flex gap-2.5 rounded-xl border border-warn/40 bg-warn/10 p-3 text-sm text-ink"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-warn" />
              <span>
                This app has not been approved here before. Anyone can give an app any name, so
                allow it only if you started this yourself a moment ago.
              </span>
            </p>
          </div>

          <ul class="divide-y divide-line border-y border-line bg-canvas/60 text-sm">
            <li class="flex gap-3 px-6 py-3.5 sm:px-8">
              <.icon name="hero-user-circle" class="mt-0.5 size-5 shrink-0 text-faint" />
              <span class="min-w-0 break-words">
                Acting as
                <strong class="font-semibold text-ink">
                  {@current_scope.user.email || @current_scope.user.name}
                </strong>
              </span>
            </li>
            <li id="consent-access" class="flex gap-3 px-6 py-3.5 sm:px-8">
              <.icon
                name={if(@request.read_only, do: "hero-eye", else: "hero-pencil-square")}
                class={[
                  "mt-0.5 size-5 shrink-0",
                  if(@request.read_only, do: "text-faint", else: "text-warn")
                ]}
              />
              <span :if={@request.read_only}>
                It can <strong class="font-semibold text-ink">read</strong> every vault you can open.
              </span>
              <span :if={not @request.read_only}>
                It can <strong class="font-semibold text-ink">read and change</strong>
                every vault you can open.
              </span>
            </li>
            <li class="flex gap-3 px-6 py-3.5 sm:px-8">
              <.icon name="hero-arrow-uturn-right" class="mt-0.5 size-5 shrink-0 text-faint" />
              <span class="min-w-0">
                You will be sent back to
                <code class="mt-1 block break-all rounded-md border border-line bg-sunken px-2 py-1 font-mono text-xs text-ink">{@request.redirect_uri}</code>
              </span>
            </li>
          </ul>

          <div class="space-y-4 p-6 sm:p-8">
            <.form for={%{}} id="consent-form" action={~p"/oauth/authorize"} class="flex gap-2.5">
              <input :for={{name, value} <- @params} type="hidden" name={name} value={value} />
              <.button id="consent-deny" name="decision" value="deny" size="lg" class="flex-1">
                Cancel
              </.button>
              <.button
                id="consent-approve"
                name="decision"
                value="approve"
                variant="primary"
                size="lg"
                class="flex-1"
              >
                Allow
              </.button>
            </.form>

            <p class="text-center text-xs text-faint">
              You can disconnect it again at any time from your settings.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp destination(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "https", host: host} -> host
      %URI{scheme: "http"} -> "an app on this device"
      %URI{scheme: scheme} -> "the #{scheme} app on this device"
    end
  end

  attr :reason, :atom, required: true
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil

  def invalid(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} column="max-w-md">
      <div class="mx-auto max-w-md pb-16 pt-12 text-center md:pt-24">
        <span class="mx-auto grid size-14 place-items-center rounded-2xl bg-warn/15 text-warn">
          <.icon name="hero-exclamation-triangle" class="size-7" />
        </span>
        <h1 id="oauth-invalid" class="mt-5 font-serif text-xl font-bold tracking-tight text-ink">
          This app could not be connected
        </h1>
        <p :if={@reason == :unknown_client} class="mt-2 text-muted">
          The app is not registered with this server. Start again from the app.
        </p>
        <p :if={@reason == :bad_redirect_uri} class="mt-2 text-muted">
          The app asked to be sent back to an address it did not register.
        </p>
        <p :if={@reason == :malformed_request} class="mt-2 text-muted">
          The app sent a request this server does not understand. Start again from the app.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
