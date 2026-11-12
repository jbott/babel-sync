defmodule BabelSync.Accounts.Session do
  @moduledoc """
  One browser signed in as a user. The cookie names the row, so removing
  the row signs that browser out wherever it is.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "sessions" do
    field :agent, :string, default: ""
    field :last_seen_at, :utc_datetime_usec
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end

  @browsers [{"Edg", "Edge"}, {"Firefox", "Firefox"}, {"Chrome", "Chrome"}, {"Safari", "Safari"}]
  @systems [
    {"iPhone", "iPhone"},
    {"iPad", "iPad"},
    {"Android", "Android"},
    {"Mac OS X", "Mac"},
    {"Windows", "Windows"},
    {"Linux", "Linux"}
  ]

  @spec label(t()) :: String.t()
  def label(%__MODULE__{agent: agent}) do
    case {named(agent, @browsers), named(agent, @systems)} do
      {nil, nil} -> "A browser"
      {browser, nil} -> browser
      {nil, system} -> "A browser on #{system}"
      {browser, system} -> "#{browser} on #{system}"
    end
  end

  defp named(agent, known) do
    Enum.find_value(known, fn {marker, name} -> String.contains?(agent, marker) && name end)
  end
end
