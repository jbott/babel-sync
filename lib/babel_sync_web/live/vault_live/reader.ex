defmodule BabelSyncWeb.VaultLive.Reader do
  @moduledoc """
  The main part of a vault's page: the bar above the open file and the
  file itself, as an editor, a rendered note, a canvas, a base or an
  attachment.
  """

  use BabelSyncWeb, :html

  alias BabelSync.Vaults
  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.Paths

  @image ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  @audio ~w(.mp3 .wav .ogg .m4a .flac)
  @video ~w(.mp4 .webm .mov .mkv)

  attr :entry, :any, required: true
  attr :vault, :any, required: true
  attr :empty, :boolean, required: true

  def welcome(assigns) do
    ~H"""
    <div :if={is_nil(@entry)} id="empty" class="m-auto max-w-sm p-8 text-center">
      <.logo class="mx-auto size-14 text-line-strong" />
      <h2 class="mt-5 font-serif text-xl font-bold tracking-tight text-ink">
        {@vault.name}
      </h2>
      <p class="mt-2 text-muted">
        {if(@empty,
          do: "Nothing here yet. Connect Obsidian to bring your notes in, or create one.",
          else: "Select a note, or connect Obsidian on another device to keep it in sync."
        )}
      </p>
      <.button
        id="connect-obsidian"
        navigate={Paths.connect(@vault.id)}
        variant={if(@empty, do: "primary", else: "secondary")}
        class="mt-5"
      >
        <.icon name="hero-device-phone-mobile-mini" class="size-4" /> Connect Obsidian
      </.button>
    </div>
    """
  end

  attr :entry, :any, required: true
  attr :vault, :any, required: true
  attr :writable, :boolean, required: true
  attr :mode, :atom, required: true
  attr :shown_as, :atom, required: true
  attr :rename_form, :any, required: true

  def toolbar(assigns) do
    ~H"""
    <div
      :if={@entry}
      id="toolbar"
      class="flex h-12 shrink-0 items-center gap-0.5 border-b border-line pl-1.5 pr-1.5 md:gap-1 md:pl-5 md:pr-3"
    >
      <.icon_button
        patch={Paths.vault(@vault.id)}
        id="back-to-files"
        icon="hero-chevron-left"
        label="All files"
        class="md:hidden"
      />
      <span
        id="entry-path"
        class="path-tail min-w-0 flex-1 truncate pr-2 text-sm font-medium text-ink"
      ><bdi>{@entry.path}</bdi></span>
      <div
        :if={@entry.kind == :doc}
        class="mr-1 flex shrink-0 items-center gap-0.5 rounded-lg border border-line bg-sunken p-0.5"
        role="group"
        aria-label="Mode"
      >
        <button
          :if={@writable}
          phx-click="mode"
          phx-value-mode="edit"
          aria-pressed={to_string(@mode == :edit)}
          class={mode_class(@mode == :edit)}
        >Edit</button>
        <button
          phx-click="mode"
          phx-value-mode="read"
          aria-pressed={to_string(@mode == :read)}
          class={mode_class(@mode == :read)}
        >Read</button>
      </div>
      <.icon_button
        :if={@entry.kind == :doc and @mode == :edit and Vaults.Path.markdown?(@entry.path)}
        id="source-button"
        phx-mounted={JS.ignore_attributes(["aria-pressed"])}
        aria-pressed="false"
        icon="hero-code-bracket"
        label="Show the Markdown as written"
      />
      <.icon_button
        :if={@entry.kind == :doc and Vaults.Path.markdown?(@entry.path)}
        id="details-button"
        phx-click="details"
        icon="hero-list-bullet"
        label="Outline and links"
      />
      <.icon_button
        :if={@entry.kind == :blob and @shown_as == :text}
        id="download-button"
        href={Paths.raw(@entry)}
        download={Path.basename(@entry.path)}
        icon="hero-arrow-down-tray"
        label="Download"
      />
      <.icon_button
        :if={@entry.kind in [:doc, :blob]}
        id="history-button"
        phx-click="history"
        icon="hero-clock"
        label="History"
      />
      <.icon_button
        :if={@writable}
        id="rename-button"
        phx-click="start_rename"
        icon="hero-pencil-square"
        label="Rename or move"
      />
      <.icon_button
        :if={@writable}
        id="delete-button"
        phx-click="delete"
        data-confirm={"Delete #{@entry.path}?"}
        icon="hero-trash"
        label="Delete"
        tone="danger"
      />
    </div>

    <.form
      :if={@rename_form}
      for={@rename_form}
      id="rename-form"
      phx-submit="rename"
      phx-keydown={JS.push("cancel_rename") |> JS.focus(to: "#rename-button")}
      phx-key="escape"
      class="flex animate-rise flex-wrap items-center justify-end gap-2 border-b border-line bg-sunken px-3 py-2.5 md:px-5"
    >
      <input
        type="text"
        name={@rename_form[:path].name}
        value={@rename_form[:path].value}
        id="rename-path"
        phx-mounted={JS.focus()}
        aria-label="New path"
        autocapitalize="off"
        autocomplete="off"
        spellcheck="false"
        class={[field_class(), "h-9 w-full basis-full text-sm sm:w-auto sm:flex-1 sm:basis-0"]}
        required
      />
      <.button type="button" phx-click="cancel_rename" variant="ghost" size="sm">
        Cancel
      </.button>
      <.button variant="primary" size="sm">Move</.button>
    </.form>
    """
  end

  attr :entry, :any, required: true
  attr :mode, :atom, required: true
  attr :writable, :boolean, required: true
  attr :socket_token, :string, required: true
  attr :user, :any, required: true

  def editor(assigns) do
    ~H"""
    <div :if={@entry && @entry.kind == :doc && @mode == :edit} class="min-h-0 flex-1">
      <div
        id={"editor-#{@entry.id}"}
        phx-hook="Editor"
        phx-update="ignore"
        data-entry-id={@entry.id}
        data-token={@socket_token}
        data-writable={to_string(@writable)}
        data-user-name={display_name(@user)}
        data-user-color={cursor_color(@user.id)}
        class="relative h-full"
      >
      </div>
    </div>
    """
  end

  attr :entry, :any, required: true
  attr :mode, :atom, required: true
  attr :shown_as, :atom, required: true
  attr :preview, :any, required: true

  def note(assigns) do
    ~H"""
    <article
      :if={
        @entry &&
          ((@entry.kind == :doc && @mode == :read && @shown_as == :markdown) ||
             (@entry.kind == :blob && @shown_as == :text))
      }
      id="preview"
      class="flex-1 overflow-y-auto px-5 pb-24 pt-7 md:px-10 md:pt-12"
    >
      <div id="preview-body" phx-hook="Markdown" class="markdown mx-auto max-w-[42rem]">
        {raw(@preview)}
      </div>
    </article>

    <article
      :if={@entry && @entry.kind == :doc && @mode == :read && @shown_as == :canvas}
      id="canvas"
      phx-hook="Canvas"
      class="relative min-h-0 flex-1 touch-none overflow-hidden bg-sunken/60"
    >
      <div id="canvas-body" phx-hook="Markdown" class="markdown canvas">
        {raw(@preview)}
      </div>
      <div class="absolute bottom-4 right-4 flex gap-1 rounded-lg border border-line bg-surface p-1 shadow-raise">
        <button
          :for={
            {action, icon, label} <- [
              {"out", "hero-minus-mini", "Zoom out"},
              {"in", "hero-plus-mini", "Zoom in"},
              {"fit", "hero-arrows-pointing-in-mini", "Fit to screen"}
            ]
          }
          id={"canvas-#{action}"}
          type="button"
          data-canvas={action}
          aria-label={label}
          title={label}
          class="grid size-8 place-items-center rounded-md text-muted transition hover:bg-sunken hover:text-ink"
        >
          <.icon name={icon} class="size-4" />
        </button>
      </div>
    </article>
    """
  end

  attr :entry, :any, required: true
  attr :mode, :atom, required: true
  attr :shown_as, :atom, required: true
  attr :base, :any, required: true

  def base(assigns) do
    ~H"""
    <article
      :if={@entry && @entry.kind == :doc && @mode == :read && @shown_as == :base && is_nil(@base)}
      id="base-loading"
      class="flex flex-1 items-start justify-center px-6 py-16 text-sm text-muted"
    >
      <span class="inline-flex items-center gap-2">
        <.icon name="hero-arrow-path" class="size-4 animate-spin" /> Running the base…
      </span>
    </article>

    <article
      :if={@entry && @entry.kind == :doc && @mode == :read && @shown_as == :base && @base}
      id="base"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div
        :if={length(@base.views) > 1}
        id="base-views"
        role="group"
        aria-label="View"
        class="flex shrink-0 gap-1 overflow-x-auto border-b border-line px-3 py-2 md:px-5"
      >
        <button
          :for={view <- @base.views}
          type="button"
          aria-pressed={to_string(view == @base.view)}
          phx-click="base_view"
          phx-value-view={view}
          class={[mode_class(view == @base.view), "whitespace-nowrap"]}
        >
          {view}
        </button>
      </div>
      <div
        :if={@base.places}
        id="base-map"
        phx-hook="BaseMap"
        data-places={@base.places}
        data-view={@base.view}
        class="relative min-h-0 flex-1"
      >
        <div id="base-map-canvas" phx-update="ignore" data-map-canvas class="h-full w-full"></div>
      </div>
      <div :if={@base.table} class="min-h-0 flex-1 overflow-auto">
        <p :if={@base.table.rows == []} class="px-6 py-12 text-center text-sm text-muted">
          No notes match this view.
        </p>
        <table :if={@base.table.rows != []} id="base-table" class="w-full text-sm">
          <thead class="sticky top-0 bg-canvas">
            <tr class="border-b border-line text-left text-xs font-medium text-faint">
              <th class="px-4 py-2 font-medium md:px-5">Note</th>
              <th :for={column <- @base.table.columns} class="px-3 py-2 font-medium">
                {column}
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @base.table.rows do %>
              <tr :if={row.heading} class="border-b border-line bg-sunken/70">
                <th
                  colspan={length(@base.table.columns) + 1}
                  class="px-4 pb-1.5 pt-4 text-left text-xs font-semibold uppercase tracking-wide text-muted md:px-5"
                >
                  {row.heading}
                </th>
              </tr>
              <tr class="border-b border-line/60 transition hover:bg-sunken/60">
                <td class="whitespace-nowrap px-4 py-2 md:px-5">
                  <.link
                    :if={row.entry}
                    patch={Paths.entry(row.entry)}
                    class="font-medium text-ink underline-offset-2 hover:underline"
                  >
                    {Path.rootname(Path.basename(row.path))}
                  </.link>
                  <span :if={is_nil(row.entry)}>{row.path}</span>
                </td>
                <td :for={cell <- row.cells} class="max-w-xs truncate px-3 py-2 text-muted">
                  <%= for part <- cell do %>
                    <%= case part do %>
                      <% {:note, href, label} -> %>
                        <.link
                          patch={href}
                          class="text-accent underline-offset-2 hover:underline"
                        >
                          {label}
                        </.link>
                      <% {:web, href, label} -> %>
                        <a
                          href={href}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="text-accent underline-offset-2 hover:underline"
                        >
                          {label}
                        </a>
                      <% {:text, text} -> %>
                        {text}
                    <% end %>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
        <p
          :if={@base.table.total > length(@base.table.rows)}
          class="px-4 py-3 text-xs text-faint md:px-5"
        >
          Showing {length(@base.table.rows)} of {@base.table.total} notes.
        </p>
      </div>
    </article>
    """
  end

  attr :entry, :any, required: true
  attr :shown_as, :atom, required: true

  def attachment(assigns) do
    ~H"""
    <div
      :if={@entry && @entry.kind == :blob && @shown_as != :text}
      id="attachment"
      class="flex flex-1 flex-col items-center gap-5 overflow-auto bg-sunken/60 p-4 md:p-10"
    >
      <img
        :if={media(@entry) == :image}
        src={Paths.raw(@entry)}
        alt={@entry.path}
        class="max-w-full rounded-lg border border-line bg-surface shadow-float"
      />
      <audio
        :if={media(@entry) == :audio}
        src={Paths.raw(@entry)}
        controls
        class="w-full max-w-xl"
      ></audio>
      <video
        :if={media(@entry) == :video}
        src={Paths.raw(@entry)}
        controls
        class="max-w-full rounded-lg border border-line shadow-float"
      ></video>
      <iframe
        :if={media(@entry) == :pdf}
        id="attachment-pdf"
        src={Paths.raw(@entry)}
        title={Path.basename(@entry.path)}
        class="min-h-[70vh] w-full max-w-4xl flex-1 rounded-lg border border-line bg-surface shadow-float"
      ></iframe>
      <div
        :if={media(@entry) == :other}
        class="grid size-20 place-items-center rounded-2xl border border-line bg-surface text-faint shadow-raise"
      >
        <.icon name="hero-paper-clip" class="size-8" />
      </div>
      <p class="flex items-center gap-3 text-sm text-muted">
        <span class="tabular-nums">{size(@entry.size)}</span>
        <.button href={Paths.raw(@entry)} download={Path.basename(@entry.path)} size="sm">
          <.icon name="hero-arrow-down-tray-mini" class="size-4" /> Download
        </.button>
      </p>
    </div>

    <div :if={@entry && @entry.kind == :folder} class="m-auto p-8 text-center text-muted">
      <.icon name="hero-folder-open" class="size-10 text-line-strong" />
      <p class="mt-2">Folder</p>
    </div>
    """
  end

  @doc false
  def mode_class(active) do
    [
      "h-7 cursor-pointer rounded-md px-3 text-sm font-medium transition duration-150",
      if(active,
        do: "bg-surface text-ink shadow-raise",
        else: "text-muted hover:text-ink"
      )
    ]
  end

  @doc false
  def media(%Entry{path: path}) do
    extension = String.downcase(Path.extname(path))

    cond do
      extension in @image -> :image
      extension in @audio -> :audio
      extension in @video -> :video
      extension == ".pdf" -> :pdf
      true -> :other
    end
  end

  @doc false
  def size(bytes) when bytes < 1024, do: "#{bytes} B"
  def size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  def size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp cursor_color(user_id), do: "hsl(#{:erlang.phash2(user_id, 360)} 70% 45%)"

  defp display_name(user), do: user.name || user.email || "Someone"
end
