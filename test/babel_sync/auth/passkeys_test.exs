defmodule BabelSync.Auth.PasskeysTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Auth.Passkeys
  alias BabelSync.TestAuthenticator

  defp origin, do: BabelSyncWeb.Endpoint.url()

  defp registered(user) do
    authenticator = TestAuthenticator.new()
    {challenge, options} = Passkeys.registration(user)
    response = TestAuthenticator.attest(authenticator, options, origin())
    {:ok, passkey} = Passkeys.register(user, challenge, response, " Laptop ")
    {authenticator, passkey}
  end

  test "a registered passkey signs its owner in" do
    user = user()
    {authenticator, passkey} = registered(user)
    assert passkey.name == "Laptop"
    assert [%{id: id}] = Passkeys.list(user)
    assert id == passkey.id

    {challenge, options} = Passkeys.authentication()
    {_authenticator, response} = TestAuthenticator.assert(authenticator, options, origin())
    assert {:ok, signed_in} = Passkeys.authenticate(challenge, response)
    assert signed_in.id == user.id
  end

  test "a replayed or foreign assertion is refused" do
    {authenticator, _passkey} = registered(user())

    {challenge, options} = Passkeys.authentication()
    {authenticator, response} = TestAuthenticator.assert(authenticator, options, origin())
    assert {:ok, _user} = Passkeys.authenticate(challenge, response)

    {other_challenge, _options} = Passkeys.authentication()
    assert {:error, :invalid} = Passkeys.authenticate(other_challenge, response)

    {challenge, options} = Passkeys.authentication()

    {_authenticator, phished} =
      TestAuthenticator.assert(authenticator, options, "https://evil.example")

    assert {:error, :invalid} = Passkeys.authenticate(challenge, phished)

    {challenge, options} = Passkeys.authentication()
    {_unknown, response} = TestAuthenticator.assert(TestAuthenticator.new(), options, origin())
    assert {:error, :invalid} = Passkeys.authenticate(challenge, response)
  end

  test "a cloned authenticator with a stale counter is refused" do
    {authenticator, _passkey} = registered(user())

    {challenge, options} = Passkeys.authentication()
    {_advanced, response} = TestAuthenticator.assert(authenticator, options, origin())
    assert {:ok, _user} = Passkeys.authenticate(challenge, response)

    {challenge, options} = Passkeys.authentication()
    {_stale, response} = TestAuthenticator.assert(authenticator, options, origin())
    assert {:error, :invalid} = Passkeys.authenticate(challenge, response)
  end

  test "only the owner can delete a passkey" do
    user = user()
    {_authenticator, passkey} = registered(user)

    assert :ok = Passkeys.delete(user(), passkey.id)
    assert [_kept] = Passkeys.list(user)
    assert :ok = Passkeys.delete(user, passkey.id)
    assert [] = Passkeys.list(user)
  end
end
