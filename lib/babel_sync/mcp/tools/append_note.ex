defmodule BabelSync.MCP.Tools.AppendNote do
  @moduledoc """
  Adds text to the end of a note, creating the note if it does not exist.
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

    field :content, :string, required: true, description: "The Markdown text to add."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, outcome} <- Agent.append_note(scope, params[:vault], params.path, params.content) do
        {:ok, "#{outcome} #{params.path}"}
      end
    end)
  end
end
