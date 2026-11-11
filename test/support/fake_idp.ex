defmodule BabelSync.FakeIdP do
  @moduledoc """
  A tiny OpenID Connect provider for tests. It approves every request
  and hands out an ID token carrying whatever claims the test set.
  """

  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded]
  plug :dispatch

  @table __MODULE__

  def start(claims) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public])
      :ets.insert(@table, {:key, JOSE.JWK.generate_key({:rsa, 2048})})
    end

    {:ok, server} =
      Bandit.start_link(plug: __MODULE__, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    issuer = "http://localhost:#{port}"
    :ets.insert(@table, [{:issuer, issuer}, {:claims, claims}, {:nonces, %{}}])
    {server, issuer}
  end

  def approve(authorize_url) do
    query = authorize_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    code = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    :ets.insert(@table, {:nonces, Map.put(lookup(:nonces), code, query)})
    %{"code" => code, "state" => query["state"]}
  end

  get "/.well-known/openid-configuration" do
    issuer = lookup(:issuer)

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/authorize",
      token_endpoint: issuer <> "/token",
      jwks_uri: issuer <> "/jwks",
      response_types_supported: ["code"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      scopes_supported: ["openid", "email", "profile"],
      grant_types_supported: ["authorization_code"],
      token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
      code_challenge_methods_supported: ["S256"]
    })
  end

  get "/jwks" do
    {_kind, public} = lookup(:key) |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    json(conn, %{keys: [Map.merge(public, %{"kid" => "test", "use" => "sig", "alg" => "RS256"})]})
  end

  post "/token" do
    request = Map.fetch!(lookup(:nonces), conn.body_params["code"])
    verifier = conn.body_params["code_verifier"]
    expected = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    ^expected = request["code_challenge"]

    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => lookup(:issuer),
          "aud" => request["client_id"],
          "nonce" => request["nonce"],
          "iat" => now,
          "exp" => now + 300
        },
        lookup(:claims)
      )

    {_meta, id_token} =
      lookup(:key)
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test"}, claims)
      |> JOSE.JWS.compact()

    json(conn, %{
      access_token: "idp-access",
      token_type: "Bearer",
      expires_in: 300,
      id_token: id_token
    })
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp lookup(key), do: :ets.lookup_element(@table, key, 2)
end
