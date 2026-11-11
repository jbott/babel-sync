defmodule BabelSync.MCP.Tools.DeleteFile do
  @moduledoc """
  Deletes a note, attachment or folder (with everything in it). Deleted notes stay recoverable for the retention period.
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
      with {:ok, paths} <- Agent.delete_file(scope, params[:vault], params.path) do
        {:ok, "deleted " <> Enum.join(paths, ", ")}
      end
    end)
  end
end
