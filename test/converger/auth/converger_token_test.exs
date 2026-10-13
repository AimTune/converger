defmodule Converger.Auth.ConvergerTokenTest do
  # Changes application env (signing keys, grace period).
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Auth.{ConvergerToken, RevocationCache, Revocations, RevokedToken, Signer}
  alias Converger.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    channel = channel_fixture(tenant_fixture())
    %{channel: channel}
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:converger, key)
    Application.put_env(:converger, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:converger, key, value)
        :error -> Application.delete_env(:converger, key)
      end
    end)
  end

  defp secret(char), do: String.duplicate(char, 32)

  describe "signing keys" do
    test "tokens carry the kid of the signing key", %{channel: channel} do
      {:ok, token, _claims} = ConvergerToken.generate_token(channel)
      assert {:ok, %{"kid" => "default", "alg" => "HS256"}} = Joken.peek_header(token)

      put_env(:token_signing_keys, [{"k2", secret("b")}, {"k1", secret("a")}])
      {:ok, token, _claims} = ConvergerToken.generate_token(channel)
      assert {:ok, %{"kid" => "k2"}} = Joken.peek_header(token)
      assert {:ok, _claims} = ConvergerToken.verify_token(token)
    end

    test "a token of a retired key verifies until the key is removed", %{channel: channel} do
      put_env(:token_signing_keys, [{"k1", secret("a")}])
      {:ok, old, _claims} = ConvergerToken.generate_token(channel)

      # Rotation: the new key signs, the old one still verifies.
      put_env(:token_signing_keys, [{"k2", secret("b")}, {"k1", secret("a")}])
      assert {:ok, _claims} = ConvergerToken.verify_token(old)

      put_env(:token_signing_keys, [{"k2", secret("b")}])
      assert {:error, :unknown_kid} = ConvergerToken.verify_token(old)
    end

    test "a known kid with a forged signature is rejected", %{channel: channel} do
      put_env(:token_signing_keys, [{"k1", secret("a")}])

      forged =
        Joken.generate_and_sign!(
          %{},
          %{"type" => "converger", "channel_id" => channel.id, "tenant_id" => channel.tenant_id},
          Joken.Signer.create("HS256", secret("z"), %{"kid" => "k1"})
        )

      assert {:error, :signature_error} = ConvergerToken.verify_token(forged)
    end

    test "rotating secret_key_base does not invalidate tokens of dedicated keys", %{
      channel: channel
    } do
      put_env(:token_signing_keys, [{"k1", secret("a")}])
      {:ok, token, _claims} = ConvergerToken.generate_token(channel)

      endpoint = Application.fetch_env!(:converger, ConvergerWeb.Endpoint)
      on_exit(fn -> Application.put_env(:converger, ConvergerWeb.Endpoint, endpoint) end)

      Application.put_env(
        :converger,
        ConvergerWeb.Endpoint,
        Keyword.put(endpoint, :secret_key_base, String.duplicate("x", 64))
      )

      assert {:ok, _claims} = ConvergerToken.verify_token(token)
    end

    test "tokens without a kid (pre-#52) verify with secret_key_base unless disabled", %{
      channel: channel
    } do
      claims = %{
        "type" => "converger",
        "channel_id" => channel.id,
        "tenant_id" => channel.tenant_id,
        "sub" => "converger_#{channel.id}"
      }

      {:ok, unkeyed, _claims} = ConvergerToken.generate_and_sign(claims, Signer.signer())
      {:ok, header} = Joken.peek_header(unkeyed)
      refute Map.has_key?(header, "kid")
      assert {:ok, _claims} = ConvergerToken.verify_token(unkeyed)

      put_env(:token_accept_unkeyed, false)
      assert {:error, :unknown_kid} = ConvergerToken.verify_token(unkeyed)
    end
  end

  describe "claims" do
    test "a generated token starts a family named after its jti", %{channel: channel} do
      {:ok, _token, claims} = ConvergerToken.generate_token(channel)
      assert is_binary(claims["jti"])
      assert claims["fam"] == claims["jti"]
      refute Map.has_key?(claims, "perms")
    end

    test "permissions are validated and normalised" do
      assert {:ok, nil} = ConvergerToken.cast_permissions(nil)

      assert {:ok, ["read", "typing"]} =
               ConvergerToken.cast_permissions(["typing", "read", "read"])

      assert {:error, _} = ConvergerToken.cast_permissions([])
      assert {:error, _} = ConvergerToken.cast_permissions(["admin"])
      assert {:error, _} = ConvergerToken.cast_permissions("read")
    end

    test "permitted?/2: no claim means every permission" do
      assert ConvergerToken.permitted?(%{}, "write")
      assert ConvergerToken.permitted?(%{"perms" => ["read"]}, "read")
      refute ConvergerToken.permitted?(%{"perms" => ["read"]}, "write")
    end

    test "a derived token keeps the family and permissions and never outlives its parent", %{
      channel: channel
    } do
      {:ok, _token, parent} =
        ConvergerToken.generate_token(channel,
          user_id: "u-1",
          permissions: ["read"],
          expires_in: 60
        )

      {:ok, _token, child} =
        ConvergerToken.generate_conversation_token(
          channel,
          Ecto.UUID.generate(),
          ConvergerToken.derived_opts(parent)
        )

      assert child["fam"] == parent["fam"]
      assert child["jti"] != parent["jti"]
      assert child["perms"] == ["read"]
      assert child["user_id"] == "u-1"
      assert child["exp"] <= parent["exp"]
    end
  end

  describe "refresh rotation" do
    test "refresh rotates: same family, old token valid only within the grace period", %{
      channel: channel
    } do
      {:ok, token, claims} = ConvergerToken.generate_token(channel, permissions: ["read"])

      assert {:ok, new_token, new_claims} = ConvergerToken.refresh_token(token)
      assert new_claims["fam"] == claims["fam"]
      assert new_claims["perms"] == ["read"]
      assert {:ok, _} = ConvergerToken.verify_token(new_token)

      # Within the grace period (default 30 s) the old token still works.
      assert {:ok, _} = ConvergerToken.verify_token(token)

      put_env(:token_rotation_grace_seconds, 0)
      Process.sleep(5)
      assert {:error, :token_rotated} = ConvergerToken.verify_token(token)
      assert {:ok, _} = ConvergerToken.verify_token(new_token)
    end

    test "a second refresh within the grace period is not reuse", %{channel: channel} do
      {:ok, token, _claims} = ConvergerToken.generate_token(channel)

      assert {:ok, first, _} = ConvergerToken.refresh_token(token)
      assert {:ok, second, _} = ConvergerToken.refresh_token(token)
      assert {:ok, _} = ConvergerToken.verify_token(first)
      assert {:ok, _} = ConvergerToken.verify_token(second)
    end

    test "refreshing a rotated token after the grace period revokes the family", %{
      channel: channel
    } do
      put_env(:token_rotation_grace_seconds, 0)
      {:ok, token, _claims} = ConvergerToken.generate_token(channel)

      {:ok, conversation_token, _} =
        ConvergerToken.generate_conversation_token(
          channel,
          Ecto.UUID.generate(),
          ConvergerToken.derived_opts(elem(ConvergerToken.verify_token(token), 1))
        )

      assert {:ok, legit, _} = ConvergerToken.refresh_token(token)
      Process.sleep(5)

      # The stolen copy is refreshed: reuse.
      assert {:error, :token_reused} = ConvergerToken.refresh_token(token)

      # Every token of the family is now revoked, the legitimate one too.
      assert {:error, :token_revoked} = ConvergerToken.verify_token(legit)
      assert {:error, :token_revoked} = ConvergerToken.verify_token(conversation_token)

      # Other families are unaffected.
      {:ok, other, _} = ConvergerToken.generate_token(channel)
      assert {:ok, _} = ConvergerToken.verify_token(other)
    end
  end

  describe "revocation" do
    test "revoking a family rejects every token in it", %{channel: channel} do
      {:ok, token, claims} = ConvergerToken.generate_token(channel)
      {:ok, refreshed, _} = ConvergerToken.refresh_token(token)

      assert :ok = Revocations.revoke_family(claims)
      assert {:error, :token_revoked} = ConvergerToken.verify_token(token)
      assert {:error, :token_revoked} = ConvergerToken.verify_token(refreshed)
    end

    test "revoking a user rejects their tokens issued so far, not later ones", %{
      channel: channel
    } do
      {:ok, alice, _} = ConvergerToken.generate_token(channel, user_id: "alice")
      {:ok, bob, _} = ConvergerToken.generate_token(channel, user_id: "bob")

      assert :ok = Revocations.revoke_user(channel.tenant_id, channel.id, "alice")
      assert {:error, :token_revoked} = ConvergerToken.verify_token(alice)
      assert {:ok, _} = ConvergerToken.verify_token(bob)

      # `iat` has one-second resolution: a token of the next second is new.
      Process.sleep(1_100)
      {:ok, alice_again, _} = ConvergerToken.generate_token(channel, user_id: "alice")
      assert {:ok, _} = ConvergerToken.verify_token(alice_again)
    end

    test "the cache is rebuilt from the database", %{channel: channel} do
      {:ok, token, claims} = ConvergerToken.generate_token(channel)
      Sandbox.allow(Repo, self(), Process.whereis(RevocationCache))
      :ok = Revocations.revoke_family(claims)

      # Let the cache process handle its own broadcast first (calls are
      # ordered after it), then forget the entry as a node that missed it.
      :ok = RevocationCache.sync()
      :ets.delete(RevocationCache, "fam:" <> claims["fam"])
      assert {:ok, _} = ConvergerToken.verify_token(token)

      # A node that missed the broadcast catches up on its next sync: the
      # overlap re-reads rows revoked since shortly before the last sync.
      :ok = RevocationCache.sync()
      assert {:error, :token_revoked} = ConvergerToken.verify_token(token)
    end

    test "a revocation broadcast reaches the cache", %{channel: channel} do
      {:ok, token, claims} = ConvergerToken.generate_token(channel)

      row = %RevokedToken{
        key: "fam:" <> claims["fam"],
        kind: "revoked",
        revoked_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      }

      # As if another node had revoked it.
      Phoenix.PubSub.broadcast(Converger.PubSub, RevocationCache.topic(), {
        :token_revocations,
        [row]
      })

      # The cache process handles the broadcast; a call after it is ordered.
      Sandbox.allow(Repo, self(), Process.whereis(RevocationCache))
      :ok = RevocationCache.sync()
      assert {:error, :token_revoked} = ConvergerToken.verify_token(token)
    end

    test "prune deletes rows whose tokens have all expired", %{channel: channel} do
      {:ok, _token, claims} = ConvergerToken.generate_token(channel)
      :ok = Revocations.revoke_family(claims)

      assert Revocations.prune(DateTime.utc_now()) == 0
      assert Revocations.prune(DateTime.add(DateTime.utc_now(), 3_600)) == 1
    end
  end
end
