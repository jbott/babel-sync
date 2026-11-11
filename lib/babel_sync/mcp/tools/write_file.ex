defmodule BabelSync.MCP.Tools.WriteFile do
  @moduledoc """
  Creates a file with the given text: a Markdown note, or any other text file such as .base, .canvas, .csv or .json. To replace the whole text of an existing note, pass if_rev with the rev from your last read, so the write is refused if someone changed the note since, or overwrite to replace it regardless. For any smaller change use edit_file or append_file: they send only the changed passage and never undo what others typed.
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

    field :content, :string,
      required: true,
      description: "The complete text of the file."

    field :if_rev, :string,
      description: "Replace an existing note only if it is still at this rev."

    field :overwrite, :boolean, description: "Replace an existing note whatever it holds now."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      options = [if_rev: params[:if_rev], overwrite: params[:overwrite] == true]

      with {:ok, written} <-
             Agent.write_file(scope, params[:vault], params.path, params.content, options) do
        {:ok, Format.written(written)}
      end
    end)
  end
end
