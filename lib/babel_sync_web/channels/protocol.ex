defmodule BabelSyncWeb.Protocol do
  @moduledoc """
  The version of the sync protocol spoken over the channels. A client
  says which it speaks when it joins; one older than the oldest still
  understood is told to upgrade rather than left to misread what it is
  sent. A client that says nothing predates the number and speaks 1.

  Raise `@current` when a change would be misunderstood by clients
  that have not been updated, and `@oldest` once they are no longer
  served.
  """

  @current 1
  @oldest 1

  @spec current() :: pos_integer()
  def current, do: @current

  @spec check(map()) :: :ok | {:error, :upgrade}
  def check(params) do
    case Map.get(params, "protocol", 1) do
      spoken when is_integer(spoken) and spoken >= @oldest -> :ok
      _too_old_or_malformed -> {:error, :upgrade}
    end
  end

  @spec refusal() :: map()
  def refusal, do: %{reason: "upgrade", oldest: @oldest, current: @current}
end
