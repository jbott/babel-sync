defmodule BabelSyncWeb.PageController do
  use BabelSyncWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
