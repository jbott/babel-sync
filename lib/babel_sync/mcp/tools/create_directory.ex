defmodule BabelSync.MCP.Tools.CreateDirectory do
  @moduledoc """
  Creates an empty folder. Folders are also created as needed when a file is written or moved into them.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :path, :string, required: true, description: "The folder to create."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, path} <- Agent.create_directory(scope, params[:vault], params.path) do
        {:ok, "created #{path}/"}
      end
    end)
  end
end
