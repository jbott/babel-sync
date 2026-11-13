defmodule BabelSync.Bases.Note do
  @moduledoc """
  A file as a base sees it: where it is, when it changed, and the
  properties written as YAML between `---` lines at its top.
  """

  @enforce_keys [:path]
  defstruct [:path, :created, :modified, size: 0, properties: %{}, tags: [], links: []]

  @type facts :: %{
          properties: %{optional(String.t()) => term()},
          tags: [String.t()],
          links: [String.t()]
        }

  @type t :: %__MODULE__{
          path: String.t(),
          created: DateTime.t() | nil,
          modified: DateTime.t() | nil,
          size: non_neg_integer(),
          properties: %{optional(String.t()) => term()},
          tags: [String.t()],
          links: [String.t()]
        }

  @spec new(keyword()) :: t()
  def new(fields) do
    {text, fields} = Keyword.pop(fields, :text)
    {facts, fields} = Keyword.pop(fields, :facts, read(text || ""))
    struct!(__MODULE__, fields ++ Map.to_list(facts))
  end

  @spec read(String.t()) :: facts()
  def read(text) do
    properties = properties(text)
    %{properties: properties, tags: tags_in(properties, text), links: wikilinks(text)}
  end

  @spec properties(String.t()) :: %{optional(String.t()) => term()}
  def properties("---\n" <> rest) do
    with [block, _body] <- String.split(rest, ~r/^---[ \t]*$/m, parts: 2),
         {:ok, %{} = parsed} <- YamlElixir.read_from_string(block) do
      Map.new(parsed, fn {key, value} -> {to_string(key), value} end)
    else
      _unreadable -> %{}
    end
  end

  def properties(_text), do: %{}

  @spec name(t()) :: String.t()
  def name(%__MODULE__{path: path}), do: Path.basename(path)

  @spec basename(t()) :: String.t()
  def basename(%__MODULE__{path: path}), do: Path.basename(path, Path.extname(path))

  @spec extension(t()) :: String.t()
  def extension(%__MODULE__{path: path}),
    do: path |> Path.extname() |> String.trim_leading(".")

  @spec folder(t()) :: String.t()
  def folder(%__MODULE__{path: path}) do
    case Path.dirname(path) do
      "." -> ""
      folder -> folder
    end
  end

  @spec in_folder?(t(), String.t()) :: boolean()
  def in_folder?(%__MODULE__{path: path}, folder) do
    case String.trim(folder, "/") do
      "" -> true
      folder -> String.starts_with?(String.downcase(path), String.downcase(folder) <> "/")
    end
  end

  @spec tags(t()) :: [String.t()]
  def tags(%__MODULE__{tags: tags}), do: tags

  @spec links(t()) :: [String.t()]
  def links(%__MODULE__{links: links}), do: links

  defp tags_in(properties, text) do
    declared =
      case properties["tags"] do
        tags when is_list(tags) -> Enum.map(tags, &to_string/1)
        tags when is_binary(tags) -> String.split(tags, ~r/[\s,]+/, trim: true)
        _none -> []
      end

    inline =
      for [_all, tag] <-
            Regex.scan(~r/(?:^|\s)#([\p{L}\p{N}_\/-]*[\p{L}_\/-][\p{L}\p{N}_\/-]*)/u, text),
          do: tag

    (declared ++ inline) |> Enum.map(&String.trim_leading(&1, "#")) |> Enum.uniq()
  end

  defp wikilinks(text) do
    for([_all, target] <- Regex.scan(~r/\[\[([^\]|#]+)/u, text), do: String.trim(target))
    |> Enum.uniq()
  end
end
