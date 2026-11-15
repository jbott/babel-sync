defmodule BabelSync.Sources.Host do
  @moduledoc """
  Everything a source's script can ask of the server, and the check on
  each.

  The script is handed `http`, `vault`, `state`, `log`, `attention`,
  `params` and `trigger`. Underneath, each is one call out of the
  sandbox with a name and JSON, answered here against what the source
  was approved for: its hosts, its folders, its secrets, and how much of
  each thing one run may use. A script can call these with anything it
  likes, so nothing it sends is trusted because the helpers it was given
  would not have sent it.

  What a run did is kept in a table the run owns rather than in the
  process the script runs under, so that it is still there to record
  when the script had to be killed.
  """

  alias BabelSync.Accounts.Scope
  alias BabelSync.Sources.{Fetch, Items, Script, Source}
  alias BabelSync.{Sync, Vaults}
  alias BabelSync.Vaults.Entry

  @type run :: %{
          source: Source.t(),
          script: Script.t(),
          scope: Scope.t(),
          secrets: [Fetch.secret()],
          kept: :ets.tid(),
          limits: keyword()
        }

  @prelude """
           const __call = (op, payload) => JSON.parse(__host(op, JSON.stringify(payload === undefined ? null : payload)));\
           const params = __PARAMS__, trigger = __TRIGGER__, __state = __STATE__;\
           const state = { get: (key) => __state[key], set: (key, value) => { __state[key] = value; __call("state", [key, value === undefined ? null : value]); } };\
           const log = (...parts) => { __call("log", parts.map((part) => typeof part === "string" ? part : JSON.stringify(part)).join(" ")); };\
           const __next = (link) => { const found = /<([^>]+)>;\\s*rel="next"/.exec(link || ""); return found ? found[1] : null; };\
           const __answer = (got) => ({ status: got.status, ok: got.status >= 200 && got.status < 300, url: got.url, headers: got.headers, next: __next(got.headers.link), text: () => got.body, json: () => JSON.parse(got.body) });\
           const __ask = (method) => (url, options = {}) => __answer(__call("http", { method, url, headers: options.headers || {}, body: options.body === undefined || options.body === null ? null : typeof options.body === "string" ? options.body : JSON.stringify(options.body) }));\
           const http = { get: __ask("GET"), post: __ask("POST"), put: __ask("PUT"), patch: __ask("PATCH"), delete: __ask("DELETE"), head: __ask("HEAD") };\
           const vault = { folder: __FOLDER__, item: (key, item) => __call("item", { key, ...item }), read: (path) => __call("read", path), list: (folder) => __call("list", folder), name: (text) => String(text).replace(/[\\\\/:*?"<>|#^\\[\\]]+/g, " ").replace(/\\s+/g, " ").trim().slice(0, 120) };\
           const attention = (message, options = {}) => { __call("attention", { message, url: options.url || null }); };\
           """
           |> String.replace("\\\n", " ")
           |> String.trim()

  @spec program(Script.t(), map(), String.t()) :: String.t()
  def program(%Script{} = script, state, trigger) do
    prelude =
      @prelude
      |> String.replace("__PARAMS__", Jason.encode!(script.params))
      |> String.replace("__TRIGGER__", Jason.encode!(trigger))
      |> String.replace("__FOLDER__", Jason.encode!(List.first(script.writes)))
      |> String.replace("__STATE__", Jason.encode!(state))

    "(function () { #{prelude} #{script.code}\n})(); \"\""
  end

  @spec handler(run()) :: BabelSync.Sandbox.handler()
  def handler(run) do
    fn op, payload ->
      with {:ok, asked} <- Jason.decode(payload, objects: :ordered_objects),
           {:ok, answer} <- handle(op, asked, run) do
        {:ok, Jason.encode!(answer)}
      else
        {:error, %Jason.DecodeError{}} -> {:error, "#{op} was not given JSON"}
        {:error, message} when is_binary(message) -> {:error, message}
      end
    end
  end

  defp handle("http", %Jason.OrderedObject{} = asked, run) do
    asked = plain(asked)

    with :ok <- spend(run, :requests, "this run has made all the requests it may"),
         {:ok, url} <- text(asked["url"], "http needs a web address"),
         {:ok, answer} <-
           Fetch.request(
             %{
               url: url,
               method: asked["method"] || "GET",
               headers: if(is_map(asked["headers"]), do: asked["headers"], else: %{}),
               body: asked["body"]
             },
             hosts: run.script.hosts,
             private_hosts: run.limits[:private_hosts],
             secrets: run.secrets,
             most: run.limits[:response_bytes]
           ) do
      if String.valid?(answer.body),
        do: {:ok, answer},
        else: {:error, "#{url} did not answer with text"}
    end
  end

  defp handle("item", %Jason.OrderedObject{} = asked, run) do
    fields = Map.new(asked.values)
    folders = run.script.writes

    with :ok <- spend(run, :writes, "this run has written all the notes it may"),
         {:ok, key} <- text(fields["key"], "an item needs a key"),
         {:ok, path} <- text(fields["path"], "an item needs a path"),
         path = Enum.join(Enum.take(folders, 1) ++ [path], "/"),
         {:ok, properties} <- properties(fields["properties"]),
         {:ok, match} <- match(fields["match"]),
         wanted = %{
           key: key,
           path: path,
           properties: properties,
           match: match,
           body: body(fields["body"])
         },
         {:ok, outcome, path} <-
           Items.put(run.source, run.scope, folders, wanted, finder(run, folders)) do
      count(run, outcome)
      {:ok, %{outcome: outcome, path: path}}
    end
  end

  defp handle("read", path, run) when is_binary(path) do
    with :ok <- Items.within(path, readable(run)) do
      case Vaults.get_entry_by_path(run.source.vault_id, path) do
        %Entry{kind: :doc, deleted_at: nil, id: id} -> {:ok, Sync.text(id)}
        _none -> {:ok, nil}
      end
    end
  end

  defp handle("list", folder, run) when is_binary(folder) do
    with :ok <- Items.within(folder <> "/x", readable(run)) do
      {:ok,
       for(
         %Entry{kind: kind, path: path} <- Vaults.list_entries(run.source.vault_id),
         kind != :folder,
         Items.within(path, [folder]) == :ok,
         do: path
       )
       |> Enum.sort()}
    end
  end

  defp handle("state", [key, value], run) when is_binary(key) do
    state = Map.put(kept(run, :state, %{}), key, plain(value))

    if byte_size(Jason.encode!(state)) > run.limits[:state_bytes] do
      {:error, "this source is asking to remember too much"}
    else
      keep(run, :state, state)
      {:ok, nil}
    end
  end

  defp handle("log", line, run) when is_binary(line) do
    log = kept(run, :log, "")

    if byte_size(log) < run.limits[:log_bytes],
      do: keep(run, :log, log <> String.slice(line, 0, 2_000) <> "\n")

    {:ok, nil}
  end

  defp handle("attention", %Jason.OrderedObject{} = asked, run) do
    asked = plain(asked)

    with {:ok, message} <- text(asked["message"], "attention needs a message"),
         :ok <- linkable(asked["url"], run.script.hosts) do
      keep(run, :attention, %{message: String.slice(message, 0, 300), url: asked["url"]})
      {:ok, nil}
    end
  end

  defp handle(op, _asked, _run), do: {:error, "#{op} is not something a source can ask for"}

  defp linkable(nil, _hosts), do: :ok

  defp linkable(url, hosts) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
        if Enum.any?(
             hosts,
             &(&1 == host or
                 (match?("*." <> _, &1) and String.ends_with?(host, String.trim_leading(&1, "*"))))
           ),
           do: :ok,
           else: {:error, "a link must be to one of this source's hosts"}

      _other ->
        {:error, "a link must be an https address"}
    end
  end

  defp linkable(_other, _hosts), do: {:error, "a link must be an https address"}

  defp readable(run), do: Enum.uniq(run.script.reads ++ run.script.writes)

  defp finder(run, folders) do
    Items.finder(run.source.vault_id, folders, fn name, make ->
      case :ets.lookup(run.kept, name) do
        [{^name, made}] -> made
        [] -> keep(run, name, make.())
      end
    end)
  end

  defp properties(nil), do: {:ok, []}

  defp properties(%Jason.OrderedObject{values: values}) do
    {:ok, for({name, value} <- values, do: {name, plain(value)})}
  end

  defp properties(_other), do: {:error, "an item's properties are names and values"}

  defp match(nil), do: {:ok, nil}

  defp match(%Jason.OrderedObject{values: [{property, value}]}) when not is_nil(value),
    do: {:ok, {property, to_string(plain(value))}}

  defp match(_other), do: {:error, "match names one property and the value it must have"}

  defp body(body) when is_binary(body), do: Sync.normalize(body)
  defp body(_none), do: ""

  defp text(text, _problem) when is_binary(text) and text != "", do: {:ok, text}
  defp text(_other, problem), do: {:error, problem}

  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {name, value} -> {name, plain(value)} end)

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  defp spend(run, what, refusal) do
    if :ets.update_counter(run.kept, what, 1, {what, 0}) > run.limits[what],
      do: {:error, refusal},
      else: :ok
  end

  defp count(run, outcome), do: :ets.update_counter(run.kept, outcome, 1, {outcome, 0})

  defp kept(run, name, otherwise) do
    case :ets.lookup(run.kept, name) do
      [{^name, value}] -> value
      [] -> otherwise
    end
  end

  defp keep(run, name, value) do
    :ets.insert(run.kept, {name, value})
    value
  end
end
