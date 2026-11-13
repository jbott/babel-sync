defmodule BabelSyncWeb.Plugs.ContentPolicy do
  @moduledoc """
  Tells the browser which sources a page may load, so that markup that
  slips into a page cannot run script from anywhere else.

  Scripts come only from this server, plus the one inline script in the
  root layout, which carries the nonce made here for each response.
  Styles may be inline because the editor and LiveView set them on
  elements. Images may come from any HTTPS address, since notes link to
  pictures elsewhere. No other site may frame these pages.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob: https:",
        "media-src 'self' blob:",
        "font-src 'self'",
        "connect-src 'self'",
        "frame-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "frame-ancestors 'none'"
      ],
      "; "
    )
  end
end
