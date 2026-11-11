defmodule BabelSync.MCP.Format do
  @moduledoc false

  alias BabelSync.Agent.Text

  def listing([]), do: "The folder is empty."

  def listing(listed) do
    Enum.map_join(listed, "\n", fn
      %{kind: :folder} = folder -> "#{folder.path}\tfolder\t#{folder.files} files"
      file -> "#{file.path}\t#{file.kind}\t#{file.bytes} bytes\t#{time(file.modified)}"
    end)
  end

  def paths([]), do: "No file matches."
  def paths(paths), do: Enum.join(paths, "\n")

  def matches([]), do: "No note matches."

  def matches(found) do
    Enum.map_join(found, "\n\n", fn %{path: path, matches: lines} ->
      path <>
        "\n" <>
        Enum.map_join(lines, "\n", fn line ->
          "#{line.line}#{if line.match, do: ":", else: "-"} #{line.text}"
        end)
    end)
  end

  def read(%{kind: :note} = read, numbered?) do
    range =
      case read do
        %{total: 0} -> "empty"
        %{first: 0} -> "no lines in that range, the note has #{read.total}"
        _lines -> "lines #{read.first}-#{read.last} of #{read.total}"
      end

    text =
      if numbered? and read.first > 0, do: Text.number(read.text, read.first), else: read.text

    {:parts, ["#{read.path} · #{range} · rev #{read.rev}", text]}
  end

  def read(%{kind: :attachment, image: nil} = file, _numbered?) do
    "#{file.path} is an attachment (#{file.type}, #{file.bytes} bytes) that cannot be shown as text."
  end

  def read(%{kind: :attachment} = file, _numbered?) do
    {:parts,
     ["#{file.path} · #{file.type} · #{file.bytes} bytes", {:image, file.image, file.type}]}
  end

  def outline(outline) do
    properties =
      case outline.properties do
        [] -> []
        keys -> ["properties: " <> Enum.join(keys, ", ")]
      end

    headings =
      for heading <- outline.headings do
        "#{heading.line}\t#{String.duplicate("#", heading.level)} #{heading.title}"
      end

    Enum.join(
      ["#{outline.path} · #{outline.lines} lines · rev #{outline.rev}"] ++ properties ++ headings,
      "\n"
    )
  end

  def written(%{kind: :attachment} = written) do
    "#{written.outcome} #{written.path} · #{written.type} · #{written.bytes} bytes"
  end

  def written(written) do
    "#{written.outcome} #{written.path} · rev #{written.rev} · #{written.lines} lines\n" <>
      written.changed
  end

  def queried(%{counts: counts, total: total, group: group}) do
    lines = Enum.map(counts, fn {value, count} -> "#{count}\t#{blank(value)}" end)
    Enum.join(["#{total} notes by #{group}" | lines], "\n")
  end

  def queried(%{total: 0}), do: "No note matches."

  def queried(%{columns: columns, rows: rows, total: total}) do
    shown =
      if length(rows) < total,
        do: "#{length(rows)} of #{total} notes; raise limit or narrow the query for the rest",
        else: counted(total)

    Enum.join([shown, Enum.join(columns, "\t") | Enum.map(rows, &Enum.join(&1, "\t"))], "\n")
  end

  def properties(%{notes: notes, properties: []}),
    do: "None of the #{notes} files there has properties."

  def properties(%{notes: notes, properties: properties}) do
    lines =
      for property <- properties do
        "#{property.name}\t#{property.notes} notes\t#{Enum.join(property.kinds, " or ")}\t" <>
          Enum.join(property.examples, " | ")
      end

    Enum.join(["#{notes} files" | lines], "\n")
  end

  defp counted(1), do: "1 note"
  defp counted(count), do: "#{count} notes"

  defp blank(""), do: "(none)"
  defp blank(value), do: value

  def trash([]), do: "The trash is empty."

  def trash(trash) do
    Enum.map_join(trash, "\n", &"#{&1.path}\t#{&1.kind}\tdeleted #{time(&1.deleted_at)}")
  end

  def changes(%{cursor: cursor, changes: changes}) do
    lines = Enum.map(changes, &"#{&1.change}\t#{&1.path}\t#{&1.kind}\t#{time(&1.at)}")
    Enum.join(["cursor #{cursor}" | lines], "\n")
  end

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
