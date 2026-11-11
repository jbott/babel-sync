defmodule BabelSync.Agent.Glob do
  @moduledoc """
  Shell-style path patterns: `*` within a folder, `**` across folders, `?`
  for one character and `{a,b}` for alternatives. A pattern without a slash
  matches the file name in any folder. Letter case is ignored.
  """

  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, :invalid_pattern}
  def compile(pattern) do
    pattern = pattern |> String.replace("\\", "/") |> String.trim_leading("/")
    anchor = if String.contains?(pattern, "/"), do: "^", else: "(?:^|/)"

    with true <- pattern != "",
         {:ok, source} <- translate(pattern, 0, []),
         {:ok, regex} <- Regex.compile(anchor <> source <> "$", "iu") do
      {:ok, regex}
    else
      _invalid -> {:error, :invalid_pattern}
    end
  end

  defp translate("", 0, done), do: {:ok, done |> Enum.reverse() |> IO.iodata_to_binary()}
  defp translate("", _open, _done), do: :error
  defp translate("**/" <> rest, depth, done), do: translate(rest, depth, ["(?:.*/)?" | done])
  defp translate("**" <> rest, depth, done), do: translate(rest, depth, [".*" | done])
  defp translate("*" <> rest, depth, done), do: translate(rest, depth, ["[^/]*" | done])
  defp translate("?" <> rest, depth, done), do: translate(rest, depth, ["[^/]" | done])
  defp translate("{" <> rest, depth, done), do: translate(rest, depth + 1, ["(?:" | done])

  defp translate("}" <> rest, depth, done) when depth > 0,
    do: translate(rest, depth - 1, [")" | done])

  defp translate("," <> rest, depth, done) when depth > 0,
    do: translate(rest, depth, ["|" | done])

  defp translate(pattern, depth, done) do
    {character, rest} = String.split_at(pattern, 1)
    translate(rest, depth, [Regex.escape(character) | done])
  end
end
