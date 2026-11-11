defmodule BabelSyncWeb.UserSocketTest do
  use BabelSyncWeb.ChannelCase, async: false

  alias BabelSyncWeb.UserSocket

  test "a valid token connects as its user" do
    user = user()

    assert connect_as(user).assigns.scope.user.id == user.id
  end

  test "a forged token is refused" do
    assert :error = connect(UserSocket, %{"token" => "forged"})
  end

  test "no token is refused when sign-in is required" do
    Application.put_env(:babel_sync, :auth, [:passkey])
    on_exit(fn -> Application.put_env(:babel_sync, :auth, []) end)

    assert :error = connect(UserSocket, %{})
  end

  test "no token connects as the owner when single-user sign-in is disabled" do
    assert {:ok, socket} = connect(UserSocket, %{})
    assert socket.assigns.scope.user.id == BabelSync.Accounts.single_user!().id
  end
end
