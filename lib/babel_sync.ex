defmodule BabelSync do
  @moduledoc """
  Babel Sync keeps Obsidian vaults in sync between devices, people and agents.
  """

  @spec mode() :: :single | :multi
  def mode, do: Application.fetch_env!(:babel_sync, :mode)

  @spec storage() :: :local | :remote
  def storage, do: Application.fetch_env!(:babel_sync, :storage)

  @spec data_dir() :: Path.t()
  def data_dir, do: Application.fetch_env!(:babel_sync, :data_dir)
end
