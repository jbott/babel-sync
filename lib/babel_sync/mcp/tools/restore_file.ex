defmodule BabelSync.MCP.Tools.RestoreFile do
  @moduledoc """
  Brings a deleted file back from the trash, or, with a version, puts a note back to how it was at that saved version.
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

    field :version, :integer,
      description: "A version number from file_history. Omit to restore a deleted file."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      case params[:version] do
        nil ->
          with {:ok, path} <- Agent.restore_file(scope, params[:vault], params.path) do
            {:ok, "restored #{path}"}
          end

        version ->
          with {:ok, written} <-
                 Agent.restore_version(scope, params[:vault], params.path, version) do
            {:ok, Format.written(written)}
          end
      end
    end)
  end
end
