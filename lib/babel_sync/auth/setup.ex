defmodule BabelSync.Auth.Setup do
  @moduledoc """
  First-run protection for a single-user server that signs in with a
  passkey. Until the owner has registered one, registering needs a code
  that is only written to the server log, so reaching the address first
  is not enough to claim the server.
  """

  require Logger

  alias BabelSync.Auth
  alias BabelSync.Auth.Passkeys

  @key {__MODULE__, :code}

  @spec needed?() :: boolean()
  def needed? do
    BabelSync.mode() == :single and Auth.enabled?(:passkey) and not Passkeys.any?()
  end

  @spec code() :: String.t()
  def code do
    case :persistent_term.get(@key, nil) do
      nil ->
        code = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        :persistent_term.put(@key, code)
        code

      code ->
        code
    end
  end

  @spec valid?(String.t()) :: boolean()
  def valid?(given) when is_binary(given), do: Plug.Crypto.secure_compare(given, code())
  def valid?(_missing), do: false

  @spec announce() :: :ok
  def announce do
    if needed?() do
      Logger.warning(
        "No passkey is registered yet. Register one at " <>
          BabelSyncWeb.Endpoint.url() <> "/login?setup=" <> code()
      )
    end

    :ok
  end
end
