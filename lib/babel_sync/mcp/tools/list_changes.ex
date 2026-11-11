defmodule BabelSync.MCP.Tools.ListChanges do
  @moduledoc """
  Lists files written or deleted in a vault since a cursor, oldest first, and returns a new cursor. Without a cursor it returns the most recent changes. Use it to see what people did since you last looked.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :since, :integer, description: "The cursor from an earlier list_changes reply."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, changes} <- Agent.list_changes(scope, params[:vault], params[:since]) do
        {:ok, Format.changes(changes)}
      end
    end)
  end
end
