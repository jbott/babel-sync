defmodule BabelSync.MCP.Tools.WriteFile do
  @moduledoc """
  Creates a file with the given text: a Markdown note, or any other text file such as .base, .canvas, .csv or .json. To replace the whole text of an existing note, pass if_rev with the rev from your last read, so the write is refused if someone changed the note since, or overwrite to replace it regardless. For any smaller change use edit_file or append_file: they send only the changed passage and never undo what others typed. To write a binary file such as an image or a PDF, pass its bytes as base64 with encoding "base64"; the file type follows from the extension, and replacing an existing binary file needs overwrite.
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
      description:
        "The complete text of the file, or its bytes in base64 when encoding is base64."

    field :encoding, :string,
      description: "Leave out for text. Pass base64 to write a binary file of up to 8 MiB."

    field :if_rev, :string,
      description: "Replace an existing note only if it is still at this rev."

    field :overwrite, :boolean, description: "Replace an existing note whatever it holds now."
  end

  defp writer(encoding) when encoding in [nil, "", "text", "utf-8", "utf8"],
    do: {:ok, &Agent.write_file/5}

  defp writer("base64"), do: {:ok, &Agent.write_binary/5}
  defp writer(_other), do: {:error, :invalid_encoding}

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      options = [if_rev: params[:if_rev], overwrite: params[:overwrite] == true]

      with {:ok, write} <- writer(params[:encoding]),
           {:ok, written} <- write.(scope, params[:vault], params.path, params.content, options) do
        {:ok, Format.written(written)}
      end
    end)
  end
end
