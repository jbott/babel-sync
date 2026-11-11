defmodule BabelSync.MCP.Tools.EditNote do
  @moduledoc """
  Replaces one exact passage of a note with new text. old_text must occur exactly once in the note.
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

    field :old_text, :string,
      required: true,
      description: "The exact text to replace. Must be unique in the note."

    field :new_text, :string, required: true, description: "The text to put in its place."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, outcome} <-
             Agent.edit_note(scope, params[:vault], params.path, params.old_text, params.new_text) do
        {:ok, "#{outcome} #{params.path}"}
      end
    end)
  end
end
