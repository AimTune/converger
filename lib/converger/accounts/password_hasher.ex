defmodule Converger.Accounts.PasswordHasher do
  @moduledoc """
  Password hashing for admin and tenant users (ADR-0057).

  New hashes use the configured `Comeonin` implementation:

      config :converger, :password_hasher, Bcrypt  # default
      config :converger, :password_hasher, Pbkdf2  # pure Elixir, no C compiler

  `config/config.exs` picks `Pbkdf2` when `CONVERGER_PASSWORD_HASHER=pbkdf2`,
  which also leaves the `bcrypt_elixir` NIF out of the build (`mix.exs`).

  Verification picks the algorithm from the stored hash's prefix, so bcrypt and
  PBKDF2 hashes can coexist. A hash whose algorithm is not compiled in never
  verifies.
  """

  require Logger

  @doc "Hashes `password` with a random salt using the configured hasher."
  @spec hash_pwd_salt(String.t()) :: String.t()
  def hash_pwd_salt(password), do: hasher().hash_pwd_salt(password)

  @doc "Checks `password` against `hash`, whichever supported algorithm made it."
  @spec verify_pass(String.t(), String.t()) :: boolean()
  def verify_pass(password, hash) do
    case hasher_for(hash) do
      {:ok, module} -> verify_with(module, password, hash)
      :error -> no_user_verify()
    end
  end

  defp verify_with(module, password, hash) do
    if Code.ensure_loaded?(module) do
      module.verify_pass(password, hash)
    else
      Logger.warning(
        "password hash uses #{inspect(module)}, which is not compiled in " <>
          "(CONVERGER_PASSWORD_HASHER); the login is rejected"
      )

      no_user_verify()
    end
  end

  @doc "Spends the time of a verification and returns `false` (unknown user)."
  @spec no_user_verify() :: false
  def no_user_verify, do: hasher().no_user_verify()

  defp hasher, do: Application.get_env(:converger, :password_hasher, Bcrypt)

  defp hasher_for("$2" <> _), do: {:ok, Bcrypt}
  defp hasher_for("$pbkdf2-" <> _), do: {:ok, Pbkdf2}
  defp hasher_for(_), do: :error
end
