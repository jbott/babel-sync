defmodule BabelSync.OAuth do
  @moduledoc """
  A small OAuth 2.1 authorization server for the apps that act for a
  user: the Obsidian plugin on each device, and agents that connect over
  MCP. Clients are public, register themselves, and use the authorization
  code flow with PKCE. Each approval is a grant the user can revoke.
  """

  import Ecto.Query

  alias BabelSync.Accounts.{Scope, User}
  alias BabelSync.OAuth.{Client, Code, Grant, Request}
  alias BabelSync.Repo

  @access_prefix "bsa_"
  @refresh_prefix "bsr_"
  @code_prefix "bsc_"

  @code_lifetime 300
  @access_lifetime 3600
  @rotation_grace 120
  @full_scope "vault"
  @read_scope "vault:read"

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          scope: String.t()
        }

  @spec scopes() :: [String.t()]
  def scopes, do: [@full_scope, @read_scope]

  @spec access_token?(String.t()) :: boolean()
  def access_token?(token), do: String.starts_with?(token, @access_prefix)

  @spec register_client(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def register_client(attrs) do
    %Client{} |> Client.changeset(attrs) |> Repo.insert()
  end

  @spec get_client(String.t()) :: Client.t() | nil
  def get_client(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Client, uuid)
      :error -> nil
    end
  end

  @spec request(map()) ::
          {:ok, Request.t()}
          | {:error, :unknown_client | :bad_redirect_uri}
          | {:error, {:redirect, String.t(), keyword()}}
  def request(params) do
    with {:ok, client} <- fetch_client(params["client_id"]),
         {:ok, redirect_uri} <- fetch_redirect_uri(client, params["redirect_uri"]) do
      state = params["state"]

      cond do
        params["response_type"] != "code" ->
          {:error, {:redirect, redirect_uri, error_query("unsupported_response_type", state)}}

        params["code_challenge_method"] != "S256" or params["code_challenge"] in [nil, ""] ->
          {:error, {:redirect, redirect_uri, error_query("invalid_request", state)}}

        true ->
          {:ok,
           %Request{
             client: client,
             redirect_uri: redirect_uri,
             state: state,
             challenge: params["code_challenge"],
             read_only: read_only?(params["scope"])
           }}
      end
    end
  end

  @spec approve(Request.t(), Scope.t()) :: String.t()
  def approve(%Request{} = request, %Scope{user: user, read_only: scope_read_only}) do
    code = secret(@code_prefix)

    Repo.insert!(%Code{
      client_id: request.client.id,
      user_id: user.id,
      code_hash: digest(code),
      redirect_uri: request.redirect_uri,
      challenge: request.challenge,
      read_only: request.read_only or scope_read_only,
      expires_at: after_seconds(@code_lifetime)
    })

    redirect_to(request.redirect_uri, success_query(code, request.state))
  end

  @spec deny(Request.t()) :: String.t()
  def deny(%Request{} = request) do
    redirect_to(request.redirect_uri, error_query("access_denied", request.state))
  end

  @spec redirect_to(String.t(), keyword()) :: String.t()
  def redirect_to(redirect_uri, query) do
    uri = URI.parse(redirect_uri)
    existing = URI.decode_query(uri.query || "")
    merged = Map.merge(existing, Map.new(query, fn {key, value} -> {to_string(key), value} end))
    URI.to_string(%{uri | query: URI.encode_query(merged)})
  end

  @spec token(map()) :: {:ok, tokens()} | {:error, String.t()}
  def token(%{"grant_type" => "authorization_code"} = params) do
    with code when is_binary(code) <- params["code"],
         verifier when is_binary(verifier) <- params["code_verifier"],
         %Code{} = stored <- take_code(code),
         true <- stored.client_id == params["client_id"],
         true <- stored.redirect_uri == params["redirect_uri"],
         true <- DateTime.compare(stored.expires_at, DateTime.utc_now()) == :gt,
         true <- Plug.Crypto.secure_compare(challenge(verifier), stored.challenge) do
      {:ok, issue(stored)}
    else
      _invalid -> {:error, "invalid_grant"}
    end
  end

  def token(%{"grant_type" => "refresh_token", "refresh_token" => refresh} = params)
      when is_binary(refresh) do
    hash = digest(refresh)
    grace = DateTime.add(DateTime.utc_now(), -@rotation_grace, :second)

    grant =
      Repo.one(
        from g in Grant,
          where:
            g.refresh_hash == ^hash or
              (g.previous_refresh_hash == ^hash and g.rotated_at > ^grace)
      )

    client_id = params["client_id"]

    case grant do
      %Grant{client_id: ^client_id} -> {:ok, rotate(grant)}
      _invalid -> {:error, "invalid_grant"}
    end
  end

  def token(%{"grant_type" => _other}), do: {:error, "unsupported_grant_type"}
  def token(_params), do: {:error, "invalid_request"}

  @spec revoke_token(String.t()) :: :ok
  def revoke_token(token) do
    hash = digest(token)

    from(g in Grant, where: g.access_hash == ^hash or g.refresh_hash == ^hash)
    |> Repo.all()
    |> Enum.each(&drop/1)
  end

  @spec scope_from_access_token(String.t()) :: {:ok, Scope.t()} | :error
  def scope_from_access_token(token) do
    hash = digest(token)
    now = DateTime.utc_now()

    grant =
      Repo.one(
        from g in Grant,
          where: g.access_hash == ^hash and g.access_expires_at > ^now,
          preload: :user
      )

    case grant do
      %Grant{user: %User{} = user, read_only: read_only} ->
        {:ok, Scope.for_user(user, read_only: read_only)}

      nil ->
        :error
    end
  end

  @spec list_grants(User.t()) :: [Grant.t()]
  def list_grants(%User{id: user_id}) do
    Repo.all(
      from g in Grant,
        where: g.user_id == ^user_id,
        order_by: [desc: g.last_used_at],
        preload: :client
    )
  end

  @spec revoke_grant(User.t(), Ecto.UUID.t()) :: :ok
  def revoke_grant(%User{id: user_id}, grant_id) do
    case Repo.get_by(Grant, id: grant_id, user_id: user_id) do
      %Grant{} = grant -> drop(grant)
      nil -> :ok
    end
  end

  @spec prune(DateTime.t()) :: :ok
  def prune(now \\ DateTime.utc_now()) do
    Repo.delete_all(from c in Code, where: c.expires_at < ^now)
    :ok
  end

  defp drop(%Grant{} = grant) do
    Repo.delete!(grant)
    BabelSyncWeb.Endpoint.broadcast("user_socket:" <> grant.user_id, "disconnect", %{})
    :ok
  end

  defp fetch_client(id) when is_binary(id) do
    case get_client(id) do
      %Client{} = client -> {:ok, client}
      nil -> {:error, :unknown_client}
    end
  end

  defp fetch_client(_missing), do: {:error, :unknown_client}

  defp fetch_redirect_uri(%Client{redirect_uris: [only]}, nil), do: {:ok, only}

  defp fetch_redirect_uri(%Client{redirect_uris: registered}, uri) when is_binary(uri) do
    if Enum.any?(registered, &same_redirect?(&1, uri)),
      do: {:ok, uri},
      else: {:error, :bad_redirect_uri}
  end

  defp fetch_redirect_uri(_client, _uri), do: {:error, :bad_redirect_uri}

  defp same_redirect?(registered, requested) when registered == requested, do: true

  defp same_redirect?(registered, requested) do
    with {:ok, known} <- URI.new(registered),
         {:ok, asked} <- URI.new(requested) do
      Client.loopback?(known) and Client.loopback?(asked) and
        %{known | port: nil, authority: nil} == %{asked | port: nil, authority: nil}
    else
      _invalid -> false
    end
  end

  defp read_only?(nil), do: false

  defp read_only?(scope) do
    requested = String.split(scope)
    @read_scope in requested and @full_scope not in requested
  end

  defp success_query(code, nil), do: [code: code]
  defp success_query(code, state), do: [code: code, state: state]

  defp error_query(error, nil), do: [error: error]
  defp error_query(error, state), do: [error: error, state: state]

  defp take_code(code) do
    hash = digest(code)

    case Repo.delete_all(from(c in Code, where: c.code_hash == ^hash, select: c)) do
      {1, [stored]} -> stored
      {0, _none} -> nil
    end
  end

  defp issue(%Code{} = code) do
    access = secret(@access_prefix)
    refresh = secret(@refresh_prefix)
    now = DateTime.utc_now()

    grant =
      Repo.insert!(%Grant{
        client_id: code.client_id,
        user_id: code.user_id,
        read_only: code.read_only,
        access_hash: digest(access),
        access_expires_at: after_seconds(@access_lifetime),
        refresh_hash: digest(refresh),
        last_used_at: now
      })

    response(grant, access, refresh)
  end

  defp rotate(%Grant{} = grant) do
    access = secret(@access_prefix)
    refresh = secret(@refresh_prefix)
    now = DateTime.utc_now()

    grant =
      grant
      |> Ecto.Changeset.change(
        access_hash: digest(access),
        access_expires_at: after_seconds(@access_lifetime),
        refresh_hash: digest(refresh),
        previous_refresh_hash: grant.refresh_hash,
        rotated_at: now,
        last_used_at: now
      )
      |> Repo.update!()

    response(grant, access, refresh)
  end

  defp response(%Grant{read_only: read_only}, access, refresh) do
    %{
      access_token: access,
      refresh_token: refresh,
      token_type: "Bearer",
      expires_in: @access_lifetime,
      scope: if(read_only, do: @read_scope, else: @full_scope)
    }
  end

  defp challenge(verifier) do
    Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
  end

  defp secret(prefix) do
    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp after_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
end
