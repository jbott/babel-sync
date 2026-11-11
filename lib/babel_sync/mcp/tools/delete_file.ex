defmodule BabelSync.MCP.Tools.DeleteFile do
  @moduledoc """
  Moves a note, attachment or folder to the vault's trash. A folder goes with everything in it. restore_file brings a file back.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :path, :string, required: true, description: "Path of the file or folder to delete."
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
