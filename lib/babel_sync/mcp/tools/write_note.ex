defmodule BabelSync.MCP.Tools.WriteNote do
  @moduledoc """
  Creates a note, or replaces the whole text of an existing one. The change is merged with edits other people are making at the same moment. Prefer edit_note or append_note for small changes.
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

    field :content, :string,
      required: true,
      description: "The complete new Markdown text of the note."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, outcome} <- Agent.write_note(scope, params[:vault], params.path, params.content) do
        {:ok, "#{outcome} #{params.path}"}
      end
    end)
  end
end
