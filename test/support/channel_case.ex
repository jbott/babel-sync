defmodule BabelSyncWeb.ChannelCase do
  @moduledoc """
  Sets up tests of Phoenix channels with a sandboxed database.
  """

  use ExUnit.CaseTemplate

  import Phoenix.ChannelTest

  @endpoint BabelSyncWeb.Endpoint

  using do
    quote do
      import Phoenix.ChannelTest
      import BabelSyncWeb.ChannelCase
      import BabelSync.Fixtures

      @endpoint BabelSyncWeb.Endpoint
    end
  end

  setup tags do
    BabelSync.DataCase.setup_sandbox(tags)
    :ok
  end

  def connect_as(user, opts \\ []) do
    token = user |> BabelSync.Accounts.Scope.for_user(opts) |> BabelSync.Auth.socket_token()
    {:ok, socket} = connect(BabelSyncWeb.UserSocket, %{"token" => token})
    socket
  end
end
