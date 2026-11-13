defmodule BabelSync.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BabelSyncWeb.Telemetry,
      BabelSync.Repo.active(),
      {Ecto.Migrator,
       repos: [BabelSync.Repo.active()],
       skip: not Application.get_env(:babel_sync, :auto_migrate, true)},
      {Phoenix.PubSub, name: BabelSync.PubSub},
      {Registry, keys: :unique, name: BabelSync.Sync.Registry},
      BabelSync.RateLimit,
      {DynamicSupervisor, name: BabelSync.Sync.Supervisor, strategy: :one_for_one},
      {BabelSync.MCP.Server, transport: {:streamable_http, start: true}},
      BabelSyncWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BabelSync.Supervisor]

    children = children ++ sign_in_children() ++ cleanup_children() ++ cluster_children()

    with {:ok, supervisor} <- Supervisor.start_link(children, opts) do
      BabelSync.Auth.Setup.announce()
      {:ok, supervisor}
    end
  end

  defp cleanup_children do
    if Application.fetch_env!(:babel_sync, BabelSync.Janitor)[:enabled],
      do: [BabelSync.Janitor],
      else: []
  end

  defp cluster_children do
    if BabelSync.Cluster.enabled?(), do: [BabelSync.Cluster], else: []
  end

  defp sign_in_children do
    if BabelSync.Auth.enabled?(:oidc), do: [BabelSync.Auth.OIDC], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BabelSyncWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
