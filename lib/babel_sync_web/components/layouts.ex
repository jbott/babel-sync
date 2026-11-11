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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 flex h-12 items-center gap-3 border-b border-line bg-canvas/85 px-3 backdrop-blur-md md:px-4">
      <.link
        navigate={~p"/"}
        class="group -ml-1 flex items-center gap-2 rounded-lg px-1.5 py-1 text-ink"
      >
        <.logo class="size-[1.375rem] text-accent transition-transform duration-300 group-hover:rotate-[60deg]" />
        <span class="font-serif text-[1.0625rem] font-bold tracking-tight">BabelSync</span>
      </.link>
      <div class="flex-1"></div>
      <.theme_toggle />
      <.icon_button
        :if={@current_scope}
        id="account-link"
        navigate={~p"/account"}
        icon="hero-user-circle"
        label="Account"
      />
    </header>

    <main class={[not @wide && "px-4 sm:px-6 lg:px-8"]}>
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
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
      class="pointer-events-none fixed inset-x-3 top-14 z-50 flex flex-col gap-2 sm:left-auto sm:right-4 sm:w-96"
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
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="theme-toggle flex items-center gap-0.5 rounded-full border border-line bg-sunken p-0.5"
      role="group"
      aria-label="Theme"
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "Match the system theme"},
            {"light", "hero-sun-micro", "Light theme"},
            {"dark", "hero-moon-micro", "Dark theme"}
          ]
        }
        type="button"
        class="grid h-7 w-8 cursor-pointer place-items-center rounded-full"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        title={label}
        aria-label={label}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
