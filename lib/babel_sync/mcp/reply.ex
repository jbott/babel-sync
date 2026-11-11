defmodule BabelSync.MCP.Reply do
  @moduledoc false

  alias Anubis.Server.Response
  alias BabelSync.Accounts.Scope

  @unchanged " Nothing was changed."

  def run(frame, fun) do
    case frame.assigns[:current_scope] do
      %Scope{} = scope -> reply(fun.(scope), frame)
      _missing -> {:reply, Response.error(Response.tool(), "Not signed in."), frame}
    end
  end

  defp reply({:ok, text}, frame) when is_binary(text) do
    {:reply, Response.text(Response.tool(), text), frame}
  end

  defp reply({:ok, {:parts, parts}}, frame) do
    response =
      Enum.reduce(parts, Response.tool(), fn
        {:image, data, type}, response -> Response.image(response, Base.encode64(data), type)
        text, response -> Response.text(response, text)
      end)

    {:reply, response, frame}
  end

  defp reply({:ok, data}, frame) do
    {:reply, Response.text(Response.tool(), Jason.encode!(data, pretty: true)), frame}
  end

  defp reply({:error, reason}, frame) do
    {:reply, Response.error(Response.tool(), message(reason)), frame}
  end

  defp message(:forbidden), do: "This credential may not do that in this vault."

  defp message(:vault_not_found),
    do: "No such vault. Call list_vaults to see the vaults available."

  defp message(:ambiguous_vault),
    do: "More than one vault is available. Pass the vault name or id."

  defp message(:not_found),
    do: "Nothing exists at that path. Call list_directory or find_files to see what does."

  defp message(:not_a_note), do: "That path is an attachment or folder, not a text note."
  defp message(:not_a_folder), do: "That path is a file, not a folder."
  defp message(:exists), do: "A file already exists at the destination path." <> @unchanged
  defp message(:invalid_path), do: "That is not a valid vault path."

  defp message(:off_limits) do
    "The .obsidian folder holds Obsidian's plugins and settings and is closed to agents in this vault." <>
      @unchanged <> " The vault's owner can open it in the vault settings."
  end

  defp message(:invalid_pattern),
    do: "That pattern is empty or malformed. Check the brackets and braces."

  defp message(:unguarded) do
    "A note already exists at that path." <>
      @unchanged <>
      " Use edit_file or append_file to change part of it. To replace all of it, pass if_rev" <>
      " with the rev from read_file, or overwrite: true."
  end

  defp message({:stale, rev}) do
    "The note changed since the rev you passed; it is now at rev #{rev}." <>
      @unchanged <> " Read it again, or use edit_file, which works on the current text."
  end

  defp message(:no_heading),
    do: "The note has no such heading." <> @unchanged <> " Call file_outline to see its headings."

  defp message(:ambiguous_heading) do
    "More than one heading has that title." <>
      @unchanged <> " Use edit_file with a passage from the section you mean."
  end

  defp message({:no_match, edit}) do
    "Edit #{edit}: old_text was not found in the note." <>
      @unchanged <> " Check spacing and line breaks, or search_files for the passage."
  end

  defp message({:ambiguous_match, edit}) do
    "Edit #{edit}: old_text is empty or occurs more than once." <>
      @unchanged <> " Include more surrounding text, or set replace_all."
  end
end
