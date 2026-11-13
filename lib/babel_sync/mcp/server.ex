defmodule BabelSync.MCP.Server do
  @moduledoc """
  The Model Context Protocol server: a vault as a file system of tools for
  agents, served over Streamable HTTP at `/mcp`.
  """

  @instructions """
  Babel Sync holds Obsidian vaults: folders of Markdown notes and attachments that people \
  are editing live, in Obsidian and in the browser, while you work.

  Find things with list_directory, find_files (path patterns) and search_files (note text). \
  For a long note, file_outline gives its headings and line numbers; read_file then takes \
  an offset and limit.

  Notes carry properties, and query_notes treats a folder as a table of them: filter with an \
  expression, keep notes within a distance of a point, sort, count by a value, or run a \
  .base file's own views. list_properties shows which properties exist. Reach for these \
  before reading notes one by one.

  Change a note with edit_file or append_file. They send only the passage you change, need \
  no read first, and merge with what people are typing. write_file is for new notes; \
  replacing a whole existing note needs the rev from your last read, and is refused if the \
  note changed since. A refused call changes nothing and says what to do next.

  Deleted files go to the trash (list_trash, restore_file) and every note keeps its saved \
  versions (file_history). list_changes shows what happened in a vault since a cursor.

  Every file that holds text works with every tool, whatever its extension: Markdown notes, \
  .base and .canvas files, .csv, .json, code and the like. edit_file and append_file change \
  just the passage you name in all of them. The one difference is what happens when a \
  person changes the same file at the same moment: in Markdown, .txt, .base and .canvas \
  files both changes are kept; in other text files pass if_rev to be refused instead of \
  overwriting theirs. Images are shown. Binary files are written whole, as base64, with write_file.

  Any file can also move outside the conversation: upload_file and download_file give an \
  HTTP link to PUT or GET its bytes with curl, for files too large for a tool call, files \
  that are not text, or files on a disk you can reach from a shell. Without a shell, \
  read_file with encoding base64 returns any file's bytes, up to 8 MiB.

  Notes use Obsidian Markdown: [[wikilinks]], #tags, and YAML properties between --- lines \
  at the top.
  """

  use Anubis.Server,
    name: "Babel Sync",
    version: "0.1.0",
    capabilities: [:tools],
    instructions: @instructions

  alias BabelSync.MCP.Tools

  @impl true
  def serialize_assigns(_assigns), do: %{}

  component(Tools.ListVaults)
  component(Tools.ListDirectory)
  component(Tools.FindFiles)
  component(Tools.SearchFiles)
  component(Tools.QueryNotes)
  component(Tools.ListProperties)
  component(Tools.ReadFile)
  component(Tools.FileOutline)
  component(Tools.WriteFile)
  component(Tools.UploadFile)
  component(Tools.DownloadFile)
  component(Tools.EditFile)
  component(Tools.AppendFile)
  component(Tools.CreateDirectory)
  component(Tools.MoveFile)
  component(Tools.DeleteFile)
  component(Tools.ListTrash)
  component(Tools.RestoreFile)
  component(Tools.FileHistory)
  component(Tools.ListChanges)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
