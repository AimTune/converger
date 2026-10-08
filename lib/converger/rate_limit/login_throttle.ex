defmodule Converger.RateLimit.LoginThrottle do
  @moduledoc """
  Failed-login lockout for the admin and tenant portal login forms.

  Failed attempts are counted per client IP (`:login_ip` bucket) and per
  account (`:login_account` bucket, default 5 per minute each). Once either
  counter reaches its limit, further attempts are rejected before the
  password is checked until the window ends.

  Note that the per-account lock can be triggered by anyone who knows the
  account identifier; the short window keeps that denial of service bounded.
  """

  alias Converger.RateLimit

  @doc "Returns `:ok` or `{:error, retry_after_ms}` when the IP or account is locked out."
  @spec check(:inet.ip_address(), String.t()) :: :ok | {:error, non_neg_integer()}
  def check(remote_ip, account) do
    with :ok <- RateLimit.peek(:login_ip, ip_id(remote_ip)),
         :ok <- RateLimit.peek(:login_account, account_id(account)) do
      :ok
    else
      {:deny, retry_after_ms, _spec} -> {:error, retry_after_ms}
    end
  end

  @doc "Records a failed login attempt for the IP and the account."
  @spec record_failure(:inet.ip_address(), String.t()) :: :ok
  def record_failure(remote_ip, account) do
    RateLimit.record(:login_ip, ip_id(remote_ip))
    RateLimit.record(:login_account, account_id(account))
    :ok
  end

  defp ip_id(remote_ip), do: remote_ip |> :inet.ntoa() |> to_string()

  defp account_id(account), do: account |> String.trim() |> String.downcase()
end
