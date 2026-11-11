defmodule BabelSync.MCP.Reply do
  @moduledoc false

  alias Anubis.Server.Response
  alias BabelSync.Accounts.Scope

  @messages %{
    forbidden: "This credential may not do that in this vault.",
    vault_not_found: "No such vault. Call list_vaults to see the vaults available.",
    ambiguous_vault: "More than one vault is available. Pass the vault name or id.",
    not_found: "No file exists at that path. Call list_files to see what exists.",
    not_a_note: "That path is an attachment or folder, not a text note.",
    exists: "A file already exists at the destination path.",
    invalid_path: "That is not a valid vault path.",
    no_match: "old_text was not found in the note. Read the note and try again.",
    ambiguous_match:
      "old_text is empty or occurs more than once. Include more surrounding text so it is unique."
  }

  def run(frame, fun) do
    case frame.assigns[:current_scope] do
      %Scope{} = scope -> reply(fun.(scope), frame)
      _missing -> {:reply, Response.error(Response.tool(), "Not signed in."), frame}
    end
  end

  defp reply({:ok, text}, frame) when is_binary(text) do
    {:reply, Response.text(Response.tool(), text), frame}
  end

  defp reply({:ok, data}, frame) do
    {:reply, Response.text(Response.tool(), Jason.encode!(data, pretty: true)), frame}
  end

  defp reply({:error, reason}, frame) do
    {:reply, Response.error(Response.tool(), Map.fetch!(@messages, reason)), frame}
  end
end
