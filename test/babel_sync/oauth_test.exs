defmodule BabelSync.OAuthTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures
  import Ecto.Query

  alias BabelSync.Accounts.Scope
  alias BabelSync.OAuth
  alias BabelSync.OAuth.Client

  @verifier "a-verifier-that-is-long-enough-to-be-plausible-0123456789"
  @redirect "obsidian://babelsync"

  defp challenge, do: Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)

  defp client(redirect_uris \\ [@redirect]) do
    {:ok, client} =
      OAuth.register_client(%{name: "Obsidian on Laptop", redirect_uris: redirect_uris})

    client
  end

  defp params(client, extra \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "response_type" => "code",
        "state" => "xyz",
        "code_challenge" => challenge(),
        "code_challenge_method" => "S256"
      },
      extra
    )
  end

  defp code_for(client, user, extra \\ %{}) do
    {:ok, request} = OAuth.request(params(client, extra))
    destination = OAuth.approve(request, Scope.for_user(user))

    %{"code" => code, "state" => "xyz"} =
      destination |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    code
  end

  defp exchange(client, code, extra \\ %{}) do
    OAuth.token(
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "code_verifier" => @verifier
        },
        extra
      )
    )
  end

  describe "client registration" do
    test "accepts https, loopback http and app schemes" do
      for uri <- [
            "https://app.example/cb",
            "http://127.0.0.1:8123/cb",
            "http://localhost/cb",
            "com.example.app:/cb",
            @redirect
          ] do
        assert Client.redirect_uri?(uri), uri
      end
    end

    test "rejects plain http elsewhere, script schemes and fragments" do
      for uri <- [
            "http://example.com/cb",
            "javascript:alert(1)",
            "data:text/html,x",
            "https://a.example/#x",
            "ms-msdt:/id",
            "tel:5551234",
            "smb://files.example/share",
            "https://app.example/" <> String.duplicate("a", 2000),
            "nope"
          ] do
        refute Client.redirect_uri?(uri), uri
      end

      assert {:error, _changeset} = OAuth.register_client(%{name: "x", redirect_uris: []})
    end

    test "a registration nobody approved is forgotten after a day, an approved one is kept" do
      approved = client()
      code_for(approved, user())
      forgotten = client()
      recent = client()

      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)

      BabelSync.Repo.update_all(
        from(c in Client, where: c.id in ^[approved.id, forgotten.id]),
        set: [inserted_at: two_days_ago]
      )

      assert :ok = OAuth.prune()
      assert OAuth.get_client(approved.id)
      assert OAuth.get_client(recent.id)
      refute OAuth.get_client(forgotten.id)
    end

    test "only the newest unapproved registrations are kept" do
      settings = Application.fetch_env!(:babel_sync, OAuth)
      Application.put_env(:babel_sync, OAuth, Keyword.put(settings, :unapproved_clients, 2))
      on_exit(fn -> Application.put_env(:babel_sync, OAuth, settings) end)

      approved = client()
      code_for(approved, user())
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      BabelSync.Repo.update_all(Client, set: [inserted_at: long_ago])

      oldest = client()

      BabelSync.Repo.update_all(from(c in Client, where: c.id == ^oldest.id),
        set: [inserted_at: DateTime.add(long_ago, 60, :second)]
      )

      kept = [client(), client()]

      assert OAuth.get_client(approved.id)
      refute OAuth.get_client(oldest.id)
      assert Enum.all?(kept, &OAuth.get_client(&1.id))
    end
  end

  describe "authorization requests" do
    test "an unknown client or unregistered redirect is refused without redirecting" do
      assert {:error, :unknown_client} = OAuth.request(%{"client_id" => Ecto.UUID.generate()})
      assert {:error, :unknown_client} = OAuth.request(%{"client_id" => "not-a-uuid"})

      assert {:error, :bad_redirect_uri} =
               OAuth.request(params(client(), %{"redirect_uri" => "https://evil.example/cb"}))
    end

    test "a loopback redirect may use any port" do
      client = client(["http://127.0.0.1/callback"])

      assert {:ok, request} =
               OAuth.request(
                 params(client, %{"redirect_uri" => "http://127.0.0.1:53211/callback"})
               )

      assert request.redirect_uri == "http://127.0.0.1:53211/callback"

      assert {:error, :bad_redirect_uri} =
               OAuth.request(params(client, %{"redirect_uri" => "http://127.0.0.1:53211/other"}))
    end

    test "a request without PKCE is sent back with an error once the app has been approved" do
      client = client()

      assert {:error, :malformed_request} =
               OAuth.request(params(client, %{"code_challenge_method" => "plain"}))

      code_for(client, user())

      assert {:error, {:redirect, @redirect, query}} =
               OAuth.request(
                 params(OAuth.get_client(client.id), %{"code_challenge_method" => "plain"})
               )

      assert query == [error: "invalid_request", state: "xyz"]
    end

    test "denying sends the user back with access_denied" do
      {:ok, request} = OAuth.request(params(client()))
      assert OAuth.deny(request) == "obsidian://babelsync?error=access_denied&state=xyz"
    end
  end

  describe "tokens" do
    setup do
      %{user: user(), client: client()}
    end

    test "a code is exchanged once for tokens that identify the user", %{
      user: user,
      client: client
    } do
      code = code_for(client, user)

      assert {:ok,
              %{
                access_token: access,
                refresh_token: _refresh,
                token_type: "Bearer",
                scope: "vault"
              }} =
               exchange(client, code)

      assert {:ok, %Scope{user: %{id: id}, read_only: false}} =
               OAuth.scope_from_access_token(access)

      assert id == user.id
      assert {:error, "invalid_grant"} = exchange(client, code)
    end

    test "the wrong verifier, client or redirect is refused", %{user: user, client: client} do
      assert {:error, "invalid_grant"} =
               exchange(client, code_for(client, user), %{"code_verifier" => "something-else"})

      assert {:error, "invalid_grant"} =
               exchange(client, code_for(client, user), %{"client_id" => client().id})

      assert {:error, "invalid_grant"} =
               exchange(client, code_for(client, user), %{"redirect_uri" => "obsidian://other"})
    end

    test "asking for vault:read gives a read-only scope", %{user: user, client: client} do
      code = code_for(client, user, %{"scope" => "vault:read"})
      assert {:ok, %{access_token: access, scope: "vault:read"}} = exchange(client, code)
      assert {:ok, %Scope{read_only: true}} = OAuth.scope_from_access_token(access)
    end

    test "refreshing rotates both tokens, and asking again with the same token gives the same pair",
         %{
           user: user,
           client: client
         } do
      {:ok, first} = exchange(client, code_for(client, user))

      refresh = fn token ->
        OAuth.token(%{
          "grant_type" => "refresh_token",
          "refresh_token" => token,
          "client_id" => client.id
        })
      end

      assert {:ok, second} = refresh.(first.refresh_token)
      assert :error = OAuth.scope_from_access_token(first.access_token)
      assert {:ok, _scope} = OAuth.scope_from_access_token(second.access_token)

      for _again <- 1..3 do
        assert {:ok, repeat} = refresh.(first.refresh_token)
        assert repeat.access_token == second.access_token
        assert repeat.refresh_token == second.refresh_token
      end

      assert {:ok, _scope} = OAuth.scope_from_access_token(second.access_token)

      assert {:ok, third} = refresh.(second.refresh_token)
      assert third.refresh_token != second.refresh_token
      assert {:ok, _scope} = OAuth.scope_from_access_token(third.access_token)
      assert {:error, "invalid_grant"} = refresh.(first.refresh_token)
      assert {:error, "invalid_grant"} = refresh.("bsr_unknown")
    end

    test "several refreshes at the same moment all receive the tokens that stay valid", %{
      user: user,
      client: client
    } do
      {:ok, first} = exchange(client, code_for(client, user))

      replies =
        1..6
        |> Task.async_stream(
          fn _n ->
            OAuth.token(%{
              "grant_type" => "refresh_token",
              "refresh_token" => first.refresh_token,
              "client_id" => client.id
            })
          end,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, {:ok, tokens}} -> tokens.refresh_token end)

      assert [kept] = Enum.uniq(replies)

      assert {:ok, _next} =
               OAuth.token(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => kept,
                 "client_id" => client.id
               })
    end

    test "a grant can be listed and revoked", %{user: user, client: client} do
      {:ok, tokens} = exchange(client, code_for(client, user))
      assert [grant] = OAuth.list_grants(user)
      assert grant.client.name == "Obsidian on Laptop"

      assert :ok = OAuth.revoke_grant(user(), grant.id)
      assert {:ok, _scope} = OAuth.scope_from_access_token(tokens.access_token)

      assert :ok = OAuth.revoke_grant(user, grant.id)
      assert :error = OAuth.scope_from_access_token(tokens.access_token)
      assert [] = OAuth.list_grants(user)
    end

    test "revoking by token drops the grant", %{user: user, client: client} do
      {:ok, tokens} = exchange(client, code_for(client, user))
      assert :ok = OAuth.revoke_token(tokens.refresh_token)
      assert :error = OAuth.scope_from_access_token(tokens.access_token)
    end
  end

  describe "less common requests" do
    test "a client with one redirect address may leave it out, and state is optional" do
      client = client()
      params = client |> params() |> Map.drop(["redirect_uri", "state"])

      assert {:ok, request} = OAuth.request(params)
      assert request.redirect_uri == @redirect
      assert OAuth.deny(request) == "obsidian://babelsync?error=access_denied"

      destination = OAuth.approve(request, Scope.for_user(user()))

      assert %{"code" => "bsc_" <> _code} =
               destination |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      refute destination =~ "state="
    end

    test "a client with several redirect addresses must say which" do
      client = client([@redirect, "https://app.example/cb"])

      assert {:error, :bad_redirect_uri} =
               OAuth.request(client |> params() |> Map.delete("redirect_uri"))

      assert {:error, :unknown_client} = OAuth.request(%{})
    end

    test "anything but the code flow is sent back as unsupported" do
      client = client()
      code_for(client, user())

      assert {:error, {:redirect, @redirect, [error: "unsupported_response_type", state: "xyz"]}} =
               OAuth.request(params(client, %{"response_type" => "token"}))
    end

    test "a redirect address that already has a query keeps it" do
      client = client(["https://app.example/cb?tenant=a"])
      {:ok, request} = OAuth.request(params(client))
      assert OAuth.deny(request) =~ "tenant=a"
      assert OAuth.deny(request) =~ "error=access_denied"
    end

    test "a read-only session cannot mint a read-write token" do
      user = user()
      client = client()
      {:ok, request} = OAuth.request(params(client))
      destination = OAuth.approve(request, Scope.for_user(user, read_only: true))
      %{"code" => code} = destination |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, %{scope: "vault:read", access_token: access}} = exchange(client, code)
      assert {:ok, %Scope{read_only: true}} = OAuth.scope_from_access_token(access)
    end

    test "an expired code or access token is worthless, and expired codes are pruned" do
      user = user()
      client = client()
      code = code_for(client, user)
      past = DateTime.add(DateTime.utc_now(), -10, :second)
      BabelSync.Repo.update_all(OAuth.Code, set: [expires_at: past])
      assert :ok = OAuth.prune()
      assert BabelSync.Repo.aggregate(OAuth.Code, :count) == 0
      assert {:error, "invalid_grant"} = exchange(client, code)

      {:ok, tokens} = exchange(client, code_for(client, user))
      BabelSync.Repo.update_all(OAuth.Grant, set: [access_expires_at: past])
      assert :error = OAuth.scope_from_access_token(tokens.access_token)

      assert {:error, "invalid_request"} = OAuth.token(%{})
      assert {:error, "invalid_grant"} = OAuth.token(%{"grant_type" => "authorization_code"})
      assert :ok = OAuth.revoke_token("bsr_unknown")
    end

    test "a refresh token from before the grace period is dead, and one from another client is refused" do
      user = user()
      client = client()
      {:ok, first} = exchange(client, code_for(client, user))

      refresh =
        &OAuth.token(%{"grant_type" => "refresh_token", "refresh_token" => &1, "client_id" => &2})

      assert {:error, "invalid_grant"} = refresh.(first.refresh_token, client().id)
      assert {:ok, _second} = refresh.(first.refresh_token, client.id)

      BabelSync.Repo.update_all(OAuth.Grant,
        set: [rotated_at: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

      assert {:error, "invalid_grant"} = refresh.(first.refresh_token, client.id)
    end
  end
end
