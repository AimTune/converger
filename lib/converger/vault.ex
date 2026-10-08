defmodule Converger.Vault do
  @moduledoc """
  Cloak vault used to encrypt secrets at rest (channel secrets and configs).

  Configuration (`config :converger, Converger.Vault`):

    * `:key` - base64-encoded 32 byte AES key used for new encryptions.
    * `:retired_keys` - list of base64-encoded keys that are still accepted
      for decryption (key rotation).

  Every key gets a cipher tag derived from its fingerprint, so ciphertexts
  are self-describing and any configured key can decrypt them. To rotate:
  generate a new key, set it as `CLOAK_KEY`, move the old one into
  `CLOAK_RETIRED_KEYS`, deploy, then run
  `bin/converger eval "Converger.Release.reencrypt_secrets()"`. Once that
  has finished the retired key can be removed.
  """

  use Cloak.Vault, otp_app: :converger

  @impl GenServer
  def init(config) do
    {:ok, Keyword.merge(config, ciphers: ciphers(config), json_library: Jason)}
  end

  @doc """
  Vault configuration built from the application environment. Usable
  without the vault process running (e.g. from migrations).
  """
  def cipher_config do
    config = Application.get_env(:converger, __MODULE__, [])
    [ciphers: ciphers(config), json_library: Jason]
  end

  @doc "Encrypts without requiring the vault process (for migrations)."
  def encrypt_offline!(plaintext), do: Cloak.Vault.encrypt!(cipher_config(), plaintext)

  @doc "Decrypts without requiring the vault process (for migrations)."
  def decrypt_offline!(ciphertext), do: Cloak.Vault.decrypt!(cipher_config(), ciphertext)

  @doc "Generates a new random base64-encoded key suitable for `CLOAK_KEY`."
  def generate_key, do: :crypto.strong_rand_bytes(32) |> Base.encode64()

  # The `:"retired_N"` labels come from the position in the operator-configured
  # CLOAK_RETIRED_KEYS list (a handful at most), never from request input.
  # sobelow_skip ["DOS.BinToAtom"]
  defp ciphers(config) do
    default =
      Keyword.get(config, :key) ||
        raise ArgumentError, """
        no encryption key configured for Converger.Vault.
        Set the CLOAK_KEY environment variable to a base64-encoded 32 byte key,
        e.g. generated with: mix run -e 'IO.puts(Converger.Vault.generate_key())'
        """

    retired = Keyword.get(config, :retired_keys, [])

    [default | retired]
    |> Enum.map(&decode_key!/1)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.map(fn {key, index} ->
      label = if index == 0, do: :default, else: :"retired_#{index}"
      {label, {Cloak.Ciphers.AES.GCM, tag: tag(key), key: key, iv_length: 12}}
    end)
  end

  defp decode_key!(key) when is_binary(key) do
    case Base.decode64(String.trim(key)) do
      {:ok, <<_::binary-size(32)>> = raw} -> raw
      _ -> raise ArgumentError, "Converger.Vault keys must be base64-encoded 32 byte values"
    end
  end

  defp tag(key) do
    "AES.GCM." <> (:crypto.hash(:sha256, key) |> binary_part(0, 4) |> Base.encode16())
  end
end
