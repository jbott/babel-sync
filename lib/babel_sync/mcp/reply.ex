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

  defp reply({:ok, {:meta, inner, meta}}, frame) do
    {:reply, response, frame} = reply({:ok, inner}, frame)
    {:reply, Response.meta(response, meta), frame}
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

  defp message(:forbidden) do
    "This credential may not do that in this vault. Reading may be all it allows, " <>
      "or the path is among the Obsidian plugins, which only an owner may change."
  end

  defp message(:vault_not_found),
    do: "No such vault. Call list_vaults to see the vaults available."

  defp message(:ambiguous_vault),
    do: "More than one vault is available. Pass the vault name or id."

  defp message(:not_found),
    do: "Nothing exists at that path. Call list_directory or find_files to see what does."

  defp message(:not_a_note), do: "That path is a folder or a file that is not text."

  defp message(:not_an_attachment) do
    "That path is a note or a folder. Notes are written as text, without an encoding." <>
      @unchanged
  end

  defp message(:invalid_encoding), do: "The content is not valid base64." <> @unchanged

  defp message(:too_large) do
    "A note, and anything written in the call itself, may be at most 8 MiB." <>
      @unchanged <> " A larger attachment can be sent with upload_file."
  end

  defp message(:over_quota) do
    "The vault has reached the storage its server allows and has no room for this file." <>
      @unchanged
  end

  defp message(:too_large_to_store) do
    "That is larger than the #{div(BabelSync.Blobs.max_size(), 1024 * 1024)} MiB this server keeps in one file." <>
      @unchanged
  end

  defp message(:not_a_folder), do: "That path is a file, not a folder."
  defp message(:exists), do: "A file already exists at the destination path." <> @unchanged
  defp message(:invalid_path), do: "That is not a valid vault path."

  defp message(:off_limits) do
    "The .obsidian folder holds Obsidian's plugins and settings and is closed to agents in this vault." <>
      @unchanged <> " The vault's owner can open it in the vault settings."
  end

  defp message(:storage_unavailable),
    do: "The server could not store the file just now." <> @unchanged <> " Try again later."

  defp message(:search_timeout) do
    "The search took longer than ten seconds and was stopped." <>
      " Use a simpler pattern, or narrow it with glob."
  end

  defp message(:too_large_to_read) do
    "That file is larger than the 8 MiB read_file returns as base64." <>
      " download_file gives a link to fetch it with curl from a shell."
  end

  defp message(:invalid_size), do: "size must be the file's size in bytes, zero or more."

  defp message(:not_a_folder_target),
    do: "A folder exists at that path." <> @unchanged

  defp message(:invalid_pattern),
    do: "That pattern is empty or malformed. Check the brackets and braces."

  defp message({:invalid_query, message}),
    do: "That query could not be run: #{message}. Call list_properties to see what notes hold."

  defp message(:no_coordinates) do
    "near must be \"latitude, longitude\" or the path of a note that has coordinates, " <>
      "inside the folder being queried."
  end

  defp message(:unguarded) do
    "A file already exists at that path." <>
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
