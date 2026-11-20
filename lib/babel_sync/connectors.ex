defmodule BabelSync.Connectors do
  @moduledoc false

  import Ecto.Query
  alias BabelSync.Accounts.Scope
  alias BabelSync.Connectors.{Cookies, Session}
  alias BabelSync.Sources.Fetch.Pinned
  alias BabelSync.Repo

  @type reason ::
          :forbidden
          | :invalid_session
          | :reauthorize
          | :not_found
          | :changed
          | :unavailable

  @spec connect(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, map()} | {:error, reason()}
  def connect(scope, vault_id, connection_id, params) do
    with :ok <- Scope.authorize(scope, vault_id, :admin),
         {:ok, payload} <- payload(params),
         session <- reserve(scope, vault_id, connection_id),
         {:ok, response, refreshed} <-
           fetch(payload, %{url: payload["landing_url"], headers: %{}}, []),
         :ok <- verified(response, payload["check_selector"]),
         :ok <- Scope.authorize(scope, vault_id, :admin),
         :ok <- replace(session, scope.user.id, refreshed) do
      {:ok, %{status: :connected}}
    end
  end

  @spec status(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, atom()} | {:error, :forbidden}
  def status(scope, vault_id, connection_id) do
    with :ok <- Scope.authorize(scope, vault_id, :admin) do
      case get(vault_id, connection_id) do
        %Session{sealed: sealed} when is_binary(sealed) -> {:ok, :connected}
        _none -> {:ok, :disconnected}
      end
    end
  end

  @spec disconnect(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :forbidden}
  def disconnect(scope, vault_id, connection_id) do
    with :ok <- Scope.authorize(scope, vault_id, :admin) do
      session = reserve(scope, vault_id, connection_id)

      Repo.update_all(from(s in Session, where: s.id == ^session.id),
        set: [sealed: nil, updated_at: DateTime.utc_now()],
        inc: [revision: 1]
      )

      :ok
    end
  end

  @spec request(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, reason()}
  def request(scope, vault_id, connection_id, asked, options) do
    with :ok <- Scope.authorize(scope, vault_id, :write),
         %Session{user_id: owner} = session <- get(vault_id, connection_id),
         true <- owner == scope.user.id,
         {:ok, payload} <- unseal(session),
         {:ok, uri} <- address(asked[:url], Keyword.get(options, :hosts, [])),
         true <- uri.host in payload["hosts"],
         {:ok, response, refreshed} <- fetch(payload, asked, options),
         :ok <- Scope.authorize(scope, vault_id, :write),
         :ok <- refresh(session, payload, refreshed) do
      {:ok, redact(response, payload["cookies"] ++ refreshed["cookies"])}
    else
      nil -> {:error, :not_found}
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp payload(params) do
    with hosts when is_list(hosts) and hosts != [] <- params["hosts"],
         true <- Enum.all?(hosts, &host?/1),
         {:ok, _uri} <- address(params["landing_url"], hosts),
         selector when is_binary(selector) and byte_size(selector) in 1..1000 <-
           params["check_selector"],
         {:ok, cookies} <- Cookies.validate(params["cookies"], hosts),
         {:ok, agent} <- user_agent(params["user_agent"]) do
      {:ok,
       %{
         "cookies" => cookies,
         "user_agent" => agent,
         "hosts" => Enum.uniq(hosts),
         "landing_url" => params["landing_url"],
         "check_selector" => selector
       }}
    else
      _invalid -> {:error, :invalid_session}
    end
  end

  defp host?(host) when is_binary(host),
    do: byte_size(host) <= 253 and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/, host)

  defp host?(_host), do: false

  defp address(url, hosts) when is_binary(url) do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil} = uri} <- URI.new(url),
         true <- is_binary(host) and Enum.any?(hosts, &granted?(host, &1)) do
      {:ok, uri}
    else
      _invalid -> {:error, :forbidden}
    end
  end

  defp address(_url, _hosts), do: {:error, :forbidden}
  defp granted?(host, "*." <> suffix), do: String.ends_with?(host, "." <> suffix)
  defp granted?(host, granted), do: host == granted

  defp verified(%{status: status, body: body}, selector) when status in 200..299 do
    if body |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.any?(),
      do: :ok,
      else: {:error, :reauthorize}
  rescue
    ArgumentError -> {:error, :invalid_session}
  end

  defp verified(_response, _selector), do: {:error, :reauthorize}

  defp get(vault_id, connection_id),
    do: Repo.get_by(Session, vault_id: vault_id, connection_id: connection_id)

  defp reserve(scope, vault_id, connection_id) do
    Repo.insert!(
      %Session{vault_id: vault_id, connection_id: connection_id, user_id: scope.user.id},
      on_conflict: :nothing,
      conflict_target: [:vault_id, :connection_id]
    )

    get(vault_id, connection_id)
  end

  defp user_agent(value) when is_binary(value) do
    if byte_size(value) in 1..512 and Regex.match?(~r/\A[ -~]+\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_session}
  end

  defp user_agent(_value), do: {:error, :invalid_session}

  defp replace(session, owner, payload) do
    sealed =
      Plug.Crypto.MessageEncryptor.encrypt(
        Jason.encode!(payload),
        bound(session),
        key("session"),
        key("signing")
      )

    query = from s in Session, where: s.id == ^session.id and s.revision == ^session.revision

    case Repo.update_all(query,
           set: [sealed: sealed, user_id: owner, updated_at: DateTime.utc_now()],
           inc: [revision: 1]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :changed}
    end
  end

  defp refresh(session, payload, payload) do
    if Repo.exists?(
         from s in Session,
           where: s.id == ^session.id and s.revision == ^session.revision and not is_nil(s.sealed)
       ), do: :ok, else: {:error, :changed}
  end

  defp refresh(session, _payload, refreshed), do: replace(session, session.user_id, refreshed)

  defp redact(response, cookies) do
    values =
      for cookie <- cookies,
          value = cookie["value"],
          value != "" and (Map.get(cookie, "httpOnly", true) or byte_size(value) >= 8),
          do: value

    %{
      response
      | body: String.replace(response.body, values, "[secret]"),
        headers:
          Map.new(response.headers, fn {key, value} ->
            {key, String.replace(value, values, "[secret]")}
          end)
    }
  end

  defp unseal(%Session{sealed: nil}), do: {:error, :reauthorize}

  defp unseal(session) do
    with {:ok, json} <-
           Plug.Crypto.MessageEncryptor.decrypt(
             session.sealed,
             bound(session),
             key("session"),
             key("signing")
           ),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, payload} <- payload(decoded) do
      {:ok, payload}
    else
      _invalid -> {:error, :reauthorize}
    end
  end

  defp bound(session), do: session.vault_id <> ":" <> session.connection_id

  defp key(salt) do
    base = Application.fetch_env!(:babel_sync, BabelSyncWeb.Endpoint)[:secret_key_base]
    Plug.Crypto.KeyGenerator.generate(base, "connector " <> salt, length: 32, cache: Plug.Keys)
  end

  defp headers?(headers) when is_map(headers) do
    Enum.all?(headers, fn {name, value} ->
      is_binary(name) and is_binary(value) and
        Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name) and
        not String.contains?(value, ["\r", "\n", "\0"])
    end)
  end

  defp headers?(_headers), do: false

  defp fetch(payload, asked, options) do
    cookies = payload["cookies"]

    with {:ok, uri} <- address(asked[:url], payload["hosts"]),
         true <- Map.get(asked, :method, "GET") == "GET",
         true <- headers?(asked[:headers] || %{}),
         header when header != "" <- Cookies.header(cookies, URI.to_string(uri)) do
      headers =
        (asked[:headers] || %{})
        |> Map.new(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
        |> Map.drop(["host", "authorization", "cookie", "content-length", "transfer-encoding"])
        |> Map.merge(%{"cookie" => header, "user-agent" => payload["user_agent"]})

      request =
        Req.new(
          url: uri,
          headers: headers,
          adapter: Application.get_env(:babel_sync, :connector_adapter, Pinned),
          redirect: false,
          retry: false,
          decode_body: false,
          receive_timeout: 20_000
        )
        |> Req.Request.register_options([:pinned_most])
        |> Req.Request.merge_options(pinned_most: Keyword.get(options, :most, 5_000_000))

      case Req.request(request) do
        {:ok, %{status: status}} when status in [401, 403] ->
          {:error, :reauthorize}

        {:ok, response} ->
          updated =
            Cookies.receive_cookies(
              cookies,
              Req.Response.get_header(response, "set-cookie"),
              URI.to_string(uri)
            )

          answer = %{
            status: response.status,
            url: URI.to_string(uri),
            body: response.body,
            headers:
              Map.new(Map.drop(response.headers, ["set-cookie"]), fn {key, value} ->
                {key, Enum.join(value, ", ")}
              end)
          }

          {:ok, answer, %{payload | "cookies" => updated}}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      "" -> {:error, :reauthorize}
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
    end
  end
end
