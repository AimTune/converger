defmodule Converger.Auth.Signer do
  @moduledoc """
  Joken signers.

    * `signer/0`: the `secret_key_base` signer of the legacy tokens
      (`Converger.Auth.Token`), and of Converger tokens issued before #52
      (no `kid` header).
    * `converger_signer/0` and `converger_verifier/1`: the dedicated keys of
      Converger client tokens (`Converger.Auth.ConvergerToken`, ADR-0057).

  Converger token keys come from `config :converger, :token_signing_keys`
  (`TOKEN_SIGNING_KEYS`): a list of `{kid, secret}`. The first key signs every
  new token and puts its `kid` in the JWT header; every listed key verifies.
  Rotation is therefore: prepend a new key, wait one token lifetime, drop the
  old one. Without configured keys, tokens are signed with `secret_key_base`
  under the kid `"default"`.
  """

  @default_kid "default"

  def signer do
    Joken.Signer.create("HS256", secret_key_base())
  end

  @doc "The signer of new Converger tokens (the first configured key)."
  def converger_signer do
    [{kid, secret} | _] = signing_keys()
    Joken.Signer.create("HS256", secret, %{"kid" => kid})
  end

  @doc """
  The signer that verifies a Converger token, chosen by its `kid` header:
  `{:ok, signer}`, or `{:error, :unknown_kid}` for a kid that is not (or no
  longer) configured. A token without a kid (issued before #52) is verified
  with `secret_key_base` unless `:token_accept_unkeyed` is false.
  """
  def converger_verifier(token) do
    case Joken.peek_header(token) do
      {:ok, %{"kid" => kid}} when is_binary(kid) ->
        case List.keyfind(signing_keys(), kid, 0) do
          {^kid, secret} -> {:ok, Joken.Signer.create("HS256", secret)}
          nil -> {:error, :unknown_kid}
        end

      {:ok, _header} ->
        if Application.get_env(:converger, :token_accept_unkeyed, true),
          do: {:ok, signer()},
          else: {:error, :unknown_kid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The configured `{kid, secret}` pairs, signing key first."
  def signing_keys do
    case Application.get_env(:converger, :token_signing_keys, []) do
      [_ | _] = keys -> keys
      _ -> [{@default_kid, secret_key_base()}]
    end
  end

  defp secret_key_base,
    do: Application.get_env(:converger, ConvergerWeb.Endpoint)[:secret_key_base]
end
