defmodule BabelSyncWeb.Auth.LoginTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias BabelSync.Accounts
  alias BabelSync.Auth
  alias BabelSync.Auth.{Passkeys, Setup}
  alias BabelSync.TestAuthenticator

  defp with_mode(mode) do
    Application.put_env(:babel_sync, :mode, mode)
    on_exit(fn -> Application.put_env(:babel_sync, :mode, :single) end)
  end

  defp with_allowed(emails) do
    previous = Application.fetch_env!(:babel_sync, Auth.MagicLink)

    Application.put_env(
      :babel_sync,
      Auth.MagicLink,
      Keyword.put(previous, :allowed_emails, emails)
    )

    on_exit(fn -> Application.put_env(:babel_sync, Auth.MagicLink, previous) end)
  end

  defp link_token do
    assert_email_sent(fn email ->
      [_all, token] = Regex.run(~r{/login/link/([\w-]+)}, email.text_body)
      send(self(), {:token, token})
    end)

    assert_received {:token, token}
    token
  end

  test "with sign-in disabled the login page leads straight in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/login")
  end

  test "only the enabled methods are offered", %{conn: conn} do
    with_mode(:multi)
    with_auth([:magic_link])

    {:ok, view, _html} = live(conn, ~p"/login")
    assert has_element?(view, "#link-form")
    refute has_element?(view, "#passkey-sign-in")
    refute has_element?(view, "#oidc-sign-in")
  end

  test "the sign-in page shows what the product does around the sign-in card", %{conn: conn} do
    with_mode(:multi)
    with_auth([:magic_link])

    {:ok, front, _html} = live(conn, ~p"/")
    assert has_element?(front, "#landing #sign-in #link-form")

    {:ok, view, _html} = live(conn, ~p"/login")
    assert has_element?(view, "#landing #sign-in #link-form")
    assert has_element?(view, "#header-log-in")
    assert has_element?(view, "#landing-editing #landing-desktop img")
    assert has_element?(view, "#landing-editing #landing-phone")
    assert has_element?(view, "#landing-devices #landing-settings-phone img")
    assert has_element?(view, "#landing-more")
  end

  test "a link that cannot be used shows only the card", %{conn: conn} do
    with_mode(:multi)
    with_auth([:magic_link])

    {:ok, view, _html} = live(conn, ~p"/login/link/nonsense")
    assert has_element?(view, "#sign-in #link-expired")
    refute has_element?(view, "#landing")
  end

  describe "magic link" do
    setup do
      with_mode(:multi)
      with_auth([:magic_link])
    end

    test "a known address receives a link that signs in once", %{conn: conn} do
      user = user(%{email: "ada@example.com"})

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> form("#link-form", link: %{email: " Ada@Example.com "}) |> render_submit()
      assert has_element?(view, "#link-sent")
      token = link_token()

      {:ok, confirm, _html} = live(conn, ~p"/login/link/#{token}")
      assert has_element?(confirm, "#link-confirm")

      signed_in = post(conn, ~p"/login/link", %{token: token})
      assert redirected_to(signed_in) == "/"

      {:ok, account, _html} = signed_in |> recycle() |> live(~p"/account")
      assert has_element?(account, "#sign-out")
      assert render(account) =~ user.email

      again = post(conn, ~p"/login/link", %{token: token})
      assert redirected_to(again) == "/login"
    end

    test "an unknown address gets the same answer but no mail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login")
      view |> form("#link-form", link: %{email: "stranger@example.com"}) |> render_submit()
      assert has_element?(view, "#link-sent")
      assert_no_email_sent()
      refute Accounts.get_user_by_email("stranger@example.com")
    end

    test "an allowed domain lets a new person in", %{conn: conn} do
      with_allowed(["*@example.org"])

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> form("#link-form", link: %{email: "new@example.org"}) |> render_submit()

      conn |> post(~p"/login/link", %{token: link_token()}) |> redirected_to()
      assert %Accounts.User{} = Accounts.get_user_by_email("new@example.org")
    end

    test "a stale link says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login/link/nonsense")
      assert has_element?(view, "#link-expired")
    end
  end

  describe "passkey on a single-user server" do
    setup do
      with_auth([:passkey])
    end

    test "the first passkey needs the setup code, then signs in", %{conn: conn} do
      {:ok, locked, _html} = live(conn, ~p"/login")
      assert has_element?(locked, "#setup-locked")
      render_hook(locked, "passkey_options", %{})
      assert_reply locked, reply
      assert reply == %{}

      {:ok, setup, _html} = live(conn, ~p"/login?setup=#{Setup.code()}")
      assert has_element?(setup, "#passkey-setup")

      authenticator = TestAuthenticator.new()
      origin = BabelSyncWeb.Endpoint.url()

      render_hook(setup, "passkey_options", %{})
      assert_reply setup, %{create: options}

      render_hook(
        setup,
        "passkey_result",
        TestAuthenticator.attest(authenticator, options, origin)
      )

      {path, _flash} = assert_redirect(setup)
      assert redirected_to(get(conn, path)) == "/"
      assert Passkeys.any?()

      {:ok, relocked, _html} = live(conn, ~p"/login?setup=#{Setup.code()}")
      refute has_element?(relocked, "#passkey-setup")
      assert has_element?(relocked, "#passkey-sign-in")

      render_hook(relocked, "passkey_options", %{})
      assert_reply relocked, %{get: options}
      {_authenticator, response} = TestAuthenticator.assert(authenticator, options, origin)
      render_hook(relocked, "passkey_result", response)
      {path, _flash} = assert_redirect(relocked)

      signed_in = get(conn, path)
      assert redirected_to(signed_in) == "/"
      assert {:ok, _view, _html} = signed_in |> recycle() |> live(~p"/account")
    end

    test "pages need a session and signing out ends it", %{conn: conn} do
      {:ok, stranger, _html} = live(conn, ~p"/")
      assert has_element?(stranger, "#sign-in")
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/account")

      conn = sign_in(conn, Accounts.single_user!())
      assert {:ok, _view, _html} = live(conn, ~p"/account")

      signed_out = delete(conn, ~p"/logout")
      assert redirected_to(signed_out) == "/login"

      assert {:error, {:redirect, %{to: "/login"}}} =
               signed_out |> recycle() |> live(~p"/account")
    end

    test "a handoff token cannot be forged", %{conn: conn} do
      assert conn |> get(~p"/login/complete?token=made-up") |> redirected_to() == "/login"
    end

    test "a signed-in user adds and removes passkeys on the account page", %{conn: conn} do
      owner = Accounts.single_user!()
      {:ok, view, _html} = conn |> sign_in(owner) |> live(~p"/account")

      for name <- ["Laptop", "Phone"] do
        render_hook(view, "passkey_options", %{})
        assert_reply view, %{create: options}

        attested =
          TestAuthenticator.attest(TestAuthenticator.new(), options, BabelSyncWeb.Endpoint.url())

        render_hook(view, "passkey_result", Map.put(attested, "name", name))
      end

      assert [laptop, phone] = Passkeys.list(owner)
      assert has_element?(view, "#passkey-#{laptop.id}", "Laptop")

      view |> element("#passkey-#{phone.id} button") |> render_click()
      assert [_laptop] = Passkeys.list(owner)
      refute has_element?(view, "#passkey-#{laptop.id} button")
    end
  end

  describe "less common paths" do
    test "allowed addresses can be exact or anyone, and nonsense is ignored", %{conn: conn} do
      with_mode(:multi)
      with_auth([:magic_link])
      with_allowed(["boss@example.com"])

      assert Auth.MagicLink.permitted?("boss@example.com")
      refute Auth.MagicLink.permitted?("other@example.com")
      refute Auth.MagicLink.permitted?("not an address")

      with_allowed(["*"])
      assert Auth.MagicLink.permitted?("anyone@anywhere.test")

      {:ok, view, _html} = live(conn, ~p"/login")
      render_submit(view, "request_link", %{"link" => %{"email" => "not an address"}})
      assert_no_email_sent()
    end

    test "on a single-user server a link goes only to the allowed address and signs in the owner",
         %{conn: conn} do
      with_auth([:magic_link])
      with_allowed(["me@example.com"])
      owner = Accounts.single_user!()

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> form("#link-form", link: %{email: "intruder@example.com"}) |> render_submit()
      assert_no_email_sent()

      {:ok, view, _html} = live(conn, ~p"/login")
      view |> form("#link-form", link: %{email: "me@example.com"}) |> render_submit()
      signed_in = post(conn, ~p"/login/link", %{token: link_token()})
      assert redirected_to(signed_in) == "/"
      assert [%{id: id}] = BabelSync.Repo.all(Accounts.User)
      assert id == owner.id
    end

    test "expired links are pruned and cannot be used", %{conn: conn} do
      with_mode(:multi)
      with_auth([:magic_link])
      user(%{email: "ada@example.com"})
      :ok = Auth.MagicLink.request("ada@example.com", &("http://x/login/link/" <> &1))
      token = link_token()

      BabelSync.Repo.update_all(Auth.LoginLink,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert :error = Auth.MagicLink.peek(token)
      assert conn |> post(~p"/login/link", %{token: token}) |> redirected_to() == "/login"
      assert :ok = Auth.MagicLink.prune()
      assert BabelSync.Repo.aggregate(Auth.LoginLink, :count) == 0
    end

    test "methods that are switched off cannot be used through their addresses", %{conn: conn} do
      with_auth([:passkey])
      owner = Accounts.single_user!()

      assert conn |> get(~p"/login/oidc") |> redirected_to() == "/login"

      assert conn |> get(~p"/login/oidc/callback", %{code: "x", state: "y"}) |> redirected_to() ==
               "/login"

      assert conn |> get(~p"/login/oidc/callback", %{error: "access_denied"}) |> redirected_to() ==
               "/login"

      assert conn |> post(~p"/login/link", %{token: "whatever"}) |> redirected_to() == "/login"

      {:ok, view, _html} = live(conn, ~p"/login/link/whatever")
      assert has_element?(view, "#link-expired")

      conn = sign_in(conn, owner)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/login")
    end

    test "a tampered or stale session is treated as signed out", %{conn: conn} do
      with_auth([:passkey])

      forged =
        Plug.Test.init_test_session(conn, %{BabelSyncWeb.Plugs.Scope.session_key() => "forged"})

      assert {:error, {:redirect, %{to: "/login"}}} = live(forged, ~p"/account")

      ghost = %Accounts.User{id: Ecto.UUID.generate()}
      assert :error = Auth.scope_from_token(Auth.socket_token(Accounts.Scope.for_user(ghost)))
    end

    test "browsers are listed, and any of them can be signed out from another", %{conn: conn} do
      with_auth([:passkey])
      owner = user()
      here = sign_in(conn, owner)
      elsewhere = sign_in(conn, owner)
      third = sign_in(conn, owner)

      {:ok, account, _html} = live(here, ~p"/account")
      assert account |> element("#sessions") |> render() =~ "Firefox on Linux"

      assert [_this, other, _another] =
               Accounts.Sessions.list(owner) |> Enum.sort_by(& &1.inserted_at)

      assert has_element?(account, "#sessions li", "This browser")

      account |> element("#session-#{other.id} button") |> render_click()
      refute has_element?(account, "#session-#{other.id}")
      assert {:error, {:redirect, %{to: "/login"}}} = live(elsewhere, ~p"/account")
      assert {:ok, _view, _html} = live(third, ~p"/account")

      account |> element("#end-other-sessions") |> render_click()
      assert [_only] = Accounts.Sessions.list(owner)
      assert {:error, {:redirect, %{to: "/login"}}} = live(third, ~p"/account")
      assert {:ok, _view, _html} = live(here, ~p"/account")
    end

    test "signing out ends the session for good, and an old-style cookie is given a session", %{
      conn: conn
    } do
      with_auth([:passkey])
      owner = user()
      here = sign_in(conn, owner)

      assert here |> delete(~p"/logout") |> redirected_to() == ~p"/login"
      assert Accounts.Sessions.list(owner) == []
      assert {:error, {:redirect, %{to: "/login"}}} = live(here, ~p"/account")

      old = Phoenix.Token.sign(BabelSyncWeb.Endpoint, "session", owner.id)

      upgraded =
        conn
        |> Plug.Test.init_test_session(%{BabelSyncWeb.Plugs.Scope.session_key() => old})
        |> get(~p"/account")

      assert html_response(upgraded, 200)
      assert [session] = Accounts.Sessions.list(owner)

      assert {:ok, %{session_id: id}} =
               Auth.scope_from_session(
                 get_session(upgraded, BabelSyncWeb.Plugs.Scope.session_key())
               )

      assert id == session.id
    end

    test "a wrong or dismissed passkey is reported and signs nobody in", %{conn: conn} do
      with_auth([:passkey])
      owner = Accounts.single_user!()
      {challenge, options} = Passkeys.registration(owner)

      {:ok, _passkey} =
        Passkeys.register(
          owner,
          challenge,
          TestAuthenticator.attest(TestAuthenticator.new(), options, BabelSyncWeb.Endpoint.url()),
          ""
        )

      assert [%{name: "Passkey"}] = Passkeys.list(owner)

      {:ok, view, _html} = live(conn, ~p"/login")
      render_hook(view, "passkey_result", %{"id" => "early"})
      render_hook(view, "passkey_options", %{})
      assert_reply view, %{get: options}

      {_stranger, response} =
        TestAuthenticator.assert(TestAuthenticator.new(), options, BabelSyncWeb.Endpoint.url())

      assert render_hook(view, "passkey_result", response) =~ "not accepted"

      render_hook(view, "passkey_options", %{})
      assert render_hook(view, "passkey_failed", %{}) =~ "dismissed"
      assert render_hook(view, "passkey_result", %{}) =~ "dismissed"

      {challenge, _options} = Passkeys.authentication()
      assert {:error, :invalid} = Passkeys.authenticate(challenge, %{})
      assert {:error, :invalid} = Passkeys.register(owner, challenge, %{}, "x")
    end

    test "the account page saves a name and reports passkey problems", %{conn: conn} do
      with_auth([:passkey])
      owner = Accounts.single_user!()
      {:ok, view, _html} = conn |> sign_in(owner) |> live(~p"/account")

      view |> form("#profile-form", user: %{name: "Ada"}) |> render_submit()
      assert Accounts.get_user(owner.id).name == "Ada"
      view |> form("#profile-form", user: %{name: String.duplicate("x", 200)}) |> render_submit()
      assert Accounts.get_user(owner.id).name == "Ada"

      render_hook(view, "passkey_result", %{})
      render_hook(view, "passkey_options", %{})

      assert render_hook(view, "passkey_result", %{
               "attestationObject" => "AA",
               "clientDataJSON" => "AA"
             }) =~ "not accepted"

      assert render_hook(view, "passkey_failed", %{}) =~ "dismissed"
      assert Passkeys.list(owner) == []
    end

    test "without passkeys enabled the account page offers none", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account")
      refute has_element?(view, "#passkeys")
      refute has_element?(view, "#sign-out")
      render_hook(view, "passkey_options", %{})
      assert_reply view, reply
      assert reply == %{}
    end

    test "the setup notice is logged only while no passkey exists" do
      with_auth([:passkey])

      assert ExUnit.CaptureLog.capture_log(fn -> Setup.announce() end) =~
               "/login?setup=" <> Setup.code()

      refute Setup.valid?(nil)
      refute Setup.valid?("wrong")

      owner = Accounts.single_user!()
      {challenge, options} = Passkeys.registration(owner)

      {:ok, _} =
        Passkeys.register(
          owner,
          challenge,
          TestAuthenticator.attest(TestAuthenticator.new(), options, BabelSyncWeb.Endpoint.url()),
          "k"
        )

      assert ExUnit.CaptureLog.capture_log(fn -> Setup.announce() end) == ""
    end
  end
end
