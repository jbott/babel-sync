defmodule BabelSync.MCP.Tools.DownloadFile do
  @moduledoc """
  Gives a link to download any file in the vault with an HTTP GET: an attachment such as a PDF, or a note as its current text. Use it to save a file to a disk you can reach from a shell, or to fetch a file too large to read through read_file. The link lasts an hour; the reply shows the curl command.
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
      description: "Path inside the vault, for example Papers/attention.pdf"
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, link} <- Agent.download_link(scope, params[:vault], params.path) do
        {:ok, Format.download_link(link)}
      end
    end)
  end
end
