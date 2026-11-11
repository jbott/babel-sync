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
      assert {:ok, _view, _html} = signed_in |> recycle() |> live(~p"/")
    end

    test "pages need a session and signing out ends it", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")

      conn = sign_in(conn, Accounts.single_user!())
      assert {:ok, _view, _html} = live(conn, ~p"/")

      signed_out = delete(conn, ~p"/logout")
      assert redirected_to(signed_out) == "/login"
      assert {:error, {:redirect, %{to: "/login"}}} = signed_out |> recycle() |> live(~p"/")
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
end
