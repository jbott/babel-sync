defmodule BabelSync.MCP.Tools.ListProperties do
  @moduledoc """
  Lists the properties that notes carry, in the whole vault or one folder: each property's name, how many notes have it, what kind of value it holds and a few examples. Use it to learn what query_notes can filter and sort on.
  """

  use Anubis.Server.Component, type: :tool

  alias BabelSync.Agent
  alias BabelSync.MCP.Format
  alias BabelSync.MCP.Reply

  schema do
    field :vault, :string,
      description: "Vault name or id. May be omitted when only one vault is available."

    field :folder, :string, description: "Only notes inside this folder, for example Places"
  end

  @impl true
  def execute(params, frame) do
    Reply.run(frame, fn scope ->
      with {:ok, survey} <- Agent.list_properties(scope, params[:vault], params[:folder]) do
        {:ok, Format.properties(survey)}
      end
    end)
  end
end
