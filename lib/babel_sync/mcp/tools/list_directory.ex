defmodule BabelSync.MCP.Tools.ListDirectory do
  @moduledoc """
  Lists one folder of a vault: its notes, attachments and sub-folders, with sizes and modification times. Start here to see what a vault holds.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  @listed 500

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :path, :string, description: "Folder to list. Omit for the top of the vault."

    field :depth, :integer,
      description: "How many levels of sub-folders to descend into. Defaults to 1."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, listed} <-
             Agent.list_directory(scope, params[:vault], params[:path], params[:depth] || 1) do
        {:ok,
         Format.capped(
           listed,
           @listed,
           &Format.listing/1,
           "List a sub-folder, lower the depth, or use find_files."
         )}
      end
    end)
  end
end
