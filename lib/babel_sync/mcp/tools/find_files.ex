defmodule BabelSync.MCP.Tools.FindFiles do
  @moduledoc """
  Finds files by path pattern, like a shell glob. `*` matches within a folder, `**` across folders, `{a,b}` either. A pattern without a slash matches the file name in any folder; letter case is ignored.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :pattern, :string,
      required: true,
      description: "For example *.png, Projects/**/*.md or **/{todo,tasks}.md"
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, paths} <- Agent.find_files(scope, params[:vault], params.pattern) do
        {:ok, Format.paths(paths)}
      end
    end)
  end
end
