defmodule Converger.Accounts.PasswordPolicy do
  @moduledoc """
  The password policy shared by admin and tenant users (issue #52, ADR-0058).
  It is applied whenever a password is set (account creation, password
  change, password reset); existing password hashes are not re-checked.

    * at least `min_length/0` characters (`:converger, :password_min_length`,
      env `PASSWORD_MIN_LENGTH`, default 12);
    * at most 72 bytes: bcrypt ignores everything after the 72nd byte, so a
      longer password would silently be truncated;
    * must not equal or contain the account's email address (case
      insensitive).
  """

  import Ecto.Changeset

  @default_min_length 12
  @max_bytes 72

  @doc "Minimum password length in characters."
  @spec min_length() :: pos_integer()
  def min_length do
    case Application.get_env(:converger, :password_min_length, @default_min_length) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_min_length
    end
  end

  @doc "Maximum password size in bytes (the bcrypt input limit)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Validates `field` (default `:password`) of `changeset` against the policy.
  The email is read from the changeset (`:email`).
  """
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field \\ :password) do
    min = min_length()

    changeset
    |> validate_length(field, min: min, message: "must be at least %{count} characters")
    |> validate_length(field,
      max: @max_bytes,
      count: :bytes,
      message: "must be at most %{count} bytes"
    )
    |> validate_change(field, fn ^field, password ->
      if contains_email?(password, get_field(changeset, :email)),
        do: [{field, "must not contain the email address"}],
        else: []
    end)
  end

  defp contains_email?(password, email) when is_binary(password) and is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    email != "" and String.contains?(String.downcase(password), email)
  end

  defp contains_email?(_, _), do: false
end
