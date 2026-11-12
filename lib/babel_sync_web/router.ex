defmodule BabelSyncWeb.Router do
  use BabelSyncWeb, :router

  import BabelSyncWeb.Plugs.Scope

  defp welcome_strangers(
         %{path_info: [], method: "GET", assigns: %{current_scope: nil}} = conn,
         _
       ) do
    conn
    |> put_private(:phoenix_live_view, nil)
    |> Phoenix.LiveView.Controller.live_render(BabelSyncWeb.AuthLive.Login)
    |> halt()
  end

  defp welcome_strangers(conn, _opts), do: conn

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BabelSyncWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_scope
  end

  pipeline :welcome do
    plug :welcome_strangers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_scope
    plug :require_scope
  end

  pipeline :mcp do
    plug :fetch_scope
    plug :require_scope
  end

  pipeline :open_api do
    plug :accepts, ["json"]
  end

  scope "/", BabelSyncWeb do
    get "/health", HealthController, :show
  end

  scope "/mcp" do
    pipe_through :mcp

    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: BabelSync.MCP.Server
  end

  scope "/", BabelSyncWeb do
    pipe_through :open_api

    get "/.well-known/oauth-authorization-server", OAuthController, :server_metadata
    get "/.well-known/oauth-authorization-server/*rest", OAuthController, :server_metadata
    get "/.well-known/oauth-protected-resource", OAuthController, :resource_metadata
    get "/.well-known/oauth-protected-resource/*rest", OAuthController, :resource_metadata
    post "/oauth/register", OAuthController, :register
    post "/oauth/token", OAuthController, :token
    post "/oauth/revoke", OAuthController, :revoke
  end

  scope "/api", BabelSyncWeb do
    pipe_through :api

    get "/vaults", VaultController, :index
    get "/device", DeviceController, :show
    put "/device", DeviceController, :rename
    get "/plugin", ObsidianController, :build
    get "/plugin/:name", ObsidianController, :file
  end

  scope "/api/vaults/:vault_id", BabelSyncWeb do
    pipe_through :api

    post "/uploads", BlobController, :begin
    put "/uploads/:id/parts/:number", BlobController, :part
    post "/uploads/:id/complete", BlobController, :complete
    get "/blobs/:hash", BlobController, :show
    post "/docs", DocController, :index
  end

  scope "/", BabelSyncWeb do
    pipe_through [:browser, :welcome]

    get "/v/:vault_id/raw/*path", FileController, :raw
    get "/v/:vault_id/export", ExportController, :show
    get "/obsidian/plugin.zip", ObsidianController, :plugin
    get "/v/:vault_id/obsidian/vault.zip", ObsidianController, :starter

    get "/oauth/authorize", OAuthController, :authorize
    post "/oauth/authorize", OAuthController, :decide

    get "/login/complete", SessionController, :complete
    get "/login/oidc", SessionController, :oidc
    get "/login/oidc/callback", SessionController, :oidc_callback
    post "/login/link", SessionController, :link
    delete "/logout", SessionController, :delete

    live_session :signed_out, on_mount: {BabelSyncWeb.LiveScope, :signed_out} do
      live "/login", AuthLive.Login
      live "/login/link/:token", AuthLive.Login
    end

    live_session :signed_in, on_mount: {BabelSyncWeb.LiveScope, :require} do
      live "/", VaultLive.Home
      live "/account", AuthLive.Account
      live "/v/:vault_id", VaultLive.Show
      live "/v/:vault_id/settings", VaultLive.Settings
      live "/v/:vault_id/trash", VaultLive.Trash
      live "/v/:vault_id/connect", VaultLive.Connect
      live "/v/:vault_id/f/*path", VaultLive.Show
    end
  end

  if Application.compile_env(:babel_sync, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BabelSyncWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
