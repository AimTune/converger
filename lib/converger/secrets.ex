defmodule Converger.Secrets do
  @moduledoc """
  Helpers for handling secret values: hashing for lookups, masking for
  display and recursive redaction of sensitive keys (audit logs, UI).
  """

  @redacted "[REDACTED]"

  @sensitive_keys ~w(
    access_token api_key secret token password password_hash verify_token
    app_secret authorization x-api-key x-channel-token
  )

  @sensitive_suffixes ~w(_secret _token _hash)

  @doc "Placeholder that replaces sensitive values."
  def redacted, do: @redacted

  @doc """
  SHA-256 digest of a secret, used as an indexed lookup key so the secret
  itself never has to be stored or queried in plaintext.
  """
  @spec hash(binary()) :: binary()
  def hash(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  @doc "Returns true if a map key names a sensitive value."
  def sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  def sensitive_key?(key) when is_binary(key) do
    key = String.downcase(key)
    key in @sensitive_keys or String.ends_with?(key, @sensitive_suffixes)
  end

  def sensitive_key?(_), do: false

  @doc """
  Recursively replaces the values of sensitive keys with `"[REDACTED]"`
  in maps and lists. `nil` values are kept as `nil`.
  """
  def redact(%{__struct__: _} = struct), do: struct

  def redact(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      cond do
        sensitive_key?(k) and is_nil(v) -> {k, nil}
        sensitive_key?(k) -> {k, @redacted}
        true -> {k, redact(v)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  def redact(value), do: value

  @doc """
  Masks a secret for display, keeping only the last four characters
  (`"****abcd"`). Short values are fully masked.
  """
  def mask(nil), do: ""
  def mask(""), do: ""

  def mask(value) when is_binary(value) do
    if String.length(value) <= 8 do
      "****"
    else
      "****" <> String.slice(value, -4, 4)
    end
  end

  def mask(_), do: "****"
end
