defmodule BabelSync.MCP.Tools.FileHistory do
  @moduledoc """
  Lists the saved versions of a note, newest first. Read one with read_file and its version number; go back to one with restore_file.
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
      with {:ok, history} <- Agent.history(scope, params[:vault], params.path) do
        {:ok, BabelSync.MCP.Format.history(history)}
      end
    end)
  end
end
