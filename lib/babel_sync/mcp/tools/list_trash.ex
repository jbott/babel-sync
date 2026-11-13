defmodule BabelSync.MCP.Tools.ListTrash do
  @moduledoc """
  Lists deleted files that can still be restored, most recently deleted first.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  @listed 500

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, trash} <- Agent.list_trash(scope, params[:vault]) do
        {:ok,
         Format.capped(
           trash,
           @listed,
           &Format.trash/1,
           "These are the most recently deleted; restore_file takes any path."
         )}
      end
    end)
  end
end
