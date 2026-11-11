defmodule BabelSync.MCP.Tools.SearchFiles do
  @moduledoc """
  Searches the text of every note, including what people are typing right now, and returns matching lines with their line numbers. Matches one line at a time. Follow up with read_file and an offset to see more of a note.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :query, :string,
      required: true,
      description: "Text to look for, or a regular expression when regex is true."

    field :regex, :boolean, description: "Treat query as a regular expression."
    field :case_sensitive, :boolean, description: "Match letter case exactly. Off by default."

    field :glob, :string,
      description: "Only search notes whose path matches this pattern, for example Journal/**"

    field :context, :integer,
      description: "Lines to show before and after each matching line. Defaults to 0."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      options = [
        regex: params[:regex],
        case_sensitive: params[:case_sensitive],
        glob: params[:glob],
        context: min(params[:context] || 0, 10)
      ]

      with {:ok, found} <- Agent.search_files(scope, params[:vault], params.query, options) do
        {:ok, Format.matches(found)}
      end
    end)
  end
end
