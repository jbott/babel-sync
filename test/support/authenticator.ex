defmodule BabelSync.TestAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator, enough to register a passkey and
  sign in with it the way a browser would.
  """

  defstruct [:credential_id, :private_key, :public_key, counter: 0]

  def new do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(32),
      private_key: private,
      public_key: public
    }
  end

  def attest(%__MODULE__{} = authenticator, options, origin) do
    <<4, x::binary-32, y::binary-32>> = authenticator.public_key

    cose =
      CBOR.encode(%{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: x},
        -3 => %CBOR.Tag{tag: :bytes, value: y}
      })

    id = authenticator.credential_id

    authenticator_data =
      rp_hash(options.rp.id) <>
        <<0x45, 0::32, 0::128, byte_size(id)::16>> <> id <> cose

    attestation =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: authenticator_data}
      })

    %{
      "attestationObject" => encode(attestation),
      "clientDataJSON" => encode(client_data("webauthn.create", options.challenge, origin))
    }
  end

  def assert(%__MODULE__{} = authenticator, options, origin) do
    counter = authenticator.counter + 1
    authenticator_data = rp_hash(options.rpId) <> <<0x05, counter::32>>
    client_data = client_data("webauthn.get", options.challenge, origin)

    signature =
      :crypto.sign(:ecdsa, :sha256, authenticator_data <> :crypto.hash(:sha256, client_data), [
        authenticator.private_key,
        :secp256r1
      ])

    response = %{
      "id" => encode(authenticator.credential_id),
      "authenticatorData" => encode(authenticator_data),
      "signature" => encode(signature),
      "clientDataJSON" => encode(client_data)
    }

    {%{authenticator | counter: counter}, response}
  end

  defp client_data(type, challenge, origin) do
    Jason.encode!(%{type: type, challenge: challenge, origin: origin, crossOrigin: false})
  end

  defp rp_hash(rp_id), do: :crypto.hash(:sha256, rp_id)

  defp encode(binary), do: Base.url_encode64(binary, padding: false)
end
