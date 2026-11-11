defmodule BabelSync.Auth.OIDC do
  @moduledoc """
  Signing in through an OpenID Connect provider.

  `BABELSYNC_OIDC_REQUIRE` narrows who may come in: every listed claim
  must have the listed value. A single-user server needs it, since
  otherwise any account at the provider would be let in as the owner.
  """

  alias BabelSync.Accounts
  alias BabelSync.Accounts.User

  @provider __MODULE__.Provider

  @type flow :: %{state: String.t(), nonce: String.t(), verifier: String.t()}

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    options = %{issuer: config(:issuer), name: @provider}

    options =
      if String.starts_with?(config(:issuer), "http://"),
        do: Map.put(options, :provider_configuration_opts, %{quirks: %{allow_unsafe_http: true}}),
        else: options

    Supervisor.child_spec({Oidcc.ProviderConfiguration.Worker, options}, id: @provider)
  end

  @spec label() :: String.t()
  def label, do: config(:label)

  @spec begin(String.t()) :: {:ok, String.t(), flow()} | {:error, term()}
  def begin(redirect_uri) do
    flow = %{state: random(), nonce: random(), verifier: random()}

    options = %{
      redirect_uri: redirect_uri,
      scopes: config(:scopes),
      state: flow.state,
      nonce: flow.nonce,
      pkce_verifier: flow.verifier
    }

    case Oidcc.create_redirect_url(@provider, config(:client_id), secret(), options) do
      {:ok, url} -> {:ok, IO.iodata_to_binary(url), flow}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish(String.t(), String.t(), flow()) :: {:ok, User.t()} | {:error, term()}
  def finish(code, redirect_uri, flow) do
    options = %{redirect_uri: redirect_uri, nonce: flow.nonce, pkce_verifier: flow.verifier}

    with {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} <-
           Oidcc.retrieve_token(code, @provider, config(:client_id), secret(), options),
         :ok <- permit(claims) do
      {:ok, Accounts.user_for_identity(claims["iss"], claims["sub"], profile(claims))}
    end
  end

  @spec permit(map()) :: :ok | {:error, :not_permitted}
  def permit(claims) do
    permitted? =
      Enum.all?(config(:require), fn {claim, value} -> to_string(claims[claim]) == value end)

    if permitted?, do: :ok, else: {:error, :not_permitted}
  end

  defp profile(claims) do
    %{email: verified_email(claims), name: claims["name"] || claims["preferred_username"]}
  end

  defp verified_email(%{"email" => email, "email_verified" => verified})
       when is_binary(email) and verified in [true, "true"],
       do: email

  defp verified_email(_claims), do: nil

  defp secret, do: config(:client_secret) || :unauthenticated

  defp config(key), do: Application.fetch_env!(:babel_sync, __MODULE__)[key]

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
