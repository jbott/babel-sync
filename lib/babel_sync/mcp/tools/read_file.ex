defmodule BabelSync.MCP.Tools.ReadFile do
  @moduledoc """
  Reads a note or any other text file as it is right now, including edits people are making, or shows an image attachment. The first line of the reply gives the line range, the total and the note's rev; the text follows. For a long note, call file_outline first and read only the lines you need. You do not need to read a note before edit_file or append_file.
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

    field :offset, :integer, description: "First line to return, counting from 1."
    field :limit, :integer, description: "Number of lines to return. Defaults to 2000."

    field :line_numbers, :boolean,
      description: "Prefix every line with its number. The numbers are not part of the note."

    field :version, :integer,
      description: "Read this saved version, from file_history, instead of the current text."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      options = [offset: params[:offset], limit: params[:limit], version: params[:version]]

      with {:ok, read} <- Agent.read_file(scope, params[:vault], params.path, options) do
        {:ok, Format.read(read, params[:line_numbers] == true)}
      end
    end)
  end
end
