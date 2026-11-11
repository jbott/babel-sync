defmodule BabelSyncWeb.CoreComponents do
  @moduledoc """
  The building blocks every page is drawn from: buttons, fields, flash
  notices, page headers, panels and row lists. They are styled with the
  design tokens defined in `assets/css/app.css`.
  """
  use Phoenix.Component
  use Gettext, backend: BabelSyncWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="pointer-events-auto animate-rise cursor-pointer"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-xl border bg-surface py-3 pl-3.5 pr-2.5 text-sm shadow-float",
        @kind == :info && "border-line-strong",
        @kind == :error && "border-danger/50"
      ]}>
        <span class={[
          "mt-px grid size-6 shrink-0 place-items-center rounded-full",
          @kind == :info && "bg-accent/15 text-accent",
          @kind == :error && "bg-danger/15 text-danger"
        ]}>
          <.icon :if={@kind == :info} name="hero-check-mini" class="size-4" />
          <.icon :if={@kind == :error} name="hero-exclamation-triangle-mini" class="size-4" />
        </span>
        <div class="min-w-0 flex-1 py-0.5 text-ink">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="break-words">{msg}</p>
        </div>
        <button
          type="button"
          class="grid size-7 shrink-0 place-items-center rounded-md text-faint transition hover:bg-ink/8 hover:text-ink"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button, or a link that looks like one when given `href`,
  `navigate` or `patch`.

  ## Examples

      <.button>Save</.button>
      <.button variant="primary" size="lg">Sign in</.button>
      <.button variant="danger" phx-click="delete">Delete</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil

  attr :variant, :string,
    values: ~w(primary secondary ghost danger danger-ghost),
    default: "secondary"

  attr :size, :string, values: ~w(sm md lg), default: "md"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [button_class(assigns.variant, assigns.size), assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_class(variant, size) do
    [
      "inline-flex shrink-0 cursor-pointer select-none items-center justify-center gap-2 whitespace-nowrap rounded-lg font-medium",
      "transition-colors duration-150",
      "disabled:pointer-events-none disabled:opacity-50 phx-submit-loading:opacity-60 phx-click-loading:opacity-60",
      button_size(size),
      button_variant(variant)
    ]
  end

  defp button_size("sm"), do: "h-8 px-3 text-sm"
  defp button_size("md"), do: "h-10 px-4 text-sm"
  defp button_size("lg"), do: "h-11 px-5 text-base"

  defp button_variant("primary"),
    do: "bg-accent text-accent-ink shadow-raise hover:brightness-110"

  defp button_variant("secondary"),
    do:
      "border border-line-strong bg-surface text-ink shadow-raise hover:border-faint hover:bg-canvas"

  defp button_variant("ghost"), do: "text-muted hover:bg-ink/7 hover:text-ink"

  defp button_variant("danger"),
    do:
      "border border-danger/45 text-danger hover:border-danger hover:bg-danger hover:text-danger-ink"

  defp button_variant("danger-ghost"), do: "text-danger hover:bg-danger/12"

  @doc """
  Renders a square button that shows only an icon. The label is required and
  becomes both the tooltip and the accessible name.

  ## Examples

      <.icon_button icon="hero-clock" label="History" phx-click="history" />
      <.icon_button icon="hero-trash" label="Trash" navigate={~p"/trash"} />
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :string, values: ~w(neutral danger), default: "neutral"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method disabled type)

  def icon_button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "grid size-9 shrink-0 cursor-pointer place-items-center rounded-lg transition-colors duration-150 md:size-8",
        "disabled:pointer-events-none disabled:opacity-50",
        assigns.tone == "neutral" && "text-muted hover:bg-ink/7 hover:text-ink",
        assigns.tone == "danger" && "text-muted hover:bg-danger/12 hover:text-danger",
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} title={@label} aria-label={@label} {@rest}>
        <.icon name={@icon} class="size-[1.125rem]" />
      </.link>
      """
    else
      ~H"""
      <button class={@classes} title={@label} aria-label={@label} {@rest}>
        <.icon name={@icon} class="size-[1.125rem]" />
      </button>
      """
    end
  end

  @doc """
  The classes of a text field, for the few inputs that are written by hand
  because they sit inside a composite control.
  """
  def field_class do
    [
      "block h-10 w-full min-w-0 rounded-lg border border-line-strong bg-surface px-3 text-base text-ink shadow-raise",
      "outline-none transition duration-150 hover:border-faint focus:border-accent focus:ring-3 focus:ring-accent/20",
      "disabled:opacity-60"
    ]
  end

  defp field_error_class,
    do: "border-danger hover:border-danger focus:border-danger focus:ring-danger/20"

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument, which is used to
  retrieve the input name, id, and values. Otherwise all attributes may be
  passed explicitly. `type="select"` renders a `<select>` and needs `options`.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "extra classes for the input"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="min-w-0">
      <label for={@id} class="flex items-center gap-2.5 text-sm text-ink">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={["size-4 rounded accent-accent", @class]}
          {@rest}
        />{@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="min-w-0">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-muted">{@label}</span>
        <span class="relative block">
          <select
            id={@id}
            name={@name}
            class={[
              field_class(),
              "appearance-none pr-9",
              @errors != [] && (@error_class || field_error_class()),
              @class
            ]}
            multiple={@multiple}
            {@rest}
          >
            <option :if={@prompt} value="">{@prompt}</option>
            {Phoenix.HTML.Form.options_for_select(@options, @value)}
          </select>
          <.icon
            name="hero-chevron-up-down-mini"
            class="pointer-events-none absolute right-2.5 top-1/2 size-4 -translate-y-1/2 text-faint"
          />
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="min-w-0">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-muted">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            field_class(),
            "h-auto min-h-24 py-2",
            @errors != [] && (@error_class || field_error_class()),
            @class
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="min-w-0">
      <label for={@id} class="block">
        <span :if={@label} class="mb-1.5 block text-sm font-medium text-muted">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            field_class(),
            @errors != [] && (@error_class || field_error_class()),
            @class
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-sm text-danger">
      <.icon name="hero-exclamation-circle-mini" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a page header: an optional trail back to the parent page, the
  title, an optional subtitle and optional actions.
  """
  slot :inner_block, required: true
  slot :trail
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="space-y-3">
      <div :if={@trail != []} class="text-sm">{render_slot(@trail)}</div>
      <div class="flex items-end justify-between gap-6">
        <div class="min-w-0">
          <h1 class="truncate font-serif text-2xl font-bold tracking-tight text-ink">
            {render_slot(@inner_block)}
          </h1>
          <p :if={@subtitle != []} class="mt-1 text-base text-muted">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
      </div>
    </header>
    """
  end

  @doc """
  Renders the link that leads from a page back to its parent.
  """
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def back_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group -ml-1 inline-flex max-w-full items-center gap-1 rounded-md px-1 py-0.5 text-muted transition hover:text-ink"
    >
      <.icon
        name="hero-arrow-left-mini"
        class="size-4 shrink-0"
      />
      <span class="truncate">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc """
  Renders a titled section of a settings-like page.
  """
  attr :title, :string, required: true
  attr :tone, :string, values: ~w(neutral danger), default: "neutral"
  attr :rest, :global
  slot :description
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class="space-y-3" {@rest}>
      <div class="flex items-center gap-3">
        <h2 class={[
          "text-xs font-semibold uppercase tracking-[0.1em]",
          if(@tone == "danger", do: "text-danger", else: "text-muted")
        ]}>
          {@title}
        </h2>
        <span class="h-px flex-1 bg-line"></span>
      </div>
      <p :if={@description != []} class="max-w-prose text-sm text-muted">
        {render_slot(@description)}
      </p>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Renders the bordered list that rows of vaults, people, passkeys and
  deleted files sit in.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def rows(assigns) do
    ~H"""
    <ul
      class={[
        "divide-y divide-line overflow-hidden rounded-xl border border-line bg-surface shadow-raise",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </ul>
    """
  end

  @doc """
  Renders a small label such as "current" or "read only".
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full border border-line-strong px-2 py-px align-middle text-2xs font-medium uppercase tracking-wider text-muted",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders the BabelSync mark: one hexagonal gallery holding lines of text.
  """
  attr :class, :any, default: "size-5"

  def logo(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      <path d="M12 2.2 20.5 7.1v9.8L12 21.8 3.5 16.9V7.1Z" />
      <path d="M8.2 9.3h7.6M8.2 12.2h7.6M8.2 15.1h4.4" />
    </svg>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com) by its `hero-` class name.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 220,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 -translate-y-1",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 160,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(BabelSyncWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(BabelSyncWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
