defmodule BabelSyncWeb.VaultLive.Sidebar do
  @moduledoc """
  The side of a vault's page: making and uploading files, the tree of
  everything in the vault, and the way to its other vaults, trash and
  settings.
  """

  use BabelSyncWeb, :html

  alias BabelSyncWeb.Paths
  alias BabelSyncWeb.VaultLive.Tree

  attr :entry, :any, required: true
  attr :writable, :boolean, required: true
  attr :admin, :boolean, required: true
  attr :new_form, :any, required: true
  attr :notes_created, :integer, required: true
  attr :vault, :any, required: true
  attr :vaults, :list, required: true
  attr :socket_token, :string, required: true
  attr :tree, :list, required: true
  attr :open_folders, :any, required: true
  attr :current_scope, :any, required: true

  def sidebar(assigns) do
    ~H"""
    <aside
      id="sidebar"
      class={[
        "flex flex-col border-line bg-sunken md:w-72 md:shrink-0 md:border-r md:pt-[env(safe-area-inset-top)]",
        if(@entry, do: "shrink-0", else: "flex-1 md:flex-none")
      ]}
    >
      <header
        id="vault-bar"
        class="sticky top-0 z-10 box-content flex h-9 items-center gap-2 bg-sunken px-4 pb-2 pt-[calc(env(safe-area-inset-top)+0.625rem)] md:static md:pb-0 md:pt-3"
      >
        <Layouts.brand wordmark={false} />
        <form
          id="vault-switcher-form"
          phx-change="switch_vault"
          phx-auto-recover="ignore"
          class={["relative mr-auto min-w-0", @entry && "hidden md:block"]}
        >
          <select
            id="vault-switcher"
            name="vault"
            aria-label="Vault"
            title="Switch vault"
            class="block h-8 w-full min-w-0 cursor-pointer appearance-none truncate rounded-lg bg-transparent [field-sizing:content] pl-2 pr-7 text-sm font-semibold text-ink outline-none transition-colors duration-150 hover:bg-ink/7 focus-visible:ring-2 focus-visible:ring-accent/60"
          >
            <option :for={vault <- @vaults} value={vault.id} selected={vault.id == @vault.id}>
              {vault.name}
            </option>
            <hr />
            <option value="connect">Connect Obsidian…</option>
            <option value="manage">Manage vaults…</option>
          </select>
          <.icon
            name="hero-chevron-up-down-mini"
            class="pointer-events-none absolute right-1.5 top-1/2 size-4 -translate-y-1/2 text-faint"
          />
        </form>
        <nav
          :if={@entry}
          id="note-trail"
          aria-label="Where this file is"
          class="mr-auto flex min-w-0 items-center gap-1 text-sm md:hidden"
        >
          <.link
            id="back-to-files"
            patch={Paths.vault(@vault.id)}
            title="All files"
            class="max-w-[35%] shrink-0 truncate rounded-md px-1 py-0.5 font-medium text-muted transition-colors duration-150 hover:bg-ink/7 hover:text-ink"
          >
            {@vault.name}
          </.link>
          <span aria-hidden="true" class="text-faint">/</span>
          <.file_trail
            id="note-trail-path"
            path={@entry.path}
            files={Paths.vault(@vault.id)}
            class="px-1"
          />
        </nav>
        <Layouts.account_link :if={@current_scope} from={@vault.id} class="-mr-2" />
      </header>

      <div class={["px-2 pt-0.5 md:pt-2.5", @entry && "hidden md:block"]}>
        <div id="vault-controls" class="flex items-center justify-end gap-0.5">
          <.form
            :if={@writable}
            for={@new_form}
            id="new-note"
            phx-submit="create_note"
            class="relative mr-0.5 min-w-0 flex-1"
          >
            <button
              class="absolute left-0 top-0 grid size-9 cursor-pointer place-items-center rounded-lg text-faint transition-colors duration-150 hover:text-ink md:size-8"
              title="Create note"
              aria-label="Create note"
            >
              <.icon name="hero-plus-mini" class="size-[1.125rem]" />
            </button>
            <input
              type="text"
              id={"new-note-path-#{@notes_created}"}
              name={@new_form[:path].name}
              value=""
              placeholder="New note"
              aria-label="New note path"
              autocapitalize="off"
              autocomplete="off"
              spellcheck="false"
              required
              class="block h-9 w-full min-w-0 rounded-lg bg-ink/5 pl-9 pr-3 text-sm text-ink outline-none transition-colors duration-150 hover:bg-ink/8 focus:bg-surface focus:ring-2 focus:ring-accent/60 md:h-8 md:pl-8"
            />
          </.form>
          <label
            :if={@writable}
            class="grid size-9 shrink-0 cursor-pointer place-items-center rounded-lg text-muted transition-colors duration-150 hover:bg-ink/7 hover:text-ink has-focus-visible:ring-2 has-focus-visible:ring-accent/60 md:size-8"
            title="Upload files"
          >
            <.icon name="hero-arrow-up-tray" class="size-[1.125rem]" />
            <input
              id="uploader"
              type="file"
              multiple
              class="sr-only"
              aria-label="Upload files"
              phx-hook="Uploader"
              data-vault-id={@vault.id}
              data-token={@socket_token}
            />
          </label>
          <.icon_button
            navigate={Paths.trash(@vault.id)}
            id="vault-trash"
            icon="hero-trash"
            label="Trash"
          />
          <.icon_button
            :if={@admin}
            navigate={Paths.settings(@vault.id)}
            id="vault-settings"
            icon="hero-cog-6-tooth"
            label="Vault settings"
          />
        </div>
        <progress
          :if={@writable}
          id="upload-progress"
          phx-update="ignore"
          class="upload-meter mt-2"
          value="0"
          max="100"
          hidden
        ></progress>
      </div>

      <div
        :if={@tree != []}
        class={["mt-2 items-center gap-0.5 pl-4 pr-2", if(@entry, do: "hidden md:flex", else: "flex")]}
      >
        <span class="flex-1 text-2xs font-semibold uppercase tracking-[0.1em] text-faint">
          Files
        </span>
        <.icon_button
          id="find-button"
          phx-click="open_finder"
          icon="hero-magnifying-glass-mini"
          label="Find a file or search in notes"
        />
        <.all_folders open={any_open?(@tree, @open_folders)} />
      </div>

      <nav
        id="tree"
        aria-label="Files"
        phx-hook="Folders"
        data-vault-id={@vault.id}
        class={[
          "mt-1 px-2 pb-[calc(env(safe-area-inset-bottom)+1.5rem)] text-base md:flex-1 md:overflow-y-auto md:pb-6 md:text-sm",
          @entry && "hidden md:block"
        ]}
      >
        <div :if={@tree == []} class="px-3 py-10 text-center">
          <.icon name="hero-document-plus" class="size-7 text-faint" />
          <p class="mt-2 text-muted">This vault is empty.</p>
          <.link
            id="tree-connect"
            navigate={Paths.connect(@vault.id)}
            class="mt-1 inline-flex items-center gap-1 rounded-md px-1 py-0.5 font-medium text-accent transition-colors duration-150 hover:text-ink"
          >
            Connect Obsidian <.icon name="hero-arrow-right-mini" class="size-4" />
          </.link>
        </div>
        <.tree
          nodes={@tree}
          selected={@entry && @entry.path}
          open={@open_folders}
          vault_id={@vault.id}
        />
      </nav>
    </aside>
    """
  end

  defp unfolded?(node, selected) do
    is_binary(selected) and String.starts_with?(selected, node.path <> "/")
  end

  defp shown?(node, selected, open) do
    unfolded?(node, selected) or MapSet.member?(open, node.path)
  end

  attr :nodes, :list, required: true
  attr :selected, :string, default: nil
  attr :open, :any, required: true
  attr :vault_id, :string, required: true

  defp tree(assigns) do
    ~H"""
    <ul class="space-y-px">
      <li :for={node <- @nodes}>
        <details
          :if={Tree.folder?(node)}
          data-path={node.path}
          open={unfolded?(node, @selected)}
          phx-mounted={JS.ignore_attributes(["open", "data-seen"])}
        >
          <summary class="flex cursor-pointer items-center gap-1.5 rounded-md px-2 py-2 font-medium text-ink transition-colors duration-100 hover:bg-ink/6 md:py-1">
            <.icon name="hero-chevron-right-mini" class="tree-chevron size-4 shrink-0 text-faint" />
            <span class="truncate">{node.name}</span>
          </summary>
          <div class="ml-[0.9375rem] border-l border-line pl-1.5">
            <.tree
              :if={shown?(node, @selected, @open)}
              nodes={node.children}
              selected={@selected}
              open={@open}
              vault_id={@vault_id}
            />
          </div>
        </details>
        <.link
          :if={not Tree.folder?(node)}
          patch={Paths.entry(node.entry)}
          aria-current={@selected == node.path && "page"}
          class={[
            "flex items-center gap-1.5 rounded-md px-2 py-2 transition-colors duration-100 md:py-1",
            if(@selected == node.path,
              do: "bg-accent/14 font-medium text-ink",
              else: "text-muted hover:bg-ink/6 hover:text-ink"
            )
          ]}
        >
          <.icon
            name={if node.entry.kind == :doc, do: "hero-document-text", else: "hero-paper-clip"}
            class={[
              "size-4 shrink-0",
              if(@selected == node.path, do: "text-accent", else: "text-faint")
            ]}
          />
          <span class="truncate">{node.name}</span>
        </.link>
      </li>
    </ul>
    """
  end

  attr :open, :boolean, required: true

  defp all_folders(assigns) do
    assigns =
      assign(assigns, :label, if(assigns.open, do: "Close all folders", else: "Open all folders"))

    ~H"""
    <button
      id="all-folders"
      type="button"
      title={@label}
      aria-label={@label}
      aria-expanded={to_string(@open)}
      phx-click={JS.dispatch("babelsync:folders", to: "#tree", detail: %{open: not @open})}
      class="grid size-9 shrink-0 cursor-pointer place-items-center rounded-lg text-muted transition-colors duration-150 hover:bg-ink/7 hover:text-ink md:size-8"
    >
      <svg
        viewBox="0 0 20 20"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
        class="size-[1.125rem]"
      >
        <path :if={not @open} d="m6 7.5 4-4 4 4M6 12.5l4 4 4-4" />
        <path :if={@open} d="m6 3.5 4 4 4-4M6 16.5l4-4 4 4" />
      </svg>
    </button>
    """
  end

  defp any_open?(tree, open), do: Enum.any?(Tree.folders(tree), &MapSet.member?(open, &1))
end
