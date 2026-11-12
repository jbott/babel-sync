defmodule BabelSyncWeb.DeviceController do
  @moduledoc """
  Lets a signed-in device read and change the name it goes by. The name
  is kept on the server, so renaming a device on the account page and
  renaming it on the device are the same act.
  """

  use BabelSyncWeb, :controller

  alias BabelSync.OAuth
  alias BabelSync.OAuth.Grant

  def show(conn, _params) do
    with %Grant{} = grant <- grant(conn) do
      json(conn, described(grant.client.name, grant.user))
    end
  end

  def rename(conn, %{"name" => name}) when is_binary(name) do
    with %Grant{} = grant <- grant(conn),
         {:ok, client} <- OAuth.rename_grant(grant.user, grant.id, name) do
      json(conn, described(client.name, grant.user))
    else
      :error -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid"})
      %Plug.Conn{} = refused -> refused
    end
  end

  def rename(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid"})

  defp described(name, user), do: %{name: name, user: user.name || user.email}

  defp grant(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- OAuth.access_token?(token),
         %Grant{} = grant <- OAuth.grant_for_access_token(token) do
      grant
    else
      _not_a_device -> conn |> put_status(:not_found) |> json(%{error: "not_a_device"})
    end
  end
end
