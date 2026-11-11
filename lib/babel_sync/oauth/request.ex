defmodule BabelSync.OAuth.Request do
  @moduledoc """
  A checked authorization request, ready to be shown to the user.
  """

  alias BabelSync.OAuth.Client

  @type t :: %__MODULE__{
          client: Client.t(),
          redirect_uri: String.t(),
          state: String.t() | nil,
          challenge: String.t(),
          read_only: boolean()
        }

  @enforce_keys [:client, :redirect_uri, :challenge]
  defstruct [:client, :redirect_uri, :state, :challenge, read_only: false]
end
