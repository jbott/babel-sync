defmodule BabelSync.MCP.Tools.MoveFile do
  @moduledoc """
  Renames or moves a note, attachment or folder. A note keeps its history.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :from, :string, required: true, description: "Current path."
    field :to, :string, required: true, description: "New path."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, path} <- Agent.move_file(scope, params[:vault], params.from, params.to) do
        {:ok, "moved to #{path}"}
      end
    end)
  end
end
