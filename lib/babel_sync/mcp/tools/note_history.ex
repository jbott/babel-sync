defmodule BabelSync.MCP.Tools.NoteHistory do
  @moduledoc """
  Lists the saved versions of a note, newest first. Pass a version number to get the text of that version.
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

    field :version, :integer, description: "Return the text of this version instead of the list."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      case params[:version] do
        nil -> Agent.history(scope, params[:vault], params.path)
        version -> Agent.read_version(scope, params[:vault], params.path, version)
      end
    end)
  end
end
