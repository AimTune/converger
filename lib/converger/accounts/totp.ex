defmodule Converger.Accounts.TOTP do
  @moduledoc """
  TOTP two-factor authentication (RFC 6238, 6 digits, 30 s steps) for admin
  and tenant users (issue #52, ADR-0058), on top of `NimbleTOTP`.

  Enrollment: `begin_enrollment/1` stores a new random secret (encrypted at
  rest) without enabling 2FA; the user adds it to an authenticator app
  (`base32_secret/1`, `otpauth_uri/1`) and `confirm_enrollment/2` enables 2FA
  once a code from the app checks out.

  Codes of the current and the previous time step are accepted (clock skew).
  The accepted step is stored in `totp_last_step` with a conditional update,
  so a code can be used only once, even by two concurrent requests.
  """

  import Ecto.Query, warn: false

  alias Converger.Accounts.{AdminUser, Audit, TenantUser}
  alias Converger.Repo

  @period 30
  @issuer "Converger"

  @type user :: AdminUser.t() | TenantUser.t()

  @doc "True when the user has confirmed 2FA."
  @spec enabled?(user() | nil) :: boolean()
  def enabled?(%{totp_enabled_at: %DateTime{}}), do: true
  def enabled?(_), do: false

  @doc """
  Admin roles that must use 2FA (`:converger, :require_2fa_roles`, env
  `ADMIN_REQUIRE_2FA_ROLES`, default `["super_admin"]`).
  """
  @spec required_roles() :: [String.t()]
  def required_roles, do: Application.get_env(:converger, :require_2fa_roles, ["super_admin"])

  @doc """
  True when `user` is an admin whose role requires 2FA and who has not
  enabled it yet: they are sent to enrollment before any admin page.
  """
  @spec enrollment_required?(user() | nil) :: boolean()
  def enrollment_required?(%AdminUser{role: role} = user),
    do: role in required_roles() and not enabled?(user)

  def enrollment_required?(_), do: false

  @doc "True when the user has started but not confirmed enrollment."
  @spec pending?(user()) :: boolean()
  def pending?(%{totp_secret: secret} = user) when is_binary(secret), do: not enabled?(user)
  def pending?(_), do: false

  @doc """
  Starts (or restarts) enrollment with a new secret. Returns
  `{:error, :already_enabled}` when 2FA is on.
  """
  @spec begin_enrollment(user()) :: {:ok, user()} | {:error, :already_enabled}
  def begin_enrollment(user) do
    if enabled?(user) do
      {:error, :already_enabled}
    else
      user
      |> Ecto.Changeset.change(
        totp_secret: NimbleTOTP.secret(),
        totp_enabled_at: nil,
        totp_last_step: nil
      )
      |> Repo.update()
    end
  end

  @doc "The secret in base32, for manual entry in an authenticator app."
  @spec base32_secret(user()) :: String.t() | nil
  def base32_secret(%{totp_secret: secret}) when is_binary(secret),
    do: Base.encode32(secret, padding: false)

  def base32_secret(_), do: nil

  @doc "The `otpauth://` URI of the secret (QR code content)."
  @spec otpauth_uri(user()) :: String.t() | nil
  def otpauth_uri(%{totp_secret: secret, email: email}) when is_binary(secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  def otpauth_uri(_), do: nil

  @doc """
  Enables 2FA for a pending enrollment when `code` is valid. Audit-logged.
  Options: `:now` (unix seconds, for tests).
  """
  @spec confirm_enrollment(user(), String.t(), keyword()) ::
          {:ok, user()} | {:error, :invalid_code | :not_pending}
  def confirm_enrollment(user, code, opts \\ []) do
    now = now(opts)

    with true <- pending?(user) || {:error, :not_pending},
         {:ok, step} <- match_step(user.totp_secret, code, nil, now) do
      changeset =
        Ecto.Changeset.change(user,
          totp_enabled_at: DateTime.from_unix!(now * 1_000_000, :microsecond),
          totp_last_step: step
        )

      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, changeset)
      |> Ecto.Multi.insert(:audit_log, Audit.entry(user, Audit.self_actor(user), "enable_2fa"))
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, user}
        {:error, _, _, _} -> {:error, :invalid_code}
      end
    end
  end

  @doc """
  Checks a login code of a user with 2FA enabled and records its time step,
  so it cannot be used again. Returns `:ok` or `:error`.
  Options: `:now` (unix seconds, for tests).
  """
  @spec verify(user(), String.t() | nil, keyword()) :: :ok | :error
  def verify(user, code, opts \\ []) do
    with true <- enabled?(user),
         {:ok, step} <- match_step(user.totp_secret, code, user.totp_last_step, now(opts)),
         {1, _} <- record_step(user, step) do
      :ok
    else
      _ -> :error
    end
  end

  # Only moves forward: a concurrent request that used the same (or a later)
  # step wins and this one is rejected.
  defp record_step(%module{id: id}, step) do
    from(u in module,
      where: u.id == ^id and (is_nil(u.totp_last_step) or u.totp_last_step < ^step)
    )
    |> Repo.update_all(set: [totp_last_step: step])
  end

  @doc """
  Turns 2FA off for the user themself, who must give a current code or
  their password. Audit-logged.
  """
  @spec disable(user(), String.t() | nil, keyword()) :: {:ok, user()} | {:error, :invalid}
  def disable(user, code_or_password, opts \\ []) do
    code_or_password = code_or_password || ""

    if enabled?(user) and
         (verify(user, code_or_password, opts) == :ok or
            user.__struct__.valid_password?(user, code_or_password)) do
      clear(user, Audit.self_actor(user), "disable_2fa")
    else
      {:error, :invalid}
    end
  end

  @doc """
  Resets another user's 2FA (lost device): a super_admin for admins, a
  tenant owner/admin for tenant users, or a release task. Audit-logged with
  `actor` (`%{type: ..., id: ...}`).
  """
  @spec reset(user(), map()) :: {:ok, user()} | {:error, term()}
  def reset(user, actor), do: clear(user, actor, "reset_2fa")

  defp clear(user, actor, action) do
    changeset =
      Ecto.Changeset.change(user, totp_secret: nil, totp_enabled_at: nil, totp_last_step: nil)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.insert(:audit_log, Audit.entry(user, actor, action))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Rewrites every stored TOTP secret with the current `CLOAK_KEY` (after a
  key rotation, `Converger.Release.reencrypt_secrets/0`). Returns the count.
  """
  @spec reencrypt_all() :: non_neg_integer()
  def reencrypt_all do
    for module <- [AdminUser, TenantUser],
        user <- Repo.all(from(u in module, where: not is_nil(u.totp_secret))),
        reduce: 0 do
      count ->
        user
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.force_change(:totp_secret, user.totp_secret)
        |> Repo.update!()

        count + 1
    end
  end

  @doc false
  # The time step of `code` (now or one step back) newer than `last_step`.
  def match_step(secret, code, last_step, now) when is_binary(secret) and is_binary(code) do
    code = String.replace(code, ~r/\s/, "")

    [now, now - @period]
    |> Enum.find_value({:error, :invalid_code}, fn time ->
      step = Integer.floor_div(time, @period)

      if (is_nil(last_step) or step > last_step) and
           NimbleTOTP.valid?(secret, code, time: time, period: @period),
         do: {:ok, step}
    end)
  end

  def match_step(_secret, _code, _last_step, _now), do: {:error, :invalid_code}

  defp now(opts), do: Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
end
