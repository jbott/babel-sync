defmodule BabelSyncWeb.VaultLive.Tree do
  @moduledoc false

  alias BabelSync.Vaults.Entry

  defstruct [:name, :path, :entry, children: []]

  def build(entries) do
    entries
    |> Enum.reduce(%{}, fn %Entry{} = entry, tree ->
      insert(tree, String.split(entry.path, "/"), [], entry)
    end)
    |> to_nodes()
  end

  defp insert(tree, [name], parents, entry) do
    Map.update(
      tree,
      name,
      %{entry: entry, path: path(parents, name), children: %{}},
      &%{&1 | entry: entry}
    )
  end

  defp insert(tree, [name | rest], parents, entry) do
    node = Map.get(tree, name, %{entry: nil, path: path(parents, name), children: %{}})
    Map.put(tree, name, %{node | children: insert(node.children, rest, [name | parents], entry)})
  end

  defp path(parents, name), do: Enum.join(Enum.reverse([name | parents]), "/")

  defp to_nodes(tree) do
    tree
    |> Enum.map(fn {name, node} ->
      %__MODULE__{
        name: name,
        path: node.path,
        entry: node.entry,
        children: to_nodes(node.children)
      }
    end)
    |> Enum.sort_by(&{not folder?(&1), natural(&1.name), &1.name})
  end

  defp natural(name) do
    ~r/\d+/
    |> Regex.split(String.downcase(name), include_captures: true, trim: true)
    |> Enum.map(fn part ->
      if part =~ ~r/\A\d+\z/, do: {0, String.to_integer(part)}, else: {1, part}
    end)
  end

  def folder?(%__MODULE__{entry: %Entry{kind: :folder}}), do: true
  def folder?(%__MODULE__{entry: nil}), do: true
  def folder?(%__MODULE__{children: [_ | _]}), do: true
  def folder?(%__MODULE__{}), do: false
end
