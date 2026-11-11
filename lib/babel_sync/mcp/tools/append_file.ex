defmodule BabelSync.MCP.Tools.AppendFile do
  @moduledoc """
  Adds text to the end of a note, or to the end of the section under one heading. Creates the note when it does not exist. Safe while others are writing: only the new text is sent.
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

    field :content, :string, required: true, description: "The text to add."

    field :heading, :string,
      description:
        "Add at the end of the section under this heading, after any sub-sections, for example Tasks."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, written} <-
             Agent.append_file(scope, params[:vault], params.path, params.content,
               heading: params[:heading]
             ) do
        {:ok, Format.written(written)}
      end
    end)
  end
end
