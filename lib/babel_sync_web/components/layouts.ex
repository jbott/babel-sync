defmodule BabelSyncWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BabelSyncWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :wide, :boolean, default: false, doc: "let the content fill the window"
  attr :masthead, :boolean, default: true, doc: "show the brand and account links above the page"
  attr :column, :string, default: "max-w-2xl", doc: "the width the masthead lines up with"
  attr :on_account, :boolean, default: false, doc: "mark the account link as the page shown"

  attr :trail, :list,
    default: [],
    doc: "the pages above this one and then this one, each as {label, path} with a nil path last"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class={[
      not @wide && "px-4 pb-[env(safe-area-inset-bottom)] sm:px-6 lg:px-8",
      (not @wide and not @masthead) && "pt-[env(safe-area-inset-top)]"
    ]}>
      <div
        :if={not @wide and @masthead}
        id="masthead"
        class="sticky top-0 z-10 -mx-4 bg-page px-4 pb-2 pt-[calc(env(safe-area-inset-top)+0.625rem)] sm:-mx-6 sm:px-6 md:pt-[calc(env(safe-area-inset-top)+1.75rem)] lg:-mx-8 lg:px-8"
      >
        <div class={["mx-auto flex h-9 items-center gap-2", @column]}>
          <.brand wordmark={@trail == []} />
          <.crumbs trail={@trail} />
          <.account_link :if={@current_scope} active={@on_account} class="-mr-2 ml-auto" />
        </div>
      </div>
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the mark and wordmark as the link back to the list of vaults.
  """
  attr :class, :any, default: nil
  attr :wordmark, :boolean, default: true

  def brand(assigns) do
    ~H"""
    <.link
      navigate={~p"/"}
      title="Home"
      class={[
        "group -ml-1 inline-flex items-center gap-2 rounded-lg px-1 py-1 text-muted transition-colors duration-150 hover:text-ink",
        @class
      ]}
    >
      <.logo class="size-5 text-accent" />
      <span :if={@wordmark} class="font-serif text-base font-semibold tracking-tight">
        Babel Sync
      </span>
    </.link>
    """
  end

  @doc """
  Renders the way down to a page: each page above it as a link, then the
  page itself.
  """
  attr :trail, :list, required: true

  def crumbs(assigns) do
    ~H"""
    <nav
      :if={@trail != []}
      id="crumbs"
      aria-label="Where this page is"
      class="flex min-w-0 items-center gap-1 text-sm"
    >
      <%= for {{label, path}, at} <- Enum.with_index(@trail) do %>
        <span aria-hidden="true" class="text-faint">/</span>
        <.link
          :if={path}
          id={"crumb-#{at}"}
          navigate={path}
          class="min-w-8 truncate rounded-md px-1 py-0.5 font-medium text-muted transition-colors duration-150 hover:bg-ink/7 hover:text-ink"
        >
          {label}
        </.link>
        <span :if={!path} aria-current="page" class="shrink-0 px-1 font-semibold text-ink">
          {label}
        </span>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders the link to the account page, where the profile, passkeys,
  connected apps and the theme live.
  """
  attr :class, :any, default: nil
  attr :from, :string, default: nil, doc: "the vault to go back to from the account page"
  attr :active, :boolean, default: false

  def account_link(assigns) do
    ~H"""
    <.icon_button
      id="account-link"
      navigate={if @from, do: ~p"/account?#{[from: @from]}", else: ~p"/account"}
      icon={if @active, do: "hero-user-circle-solid", else: "hero-user-circle"}
      label="Your settings"
      aria-current={@active && "page"}
      class={[@active && "bg-accent/14 text-accent!", @class]}
    />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed inset-x-3 top-[max(0.75rem,env(safe-area-inset-top))] z-50 flex flex-col gap-2 sm:left-auto sm:right-4 sm:w-96"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders the switch between following the system theme, light and dark.

  The script in the head of root.html.heex applies the choice before the
  page is painted and listens for the event these buttons dispatch.
  """
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class={[
        "theme-toggle grid grid-cols-3 gap-1 rounded-xl border border-line bg-sunken p-1",
        @class
      ]}
      role="group"
      aria-label="Theme"
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-mini", "System"},
            {"light", "hero-sun-mini", "Light"},
            {"dark", "hero-moon-mini", "Dark"}
          ]
        }
        type="button"
        class="flex h-9 cursor-pointer items-center justify-center gap-2 rounded-lg px-3 text-sm font-medium"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
      >
        <.icon name={icon} class="size-4" /> {label}
      </button>
    </div>
    """
  end
end
