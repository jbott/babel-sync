defmodule BabelSync.MCP.Tools.ListVaults do
  @moduledoc """
  Lists the note vaults this credential can reach, with the role held in each.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Reply

  schema do
  end

  @impl true
  def execute(_params, frame) do
    Reply.run(frame, fn scope ->
      {:ok, Agent.list_vaults(scope)}
    end)
  end
end
