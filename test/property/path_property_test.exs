defmodule BabelSync.PathPropertyTest do
  use BabelSync.DataCase, async: true
  use ExUnitProperties

  alias BabelSync.Vaults.Path, as: VaultPath

  defp segment do
    gen all(
          name <-
            one_of([
              string([?a..?z, ?A..?Z, ?0..?9, ?%, ?_, ?!, ?\s, ?., ?-, ?é, ?É, ?ß, ?😀],
                min_length: 1,
                max_length: 8
              ),
              member_of(["Notes", "notes", "a_b", "a%b", "a!b", "Café", "café", "é"])
            ]),
          name not in [".", ".."]
        ) do
      name
    end
  end

  defp path,
    do:
      gen(
        all(parts <- list_of(segment(), min_length: 1, max_length: 4), do: Enum.join(parts, "/"))
      )

  defp like?(value, pattern) do
    query =
      from(row in fragment("SELECT 1 AS one"),
        select: fragment("? LIKE ? ESCAPE '!'", ^value, ^pattern)
      )

    Repo.one(query) in [true, 1]
  end

  property "folding is idempotent and ignores case and Unicode form" do
    check all(path <- path()) do
      folded = VaultPath.fold(path)
      assert VaultPath.fold(folded) == folded
      assert VaultPath.fold(String.downcase(path)) == folded
      assert VaultPath.fold(:unicode.characters_to_nfd_binary(path)) == folded
    end
  end

  property "the folder pattern matches exactly the paths inside that folder" do
    check all(folder <- path(), inside <- path(), other <- path()) do
      pattern = folder |> VaultPath.fold() |> VaultPath.like_prefix()

      assert like?(VaultPath.fold(folder <> "/" <> inside), pattern)
      refute like?(VaultPath.fold(folder), pattern)

      expected = String.starts_with?(VaultPath.fold(other), VaultPath.fold(folder) <> "/")
      assert like?(VaultPath.fold(other), pattern) == expected
    end
  end
end
