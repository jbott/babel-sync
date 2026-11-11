defmodule BabelSync.MCP.Tools.ListFiles do
  @moduledoc """
  Lists the notes, attachments and folders in a vault, optionally only those under one folder.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :folder, :string, description: "Only list files under this folder."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      Agent.list_files(scope, params[:vault], params[:folder])
    end)
  end
end
