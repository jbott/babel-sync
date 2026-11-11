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
      {DNSCluster, query: Application.get_env(:babel_sync, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BabelSync.PubSub},
      {Registry, keys: :unique, name: BabelSync.Sync.Registry},
      {DynamicSupervisor, name: BabelSync.Sync.Supervisor, strategy: :one_for_one},
      # Start a worker by calling: BabelSync.Worker.start_link(arg)
      # {BabelSync.Worker, arg},
      # Start to serve requests, typically the last entry
      BabelSyncWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BabelSync.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BabelSyncWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
