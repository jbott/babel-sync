defmodule BabelSync.Sources.Script do
  @moduledoc """
  Reads a source out of a note.

  The note's properties say what the script may do: `schedule` how often
  it runs, `hosts` where it may fetch from, `secrets` which secret goes
  to which host in which header, `writes` and `reads` the folders it may
  change and look in, `params` whatever the script wants to be told. The
  first `js` code block is the script. Anything else in the note is for
  people.

  What is read here is what an admin approves, so nothing is guessed or
  let through half understood: a property that is not one of these in
  the right shape is a problem to fix, listed with the rest.
  """

  alias BabelSync.Markdown.FrontMatter
  alias BabelSync.Vaults

  @enforce_keys [:code]
  defstruct [:code, :schedule, hosts: [], secrets: %{}, writes: [], reads: [], params: %{}]

  @type secret :: %{host: String.t(), header: String.t(), template: String.t()}
  @type t :: %__MODULE__{
          code: String.t(),
          schedule: pos_integer() | nil,
          hosts: [String.t()],
          secrets: %{String.t() => secret()},
          writes: [String.t()],
          reads: [String.t()],
          params: map()
        }

  @fence ~r/^```(?:js|javascript)[ \t]*\n(.*?)^```[ \t]*$/ms
  @every ~r/^every\s+(\d+)\s*(m|h|d)$/
  @unit %{"m" => 60, "h" => 3600, "d" => 86_400}
  @shortest 300
  @host ~r/^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
  @header ~r/^([A-Za-z0-9-]+):\s*(.*\{\}.*)$/
  @known ~w(type schedule hosts secrets writes reads params)

  @spec source?(String.t()) :: boolean()
  def source?(text), do: match?({:ok, %{"type" => "source"}}, FrontMatter.read(text))

  @spec parse(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(text) do
    with {:ok, properties} <- properties(text),
         {:ok, code} <- code(text) do
      fields = [
        schedule: schedule(properties["schedule"]),
        hosts: hosts(properties["hosts"]),
        secrets: secrets(properties["secrets"]),
        writes: folders("writes", properties["writes"]),
        reads: folders("reads", properties["reads"]),
        params: params(properties["params"])
      ]

      case for {_field, {:error, problem}} <- fields, do: problem do
        [] -> checked(struct!(__MODULE__, [code: code] ++ values(fields)))
        problems -> {:error, problems}
      end
    end
  end

  @spec manifest(t()) :: String.t()
  def manifest(%__MODULE__{} = script) do
    Jason.encode!(
      Jason.OrderedObject.new(
        schedule: script.schedule,
        hosts: script.hosts,
        secrets: ordered(script.secrets),
        writes: script.writes,
        reads: script.reads,
        params: ordered(script.params)
      ),
      pretty: true
    )
  end

  @spec from_manifest(String.t(), String.t()) :: t()
  def from_manifest(manifest, code) do
    held = Jason.decode!(manifest)

    %__MODULE__{
      code: code,
      schedule: held["schedule"],
      hosts: held["hosts"],
      writes: held["writes"],
      reads: held["reads"],
      params: held["params"],
      secrets:
        Map.new(held["secrets"], fn {name, secret} ->
          {name, %{host: secret["host"], header: secret["header"], template: secret["template"]}}
        end)
    }
  end

  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = script) do
    :crypto.hash(:sha256, [manifest(script), 0, script.code]) |> Base.encode16(case: :lower)
  end

  defp properties(text) do
    case FrontMatter.read(text) do
      {:ok, %{"type" => "source"} = properties} ->
        case Map.keys(properties) -- @known do
          [] -> {:ok, properties}
          unknown -> {:error, Enum.map(unknown, &"#{&1} is not something a source can be given")}
        end

      {:ok, _other} ->
        {:error, ["the note's properties do not say type: source"]}

      {:error, :invalid_front_matter} ->
        {:error, ["the note's properties cannot be read"]}
    end
  end

  defp code(text) do
    case Regex.run(@fence, text) do
      [_, code] -> {:ok, code}
      nil -> {:error, ["the note has no js code block"]}
    end
  end

  defp values(fields), do: for({field, {:ok, value}} <- fields, do: {field, value})

  defp checked(%__MODULE__{} = script) do
    case for {name, %{host: host}} <- script.secrets, host not in script.hosts, do: {name, host} do
      [] ->
        {:ok, script}

      stray ->
        {:error,
         for({name, host} <- stray, do: "secret #{name} is for #{host}, which is not in hosts")}
    end
  end

  defp schedule(nil), do: {:ok, nil}

  defp schedule(text) when is_binary(text) do
    case Regex.run(@every, String.trim(text)) do
      [_, count, unit] ->
        seconds = String.to_integer(count) * @unit[unit]

        if seconds >= @shortest,
          do: {:ok, seconds},
          else: {:error, "schedule cannot be more often than every 5m"}

      nil ->
        {:error, "schedule is written like: every 6h (m, h or d)"}
    end
  end

  defp schedule(_other), do: {:error, "schedule is written like: every 6h (m, h or d)"}

  defp hosts(nil), do: {:ok, []}

  defp hosts(hosts) when is_list(hosts) do
    if Enum.all?(hosts, &(is_binary(&1) and Regex.match?(@host, &1))),
      do: {:ok, hosts},
      else: {:error, "hosts is a list of host names in lower case, such as api.github.com"}
  end

  defp hosts(_other), do: {:error, "hosts is a list of host names"}

  defp secrets(nil), do: {:ok, %{}}

  defp secrets(secrets) when is_map(secrets) do
    read = Enum.map(secrets, fn {name, secret} -> {to_string(name), secret(secret)} end)

    if Enum.all?(read, fn {_name, secret} -> secret end),
      do: {:ok, Map.new(read)},
      else:
        {:error,
         ~s(each secret is written like: { host: api.github.com, header: "Authorization: Bearer {}" })}
  end

  defp secrets(_other), do: {:error, "secrets is a list of names, each with a host and a header"}

  defp secret(%{"host" => host, "header" => header}) when is_binary(host) and is_binary(header) do
    case Regex.run(@header, header) do
      [_, name, template] -> %{host: host, header: name, template: template}
      nil -> nil
    end
  end

  defp secret(_other), do: nil

  defp folders(_field, nil), do: {:ok, []}

  defp folders(field, folders) when is_list(folders) do
    if Enum.all?(folders, &folder?/1),
      do: {:ok, Enum.map(folders, &Vaults.Path.normalize/1)},
      else: {:error, "#{field} is a list of folders in the vault, and cannot include .obsidian"}
  end

  defp folders(field, _other), do: {:error, "#{field} is a list of folders"}

  defp folder?(folder) when is_binary(folder) do
    path = Vaults.Path.normalize(folder)
    path != "" and Vaults.Path.valid?(path) and not hidden?(path)
  end

  defp folder?(_other), do: false

  defp hidden?(path), do: path |> String.downcase() |> String.starts_with?(".obsidian")

  defp params(nil), do: {:ok, %{}}
  defp params(params) when is_map(params), do: {:ok, params}
  defp params(_other), do: {:error, "params is a list of names and values"}

  defp ordered(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort()
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
