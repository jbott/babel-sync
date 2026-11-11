defmodule BabelSync.MCP.Tools.SearchNotes do
  @moduledoc """
  Finds notes whose text or path contains a phrase, ignoring case, and returns the matching passages. Edits from the last half minute may not be searchable yet.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :query, :string, required: true, description: "The phrase to look for."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      Agent.search_notes(scope, params[:vault], params.query)
    end)
  end
end
