defmodule BabelSync.MCP.Tools.UploadFile do
  @moduledoc """
  Gives a link to upload a file's bytes with an HTTP PUT, for any file: a PDF, an image, a large attachment, or a note or other text file. Use it when the file is on a disk you can reach from a shell, or is too large to pass to write_file. The link works once, for an hour, for exactly the size you declare; the reply shows the curl command. Replacing an existing file needs overwrite.
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
      description: "Where the file goes in the vault, for example Papers/attention.pdf"

    field :size, :integer, required: true, description: "The file's size in bytes."

    field :overwrite, :boolean, description: "Replace a file already at that path."
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      options = [overwrite: params[:overwrite] == true]

      with {:ok, link} <-
             Agent.upload_link(scope, params[:vault], params.path, params.size, options) do
        {:ok, Format.upload_link(link)}
      end
    end)
  end
end
