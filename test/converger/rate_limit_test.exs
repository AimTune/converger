defmodule Converger.RateLimitTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.RateLimit
  alias Converger.Tenants

  defp unique_id, do: "id-#{System.unique_integer([:positive])}"

  describe "limit_for/2" do
    test "falls back to the built-in defaults" do
      assert RateLimit.limit_for(:activity_create) == {100, 1_000}
      assert RateLimit.limit_for(:upload) == {10, 1_000}
      assert RateLimit.limit_for(:inbound) == {500, 1_000}
      assert RateLimit.limit_for(:token_generate) == {10, 60_000}
      assert RateLimit.limit_for(:login_ip) == {5, 60_000}
      assert RateLimit.limit_for(:login_account) == {5, 60_000}
    end

    test "uses the caller default for unknown buckets" do
      assert RateLimit.limit_for("adhoc", default: {3, 500}) == {3, 500}
    end

    test "a tenant override in the database wins over the defaults" do
      tenant = tenant_fixture()

      {:ok, tenant} =
        Tenants.update_tenant_limits(tenant, %{
          "activity_create" => %{"limit" => 2, "scale_ms" => 5_000}
        })

      assert RateLimit.limit_for(:activity_create, tenant: tenant) == {2, 5_000}
      assert RateLimit.limit_for(:activity_create, tenant: tenant.id) == {2, 5_000}
      # other buckets keep the defaults
      assert RateLimit.limit_for(:upload, tenant: tenant.id) == {10, 1_000}
    end

    test "resolves the override through the channel" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)

      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{inbound: %{limit: 7, scale_ms: 1_000}})

      assert RateLimit.limit_for(:inbound, tenant: {:channel, channel.id}) == {7, 1_000}
      assert RateLimit.limit_for(:inbound, tenant: {:channel, "not-a-uuid"}) == {500, 1_000}
    end

    test "updating the limits invalidates the cached override" do
      tenant = tenant_fixture()

      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{"upload" => %{"limit" => 1, "scale_ms" => 1_000}})

      assert RateLimit.limit_for(:upload, tenant: tenant.id) == {1, 1_000}

      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{"upload" => %{"limit" => 4, "scale_ms" => 1_000}})

      assert RateLimit.limit_for(:upload, tenant: tenant.id) == {4, 1_000}
    end
  end

  describe "update_tenant_limits/2 validation" do
    test "rejects unknown buckets and invalid specs" do
      tenant = tenant_fixture()

      assert {:error, changeset} =
               Tenants.update_tenant_limits(tenant, %{"bogus" => %{"limit" => 1, "scale_ms" => 1}})

      assert "unknown rate limit bucket \"bogus\"" in errors_on(changeset).limits

      assert {:error, _} =
               Tenants.update_tenant_limits(tenant, %{
                 "upload" => %{"limit" => 0, "scale_ms" => 1}
               })

      assert {:error, _} = Tenants.update_tenant_limits(tenant, %{"upload" => 5})
    end
  end

  describe "check/3" do
    test "allows up to the limit, then denies with a retry-after and telemetry" do
      id = unique_id()
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "rate-limit-test-#{inspect(ref)}",
        [:converger, :rate_limit, :exceeded],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:exceeded, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("rate-limit-test-#{inspect(ref)}") end)

      assert {:allow, 1} = RateLimit.check("test_bucket", id, default: {2, 60_000})
      assert {:allow, 2} = RateLimit.check("test_bucket", id, default: {2, 60_000})

      assert {:deny, retry_after_ms, {2, 60_000}} =
               RateLimit.check("test_bucket", id, default: {2, 60_000})

      assert retry_after_ms in 0..60_000

      key = "test_bucket:#{id}"

      assert_receive {:exceeded, %{count: 1},
                      %{bucket: "test_bucket", key: ^key, limit: 2, scale_ms: 60_000}}
    end
  end

  describe "peek/3 and record/3" do
    test "denies once the recorded events reach the limit" do
      id = unique_id()

      for _ <- 1..4 do
        assert :ok = RateLimit.peek(:login_account, id)
        RateLimit.record(:login_account, id)
      end

      assert :ok = RateLimit.peek(:login_account, id)
      RateLimit.record(:login_account, id)
      assert {:deny, _retry_after, {5, 60_000}} = RateLimit.peek(:login_account, id)
    end
  end
end
