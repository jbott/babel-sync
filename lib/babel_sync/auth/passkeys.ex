defmodule BabelSync.Auth.Passkeys do
  @moduledoc """
  Passkeys (WebAuthn). A passkey is registered by someone already known
  to the server and afterwards signs them in on its own.
  """

  import Ecto.Query

  alias BabelSync.Accounts.User
  alias BabelSync.Auth.Passkey
  alias BabelSync.Repo

  @spec list(User.t()) :: [Passkey.t()]
  def list(%User{id: user_id}) do
    Repo.all(from p in Passkey, where: p.user_id == ^user_id, order_by: p.inserted_at)
  end

  @spec any?() :: boolean()
  def any?, do: Repo.exists?(Passkey)

  @spec delete(User.t(), Ecto.UUID.t()) :: :ok
  def delete(%User{id: user_id}, id) do
    Repo.delete_all(from p in Passkey, where: p.id == ^id and p.user_id == ^user_id)
    :ok
  end

  @spec registration(User.t()) :: {Wax.Challenge.t(), map()}
  def registration(%User{} = user) do
    challenge = Wax.new_registration_challenge(options())

    public_key = %{
      challenge: encode(challenge.bytes),
      rp: %{id: challenge.rp_id, name: "Babel Sync"},
      user: %{
        id: encode(user.id),
        name: user.email || user.name || "owner",
        displayName: user.name || user.email || "Owner"
      },
      pubKeyCredParams: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -257}],
      authenticatorSelection: %{residentKey: "required", userVerification: "preferred"},
      excludeCredentials: for(key <- list(user), do: descriptor(key.credential_id)),
      attestation: "none"
    }

    {challenge, public_key}
  end

  @spec register(User.t(), Wax.Challenge.t(), map(), String.t()) ::
          {:ok, Passkey.t()} | {:error, :invalid}
  def register(%User{} = user, %Wax.Challenge{} = challenge, response, name) do
    with {:ok, attestation} <- decode(response["attestationObject"]),
         {:ok, client_data} <- decode(response["clientDataJSON"]),
         {:ok, {authenticator_data, _result}} <- Wax.register(attestation, client_data, challenge) do
      credential = authenticator_data.attested_credential_data

      {:ok,
       Repo.insert!(%Passkey{
         user_id: user.id,
         credential_id: credential.credential_id,
         public_key: :erlang.term_to_binary(credential.credential_public_key),
         sign_count: authenticator_data.sign_count,
         name: name |> String.trim() |> String.slice(0, 60) |> default_name()
       })}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @spec authentication() :: {Wax.Challenge.t(), map()}
  def authentication do
    challenge = Wax.new_authentication_challenge(options())

    {challenge,
     %{challenge: encode(challenge.bytes), rpId: challenge.rp_id, userVerification: "preferred"}}
  end

  @spec authenticate(Wax.Challenge.t(), map()) :: {:ok, User.t()} | {:error, :invalid}
  def authenticate(%Wax.Challenge{} = challenge, response) do
    with {:ok, credential_id} <- decode(response["id"]),
         {:ok, authenticator_data} <- decode(response["authenticatorData"]),
         {:ok, signature} <- decode(response["signature"]),
         {:ok, client_data} <- decode(response["clientDataJSON"]),
         %Passkey{} = passkey <- Repo.get_by(Passkey, credential_id: credential_id),
         {:ok, verified} <-
           Wax.authenticate(
             credential_id,
             authenticator_data,
             signature,
             client_data,
             challenge,
             [{credential_id, :erlang.binary_to_term(passkey.public_key, [:safe])}]
           ),
         true <- fresh_counter?(passkey, verified.sign_count) do
      passkey
      |> Ecto.Changeset.change(sign_count: verified.sign_count, last_used_at: DateTime.utc_now())
      |> Repo.update!()

      {:ok, Repo.get!(User, passkey.user_id)}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp fresh_counter?(%Passkey{sign_count: 0}, 0), do: true
  defp fresh_counter?(%Passkey{sign_count: stored}, seen), do: seen > stored

  defp options do
    uri = URI.parse(BabelSyncWeb.Endpoint.url())

    [
      origin: BabelSyncWeb.Endpoint.url(),
      rp_id: uri.host,
      attestation: "none",
      trusted_attestation_types: [:none, :self, :basic, :uncertain, :attca, :anonca],
      verify_trust_root: false,
      user_verification: "preferred"
    ]
  end

  defp descriptor(credential_id), do: %{type: "public-key", id: encode(credential_id)}

  defp default_name(""), do: "Passkey"
  defp default_name(name), do: name

  defp encode(binary), do: Base.url_encode64(binary, padding: false)

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_missing), do: :error
end
