defmodule BabelSync.MCP.Tools.ReadNote do
  @moduledoc """
  Returns the current Markdown text of a note, including edits people are making right now.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
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
      Agent.read_note(scope, params[:vault], params.path)
    end)
  end
end
