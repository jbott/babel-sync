defmodule BabelSync.MCP.Tools.FileOutline do
  @moduledoc """
  Shows the shape of a note without its text: line count, rev, frontmatter properties and every heading with its line number. Use it to pick the lines to read from a long note.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :path, :string,
      required: true,
      description: "Path inside the vault, for example Projects/plan.md"
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, outline} <- Agent.outline(scope, params[:vault], params.path) do
        {:ok, Format.outline(outline)}
      end
    end)
  end
end
