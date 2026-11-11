defmodule BabelSyncWeb.Auth.OIDCTest do
  use BabelSyncWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BabelSync.Accounts
  alias BabelSync.Auth.OIDC
  alias BabelSync.FakeIdP

  defp provider(claims, settings \\ []) do
    {server, issuer} = FakeIdP.start(claims)
    previous = Application.fetch_env!(:babel_sync, OIDC)

    Application.put_env(
      :babel_sync,
      OIDC,
      Keyword.merge(
        previous,
        [issuer: issuer, client_id: "babelsync", client_secret: "s3cret"] ++ settings
      )
    )

    start_supervised!(OIDC)

    on_exit(fn ->
      Application.put_env(:babel_sync, OIDC, previous)
      Process.exit(server, :normal)
    end)
  end

  defp multi do
    Application.put_env(:babel_sync, :mode, :multi)
    on_exit(fn -> Application.put_env(:babel_sync, :mode, :single) end)
    with_auth([:oidc])
  end

  defp round_trip(conn) do
    started = get(conn, ~p"/login/oidc")
    answer = started |> redirected_to() |> FakeIdP.approve()
    started |> recycle() |> get(~p"/login/oidc/callback", answer)
  end

  test "a first sign-in creates the account and later ones find it", %{conn: conn} do
    multi()

    provider(%{
      "sub" => "u-1",
      "email" => "Grace@Example.com",
      "email_verified" => true,
      "name" => "Grace"
    })

    {:ok, view, _html} = live(conn, ~p"/login")
    assert has_element?(view, "#oidc-sign-in")

    signed_in = round_trip(conn)
    assert redirected_to(signed_in) == "/"
    assert %Accounts.User{id: id, name: "Grace"} = Accounts.get_user_by_email("grace@example.com")

    {:ok, account, _html} = signed_in |> recycle() |> live(~p"/account")
    assert render(account) =~ "grace@example.com"

    assert redirected_to(round_trip(conn)) == "/"
    assert [%{id: ^id}] = BabelSync.Repo.all(Accounts.User)
  end

  test "an unverified email is not used to find an existing account", %{conn: conn} do
    multi()
    existing = BabelSync.Fixtures.user(%{email: "grace@example.com"})
    provider(%{"sub" => "u-2", "email" => "grace@example.com", "email_verified" => false})

    assert redirected_to(round_trip(conn)) == "/"

    assert [_existing, stranger] =
             BabelSync.Repo.all(Accounts.User) |> Enum.sort_by(&(&1.id != existing.id))

    assert stranger.email == nil
  end

  test "a single-user server only admits the required identity", %{conn: conn} do
    with_auth([:oidc])

    provider(%{"sub" => "u-3", "email" => "owner@example.com"},
      require: [{"email", "owner@example.com"}]
    )

    signed_in = round_trip(conn)
    assert redirected_to(signed_in) == "/"
    assert {:ok, _view, _html} = signed_in |> recycle() |> live(~p"/")
    assert [_owner] = BabelSync.Repo.all(Accounts.User)
  end

  test "anyone else at the provider is turned away", %{conn: conn} do
    with_auth([:oidc])

    provider(%{"sub" => "u-4", "email" => "other@example.com"},
      require: [{"email", "owner@example.com"}]
    )

    refused = round_trip(conn)
    assert redirected_to(refused) == "/login"
    assert {:error, {:redirect, %{to: "/login"}}} = refused |> recycle() |> live(~p"/")
  end

  test "a callback with the wrong state is refused", %{conn: conn} do
    multi()
    provider(%{"sub" => "u-5"})

    started = get(conn, ~p"/login/oidc")
    answer = started |> redirected_to() |> FakeIdP.approve()

    forged =
      started |> recycle() |> get(~p"/login/oidc/callback", %{answer | "state" => "forged"})

    assert redirected_to(forged) == "/login"
  end
end
