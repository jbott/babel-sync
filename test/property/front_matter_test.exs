defmodule BabelSync.Property.FrontMatterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BabelSync.Markdown.FrontMatter

  defp key, do: string([?a..?z, ?_], min_length: 1, max_length: 8)
  defp text, do: string(:printable, max_length: 30)

  defp value do
    one_of([
      text(),
      integer(),
      boolean(),
      list_of(text(), max_length: 4) |> map(&Enum.uniq/1)
    ])
  end

  defp properties, do: map_of(key(), value(), max_length: 6)

  property "what is set can be read back, whatever the text" do
    check all(first <- properties(), second <- properties(), body <- text()) do
      {:ok, note} = FrontMatter.set(body, Map.to_list(first))
      {:ok, note} = FrontMatter.set(note, Map.to_list(second))

      assert FrontMatter.read(note) == {:ok, Map.merge(first, second)}
      assert String.ends_with?(note, body)
    end
  end

  property "setting the same properties again changes nothing" do
    check all(wanted <- properties(), body <- text()) do
      {:ok, note} = FrontMatter.set(body, Map.to_list(wanted))

      assert FrontMatter.set(note, Map.to_list(wanted)) == {:ok, note}
    end
  end

  property "properties not named keep their lines" do
    check all(kept <- properties(), changed <- properties()) do
      kept = Map.drop(kept, Map.keys(changed))
      {:ok, note} = FrontMatter.set("", Map.to_list(kept))
      {:ok, after_change} = FrontMatter.set(note, Map.to_list(changed))

      for line <- String.split(note, "\n"), line not in ["---", ""] do
        assert line in String.split(after_change, "\n")
      end
    end
  end

  property "a list merge never drops what a person added" do
    check all(
            before <- list_of(text(), max_length: 4),
            added <- list_of(text(), max_length: 3),
            wanted <- list_of(text(), max_length: 4)
          ) do
      before = Enum.uniq(before)
      {:ok, note} = FrontMatter.set("", [{"tags", Enum.uniq(before ++ added)}])
      {:ok, merged} = FrontMatter.merge(note, [{"tags", Enum.uniq(wanted)}], %{"tags" => before})
      {:ok, read} = FrontMatter.read(merged)
      tags = Map.get(read, "tags", [])

      for item <- added, item not in before, do: assert(item in tags)
      for item <- wanted, do: assert(item in tags)
    end
  end
end
