defmodule BabelSync.Auth.MagicLink do
  @moduledoc """
  Signing in with a link sent by email.

  Addresses that already have an account may always ask for a link.
  `BABELSYNC_ALLOWED_EMAILS` lets new people in: a list of addresses,
  `*@domain` patterns, or `*` for anyone.

  Sending is bounded so the server cannot be used to flood a mailbox or
  a mail server: an address with three links still unused gets no more
  until one is used or expires, and the whole server sends at most
  sixty links an hour.
  """

  import Ecto.Query

  require Logger

  alias BabelSync.Accounts
  alias BabelSync.Accounts.User
  alias BabelSync.Auth.LoginLink
  alias BabelSync.{Mailer, Repo}

  @lifetime 900
  @per_address 3
  @per_hour 60

  @spec request(String.t(), (String.t() -> String.t())) :: :ok | {:error, :busy | :unsent}
  def request(email, url) when is_binary(email) and is_function(url, 1) do
    email = User.normalize_email(email)
    now = DateTime.utc_now()

    cond do
      not permitted?(email) -> :ok
      outstanding(email, now) >= @per_address -> :ok
      sent_this_hour(now) >= @per_hour -> {:error, :busy}
      true -> send_link(email, url, now)
    end
  end

  defp send_link(email, url, now) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    link =
      Repo.insert!(%LoginLink{
        email: email,
        token_hash: digest(token),
        expires_at: DateTime.add(now, @lifetime, :second)
      })

    case Mailer.deliver(message(email, url.(token))) do
      {:ok, _receipt} ->
        :ok

      {:error, reason} ->
        Repo.delete!(link)
        Logger.warning("could not send a sign-in link: #{inspect(reason)}")
        {:error, :unsent}
    end
  end

  defp outstanding(email, now) do
    Repo.aggregate(
      from(l in LoginLink, where: l.email == ^email and l.expires_at > ^now),
      :count
    )
  end

  defp sent_this_hour(now) do
    since = DateTime.add(now, @lifetime - 3600, :second)
    Repo.aggregate(from(l in LoginLink, where: l.expires_at > ^since), :count)
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
      from: {"Babel Sync", config(:from)},
      subject: "Your Babel Sync sign-in link",
      text_body: """
      Open this link to sign in to Babel Sync:

      #{link}

      It works once and expires in 15 minutes. If you did not ask for it,
      you can ignore this message.
      """
    )
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp config(key), do: Application.fetch_env!(:babel_sync, __MODULE__)[key]
end
