defmodule BabelSync.MCP.Server do
  @moduledoc """
  The Model Context Protocol server: vault operations as tools for agents,
  served over Streamable HTTP at `/mcp`.
  """

  use Anubis.Server,
    name: "BabelSync",
    version: "0.1.0",
    capabilities: [:tools]

  alias BabelSync.MCP.Tools

  component(Tools.ListVaults)
  component(Tools.ListFiles)
  component(Tools.ReadNote)
  component(Tools.WriteNote)
  component(Tools.EditNote)
  component(Tools.AppendNote)
  component(Tools.SearchNotes)
  component(Tools.MoveFile)
  component(Tools.DeleteFile)
  component(Tools.NoteHistory)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
