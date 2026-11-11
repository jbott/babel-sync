defmodule BabelSync.MCP.Tools.EditFile do
  @moduledoc """
  Changes passages of a note, or of any other text file, in place. Each edit replaces one exact passage with new text; the passages are found in the note as it is at that moment, so no read is needed first and people typing elsewhere in the note are not disturbed. All edits apply together or none do. The reply shows the changed lines and the new rev.
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

    embeds_many :edits, required: true, description: "The replacements, applied in order." do
      field :old_text, :string,
        required: true,
        description: "The exact passage to replace. Must occur once unless replace_all is true."

      field :new_text, :string, required: true, description: "The text to put in its place."
      field :replace_all, :boolean, description: "Replace every occurrence of old_text."
    end

    field :if_rev, :string,
      description: "Apply only if the note is still at this rev. Rarely needed."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, written} <-
             Agent.edit_file(scope, params[:vault], params.path, params.edits,
               if_rev: params[:if_rev]
             ) do
        {:ok, Format.written(written)}
      end
    end)
  end
end
