defmodule BabelSyncWeb.OAuthController do
  use BabelSyncWeb, :controller

  alias BabelSync.OAuth
  alias BabelSync.OAuth.Request
  alias BabelSync.RateLimit
  alias BabelSyncWeb.ClientAddress
  alias BabelSyncWeb.SessionController

  @request_params ~w(client_id redirect_uri response_type state scope code_challenge code_challenge_method)
  @hour 3600

  plug :limit_registrations when action == :register
  plug BabelSyncWeb.Plugs.Limit, :token when action == :token

  def server_metadata(conn, _params) do
    issuer = BabelSyncWeb.Endpoint.url()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> ~p"/oauth/authorize",
      token_endpoint: issuer <> ~p"/oauth/token",
      registration_endpoint: issuer <> ~p"/oauth/register",
      revocation_endpoint: issuer <> ~p"/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: OAuth.scopes()
    })
  end

  def resource_metadata(conn, _params) do
    issuer = BabelSyncWeb.Endpoint.url()

    json(conn, %{
      resource: issuer <> "/mcp",
      authorization_servers: [issuer],
      scopes_supported: OAuth.scopes(),
      bearer_methods_supported: ["header"]
    })
  end

  def register(conn, params) do
    attrs = %{
      name: params["client_name"] || "Unnamed app",
      redirect_uris: params["redirect_uris"]
    }

    case OAuth.register_client(attrs) do
      {:ok, client} ->
        conn
        |> put_status(:created)
        |> json(%{
          client_id: client.id,
          client_name: client.name,
          redirect_uris: client.redirect_uris,
          token_endpoint_auth_method: "none",
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"]
        })

      {:error, _changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_redirect_uri",
          error_description:
            "redirect_uris must be 1 to 10 addresses of at most 2000 bytes: https, loopback http, or an app scheme"
        })
    end
  end

  def authorize(conn, params) do
    case OAuth.request(params) do
      {:ok, %Request{} = request} ->
        if conn.assigns.current_scope do
          render(conn, :consent,
            request: request,
            params: Map.take(params, @request_params),
            page_title: "Connect #{request.client.name}"
          )
        else
          conn
          |> put_session(SessionController.return_to_key(), current_path(conn))
          |> redirect(to: ~p"/login")
        end

      {:error, {:redirect, redirect_uri, query}} ->
        redirect(conn, external: OAuth.redirect_to(redirect_uri, query))

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> render(:invalid, reason: reason, page_title: "Cannot connect")
    end
  end

  def decide(conn, %{"decision" => decision} = params) do
    scope = conn.assigns.current_scope

    case OAuth.request(params) do
      {:ok, %Request{} = request} when not is_nil(scope) ->
        destination =
          if decision == "approve",
            do: OAuth.approve(request, scope),
            else: OAuth.deny(request)

        redirect(conn, external: destination)

      _invalid ->
        conn
        |> put_status(:bad_request)
        |> render(:invalid, reason: :unknown_client, page_title: "Cannot connect")
    end
  end

  defp limit_registrations(conn, _opts) do
    limit = Application.fetch_env!(:babel_sync, OAuth)[:registrations_per_hour]

    case RateLimit.hit({:register, ClientAddress.of(conn)}, limit, @hour) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{
          error: "too_many_requests",
          error_description: "Too many apps were registered from this address. Try again later."
        })
        |> halt()
    end
  end

  def token(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case OAuth.token(params) do
      {:ok, tokens} -> json(conn, tokens)
      {:error, error} -> conn |> put_status(:bad_request) |> json(%{error: error})
    end
  end

  def revoke(conn, params) do
    if is_binary(params["token"]), do: OAuth.revoke_token(params["token"])
    send_resp(conn, :ok, "")
  end
end
