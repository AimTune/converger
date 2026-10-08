defmodule Converger.SecretsAtRestTest do
  use Converger.DataCase, async: false

  alias Converger.{Channels, Repo, Secrets, Tenants, Vault}
  alias Converger.Channels.Channel
  alias Converger.Tenants.Tenant

  import Converger.TenantsFixtures

  defp raw_channel(id) do
    %{rows: [[secret, config, secret_hash]]} =
      Repo.query!("SELECT secret, config, secret_hash FROM channels WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    %{secret: secret, config: config, secret_hash: secret_hash}
  end

  defp whatsapp_channel(tenant) do
    {:ok, channel} =
      Channels.create_channel(%{
        name: "WA #{System.unique_integer()}",
        tenant_id: tenant.id,
        type: "whatsapp_meta",
        mode: "duplex",
        config: %{
          "phone_number_id" => "1234567890",
          "access_token" => "EAAG-plaintext-access-token",
          "verify_token" => "plaintext-verify-token",
          "app_secret" => "plaintext-app-secret"
        }
      })

    channel
  end

  describe "channel encryption at rest" do
    test "channels.config and channels.secret are stored as ciphertext" do
      channel = whatsapp_channel(tenant_fixture())
      raw = raw_channel(channel.id)

      assert is_binary(raw.config)
      refute raw.config =~ "EAAG-plaintext-access-token"
      refute raw.config =~ "plaintext-verify-token"
      refute raw.config =~ "plaintext-app-secret"
      refute raw.config =~ "1234567890"
      assert {:error, _} = Jason.decode(raw.config)

      assert is_binary(raw.secret)
      refute raw.secret =~ channel.secret
      assert raw.secret_hash == :crypto.hash(:sha256, channel.secret)
    end

    test "encrypted fields are decrypted transparently on load" do
      channel = whatsapp_channel(tenant_fixture())
      loaded = Channels.get_channel!(channel.id)

      assert loaded.config["access_token"] == "EAAG-plaintext-access-token"
      assert loaded.config["verify_token"] == "plaintext-verify-token"
      assert loaded.secret == channel.secret
    end

    test "encrypted fields are redacted from inspect output" do
      channel = whatsapp_channel(tenant_fixture())
      refute inspect(channel) =~ channel.secret
      refute inspect(channel) =~ "EAAG-plaintext-access-token"
    end

    test "get_channel_by_secret/1 looks up by hash" do
      channel = whatsapp_channel(tenant_fixture())

      assert %Channel{id: id} = Channels.get_channel_by_secret(channel.secret)
      assert id == channel.id
      assert Channels.get_channel_by_secret("wrong") == nil
      assert Channels.get_channel_by_secret("") == nil
      assert Channels.get_channel_by_secret(nil) == nil
    end

    test "changing the secret updates the lookup hash" do
      channel = whatsapp_channel(tenant_fixture())
      old_secret = channel.secret
      {:ok, _} = Channels.update_channel(channel, %{secret: "a-brand-new-secret"})

      assert Channels.get_channel_by_secret(old_secret) == nil
      assert Channels.get_channel_by_secret("a-brand-new-secret").id == channel.id
      assert {:ok, _} = Channels.validate_channel_secret(channel.id, "a-brand-new-secret")
      assert {:error, :unauthorized} = Channels.validate_channel_secret(channel.id, old_secret)
    end
  end

  describe "encryption key rotation" do
    setup do
      original = Application.get_env(:converger, Vault)
      on_exit(fn -> Application.put_env(:converger, Vault, original) end)
      %{original: original}
    end

    test "data encrypted with a retired key is still decryptable", %{original: original} do
      old_key = Keyword.fetch!(original, :key)
      ciphertext = Vault.encrypt_offline!("rotate-me")

      new_key = Vault.generate_key()
      Application.put_env(:converger, Vault, key: new_key, retired_keys: [old_key])

      assert Vault.decrypt_offline!(ciphertext) == "rotate-me"

      reencrypted = Vault.encrypt_offline!("rotate-me")
      Application.put_env(:converger, Vault, key: new_key)
      assert Vault.decrypt_offline!(reencrypted) == "rotate-me"
      assert_raise Cloak.MissingCipher, fn -> Vault.decrypt_offline!(ciphertext) end
    end

    test "reencrypt_all/0 rewrites every channel" do
      channel = whatsapp_channel(tenant_fixture())
      before = raw_channel(channel.id)

      assert Channels.reencrypt_all() >= 1

      after_rotation = raw_channel(channel.id)
      # Fresh IVs mean new ciphertext for the same plaintext.
      assert before.config != after_rotation.config
      assert before.secret != after_rotation.secret

      assert Channels.get_channel!(channel.id).config["access_token"] ==
               "EAAG-plaintext-access-token"
    end

    test "rejects keys that are not 32 bytes" do
      Application.put_env(:converger, Vault, key: Base.encode64("too-short"))
      assert_raise ArgumentError, fn -> Vault.cipher_config() end
    end
  end

  describe "tenant API keys" do
    test "keys are generated with a public prefix and stored hashed" do
      tenant = tenant_fixture()

      assert String.starts_with?(tenant.api_key, "cvg_live_")
      assert tenant.api_key_hash == Secrets.hash(tenant.api_key)
      assert tenant.api_key_prefix == String.slice(tenant.api_key, 0, 13)
      assert Tenant.masked_api_key(tenant) == tenant.api_key_prefix <> "****"

      %{columns: columns, rows: [row]} =
        Repo.query!("SELECT * FROM tenants WHERE id = $1", [Ecto.UUID.dump!(tenant.id)])

      refute "api_key" in columns
      refute Enum.any?(row, &(is_binary(&1) and &1 == tenant.api_key))

      # The plaintext key is never available after a reload.
      assert Tenants.get_tenant!(tenant.id).api_key == nil
    end

    test "get_tenant_by_api_key/1 authenticates with the plaintext key" do
      tenant = tenant_fixture()
      assert Tenants.get_tenant_by_api_key(tenant.api_key).id == tenant.id
      assert Tenants.get_tenant_by_api_key("cvg_live_wrong") == nil
      assert Tenants.get_tenant_by_api_key("") == nil
      assert Tenants.get_tenant_by_api_key(nil) == nil
    end

    test "rotation keeps the old key valid during the grace period" do
      tenant = tenant_fixture()
      old_key = tenant.api_key

      {:ok, rotated} = Tenants.rotate_api_key(tenant)
      new_key = rotated.api_key

      assert new_key != old_key
      assert String.starts_with?(new_key, "cvg_live_")
      assert Tenants.get_tenant_by_api_key(new_key).id == tenant.id
      assert Tenants.get_tenant_by_api_key(old_key).id == tenant.id

      expected_expiry = DateTime.add(DateTime.utc_now(), 24 * 60 * 60, :second)
      assert abs(DateTime.diff(rotated.previous_api_key_expires_at, expected_expiry)) < 5
    end

    test "old key stops working once the grace period has expired" do
      tenant = tenant_fixture()
      old_key = tenant.api_key

      {:ok, rotated} = Tenants.rotate_api_key(tenant, grace_period: -1)

      assert Tenants.get_tenant_by_api_key(old_key) == nil
      assert Tenants.get_tenant_by_api_key(rotated.api_key).id == tenant.id
    end

    test "rotating again invalidates the key from two rotations ago" do
      tenant = tenant_fixture()
      first = tenant.api_key
      {:ok, t2} = Tenants.rotate_api_key(tenant)
      {:ok, t3} = Tenants.rotate_api_key(t2)

      assert Tenants.get_tenant_by_api_key(first) == nil
      assert Tenants.get_tenant_by_api_key(t2.api_key).id == tenant.id
      assert Tenants.get_tenant_by_api_key(t3.api_key).id == tenant.id
    end

    test "API requests work with both keys during the grace period" do
      tenant = tenant_fixture()
      {:ok, rotated} = Tenants.rotate_api_key(tenant)

      for key <- [tenant.api_key, rotated.api_key] do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-api-key", key)
          |> ConvergerWeb.Plugs.TenantAuth.call([])

        refute conn.halted
        assert conn.assigns.tenant.id == tenant.id
      end
    end
  end

  describe "Secrets helpers" do
    test "redact/1 redacts nested sensitive keys" do
      input = %{
        "name" => "x",
        "config" => %{
          "access_token" => "a",
          "api_key" => "b",
          "verify_token" => "c",
          "app_secret" => "d",
          "client_secret" => "e",
          "refresh_token" => "f",
          "password" => "g",
          "headers" => %{"Authorization" => "Bearer h"},
          "list" => [%{"token" => "i", "ok" => "j"}],
          "missing_token" => nil
        }
      }

      redacted = Secrets.redact(input)
      config = redacted["config"]

      for key <-
            ~w(access_token api_key verify_token app_secret client_secret refresh_token password) do
        assert config[key] == "[REDACTED]"
      end

      assert config["headers"]["Authorization"] == "[REDACTED]"
      assert [%{"token" => "[REDACTED]", "ok" => "j"}] = config["list"]
      assert config["missing_token"] == nil
      assert redacted["name"] == "x"
    end

    test "mask/1 keeps only the last four characters" do
      assert Secrets.mask("EAAG-abcdefgh-1234") == "****1234"
      assert Secrets.mask("short") == "****"
      assert Secrets.mask(nil) == ""
    end
  end
end
