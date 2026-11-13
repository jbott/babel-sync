defmodule BabelSync.Auth.Setup do
  @moduledoc """
  First-run protection for a single-user server that signs in with a
  passkey. Until the owner has registered one, registering needs a code
  that is only written to the server log, so reaching the address first
  is not enough to claim the server. The code is made from the server's
  secret, so every node of a cluster prints and accepts the same one.
  """

  require Logger

  alias BabelSync.Auth
  alias BabelSync.Auth.Passkeys

  @spec needed?() :: boolean()
  def needed? do
    BabelSync.mode() == :single and Auth.enabled?(:passkey) and not Passkeys.any?()
  end

  @spec code() :: String.t()
  def code do
    secret = BabelSyncWeb.Endpoint.config(:secret_key_base)

    :hmac
    |> :crypto.mac(:sha256, secret, "first passkey")
    |> binary_part(0, 18)
    |> Base.url_encode64(padding: false)
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
