defmodule BabelSync.Auth.MagicLink do
  @moduledoc """
  Signing in with a link sent by email.

  Addresses that already have an account may always ask for a link.
  `BABELSYNC_ALLOWED_EMAILS` lets new people in: a list of addresses,
  `*@domain` patterns, or `*` for anyone.
  """

  import Ecto.Query

  alias BabelSync.Accounts
  alias BabelSync.Accounts.User
  alias BabelSync.Auth.LoginLink
  alias BabelSync.{Mailer, Repo}

  @lifetime 900

  @spec request(String.t(), (String.t() -> String.t())) :: :ok
  def request(email, url) when is_binary(email) and is_function(url, 1) do
    email = User.normalize_email(email)

    if permitted?(email) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      Repo.insert!(%LoginLink{
        email: email,
        token_hash: digest(token),
        expires_at: DateTime.add(DateTime.utc_now(), @lifetime, :second)
      })

      {:ok, _receipt} = Mailer.deliver(message(email, url.(token)))
    end

    :ok
  end

  @spec peek(String.t()) :: {:ok, String.t()} | :error
  def peek(token) do
    case Repo.one(live(token)) do
      %LoginLink{email: email} -> {:ok, email}
      nil -> :error
    end
  end

  @spec redeem(String.t()) :: {:ok, User.t()} | :error
  def redeem(token) do
    case Repo.delete_all(select(live(token), [l], l)) do
      {1, [%LoginLink{email: email}]} -> {:ok, Accounts.user_for_email(email)}
      {0, _none} -> :error
    end
  end

  @spec prune(DateTime.t()) :: :ok
  def prune(now \\ DateTime.utc_now()) do
    Repo.delete_all(from l in LoginLink, where: l.expires_at < ^now)
    :ok
  end

  @spec permitted?(String.t()) :: boolean()
  def permitted?(email) do
    cond do
      not String.match?(email, ~r/^[^\s@]+@[^\s@]+$/) -> false
      BabelSync.mode() == :single -> allowed?(email)
      true -> allowed?(email) or not is_nil(Accounts.get_user_by_email(email))
    end
  end

  defp allowed?(email) do
    Enum.any?(config(:allowed_emails), fn
      "*" -> true
      "*@" <> domain -> String.ends_with?(email, "@" <> domain)
      exact -> exact == email
    end)
  end

  defp live(token) do
    hash = digest(token)
    now = DateTime.utc_now()
    from l in LoginLink, where: l.token_hash == ^hash and l.expires_at > ^now
  end

  defp message(email, link) do
    Swoosh.Email.new(
      to: email,
      from: {"BabelSync", config(:from)},
      subject: "Your BabelSync sign-in link",
      text_body: """
      Open this link to sign in to BabelSync:

      #{link}

      It works once and expires in 15 minutes. If you did not ask for it,
      you can ignore this message.
      """
    )
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp config(key), do: Application.fetch_env!(:babel_sync, __MODULE__)[key]
end
