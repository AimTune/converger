defmodule Converger.Accounts.PasswordReset do
  @moduledoc """
  Password reset by email for admin and tenant users (issue #52, ADR-0058).

  `deliver_admin_instructions/2` and `deliver_tenant_instructions/3` mail a
  link with a random 32-byte token (URL-safe base64) when an active account
  matches, and return `:ok` either way, so the request form cannot be used to
  find out which accounts exist. Only the token's SHA-256 is stored
  (`account_tokens`, context `"reset_password"`).

  A token is valid for one hour, for one use, and only while the account's
  email is still the one it was sent to. Any password change deletes the
  user's reset tokens. A reset also clears `must_change_password`, signs the
  user out everywhere (`Converger.Accounts.Sessions.delete_all/3`) and is
  audit-logged.
  """

  import Ecto.Query, warn: false

  alias Converger.Accounts
  alias Converger.Accounts.{AccountToken, AdminUser, Audit, Sessions, TenantUser, UserNotifier}
  alias Converger.Repo

  require Logger

  @context "reset_password"
  @validity_seconds 3_600

  @doc "Lifetime of a reset link in seconds."
  def validity_seconds, do: @validity_seconds

  @doc """
  Mails a reset link to the active admin with `email`, if any. `url_fun`
  builds the link from the token. Always returns `:ok`.
  """
  @spec deliver_admin_instructions(String.t(), (String.t() -> String.t())) :: :ok
  def deliver_admin_instructions(email, url_fun) when is_binary(email) do
    case Accounts.get_admin_user_by_email(String.trim(email)) do
      %AdminUser{status: "active"} = user -> deliver(user, url_fun)
      _ -> :ok
    end
  end

  @doc """
  Mails a reset link to the active tenant user with `email` in the active
  tenant named `tenant_name`, if any. Always returns `:ok`.
  """
  @spec deliver_tenant_instructions(String.t(), String.t(), (String.t() -> String.t())) :: :ok
  def deliver_tenant_instructions(tenant_name, email, url_fun)
      when is_binary(tenant_name) and is_binary(email) do
    with %{id: tenant_id, status: "active"} <-
           Converger.Tenants.get_tenant_by_name(String.trim(tenant_name)),
         %TenantUser{status: "active"} = user <-
           Accounts.get_tenant_user_by_email_and_tenant(String.trim(email), tenant_id) do
      deliver(user, url_fun)
    else
      _ -> :ok
    end
  end

  defp deliver(user, url_fun) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    Repo.insert!(%AccountToken{
      user_type: user_type(user),
      user_id: user.id,
      context: @context,
      token_hash: hash(token),
      sent_to: user.email
    })

    # A failing mailer must not change the answer (no account enumeration).
    case send_mail(user, url_fun.(token)) do
      {:ok, _email} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send the password reset email: #{inspect(reason)}")
        :ok
    end
  end

  defp send_mail(user, url) do
    UserNotifier.deliver_reset_password_instructions(user, url)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  The active user a valid, unexpired reset token of `user_type` (`"admin"` or
  `"tenant"`) belongs to, or `nil`.
  """
  @spec get_user_by_token(String.t(), String.t() | nil) :: AdminUser.t() | TenantUser.t() | nil
  def get_user_by_token(user_type, token) when is_binary(token) do
    with %AccountToken{} = account_token <- get_token(user_type, token),
         %{status: "active", email: email} = user <- get_user(user_type, account_token.user_id),
         true <- email == account_token.sent_to do
      user
    else
      _ -> nil
    end
  end

  def get_user_by_token(_user_type, _token), do: nil

  defp get_token(user_type, token) do
    valid_after = DateTime.add(DateTime.utc_now(), -@validity_seconds, :second)

    from(t in AccountToken,
      where:
        t.context == @context and t.user_type == ^user_type and t.token_hash == ^hash(token) and
          t.inserted_at > ^valid_after
    )
    |> Repo.one()
  end

  defp get_user("admin", id), do: Repo.get(AdminUser, id)
  defp get_user("tenant", id), do: Repo.get(TenantUser, id)

  @doc """
  Sets a new password with a reset token (`attrs`: `"password"`,
  `"password_confirmation"`). Returns `{:ok, user}`,
  `{:error, :invalid_token}` or `{:error, changeset}`.
  """
  @spec reset_password(String.t(), String.t(), map()) ::
          {:ok, AdminUser.t() | TenantUser.t()} | {:error, :invalid_token | Ecto.Changeset.t()}
  def reset_password(user_type, token, attrs) do
    case get_user_by_token(user_type, token) do
      nil ->
        {:error, :invalid_token}

      user ->
        changeset = user.__struct__.password_changeset(user, attrs)

        Ecto.Multi.new()
        |> Ecto.Multi.update(:user, changeset)
        |> Ecto.Multi.delete_all(:tokens, tokens_query(user_type, user.id))
        |> Ecto.Multi.insert(
          :audit_log,
          Audit.entry(user, Audit.self_actor(user), "reset_password", %{
            "password" => "[changed]"
          })
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{user: updated}} ->
            Sessions.delete_all(user_type, updated.id)
            {:ok, updated}

          {:error, :user, changeset, _} ->
            {:error, changeset}
        end
    end
  end

  @doc "Query of all reset tokens of a user (deleted on every password change)."
  def tokens_query(user_type, user_id) do
    from(t in AccountToken, where: t.user_type == ^user_type and t.user_id == ^user_id)
  end

  @doc "Deletes expired tokens. Returns the count."
  @spec prune() :: non_neg_integer()
  def prune do
    expired_before = DateTime.add(DateTime.utc_now(), -@validity_seconds, :second)

    {count, _} =
      from(t in AccountToken, where: t.inserted_at <= ^expired_before) |> Repo.delete_all()

    count
  end

  defp user_type(%AdminUser{}), do: "admin"
  defp user_type(%TenantUser{}), do: "tenant"

  defp hash(token), do: :crypto.hash(:sha256, token)
end
