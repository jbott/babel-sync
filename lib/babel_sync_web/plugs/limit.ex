defmodule BabelSyncWeb.Plugs.Limit do
  @moduledoc """
  Refuses a request once its sender's address has made too many of the
  same kind in the current window. The kinds and their limits are the
  `:rate_limits` in the application's configuration.
  """

  import Plug.Conn

  alias BabelSync.RateLimit
  alias BabelSyncWeb.ClientAddress

  @behaviour Plug

  @impl true
  def init(kind) when is_atom(kind), do: kind

  @impl true
  def call(conn, kind) do
    case RateLimit.allow(kind, ClientAddress.of(conn)) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{
          error: "too_many_requests",
          error_description: "Too many requests from this address. Try again later."
        })
        |> halt()
    end
  end
end
