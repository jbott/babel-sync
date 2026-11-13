defmodule BabelSync.AccountsOwnerTest do
  use BabelSync.DataCase, async: false

  alias BabelSync.{Accounts, Repo}

  setup do
    previous = Application.fetch_env!(:babel_sync, :mode)
    Application.put_env(:babel_sync, :mode, :single)
    on_exit(fn -> Application.put_env(:babel_sync, :mode, previous) end)
  end

  test "the owner is the same person whichever server makes them" do
    first = Accounts.single_user!()
    Repo.delete_all(Accounts.User)
    made_again = for _server <- 1..2, do: Accounts.single_user!()

    assert [%{id: id}, %{id: id}] = made_again
    assert id == first.id
    assert Repo.aggregate(Accounts.User, :count) == 1
  end
end
