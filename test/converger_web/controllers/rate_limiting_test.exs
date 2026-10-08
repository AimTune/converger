defmodule ConvergerWeb.RateLimitingTest do
  use ConvergerWeb.ConnCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Accounts, Tenants}

  defp unique_ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  describe "hot paths" do
    test "activity create is limited per tenant using the tenant override", %{conn: conn} do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)

      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{
          "activity_create" => %{"limit" => 1, "scale_ms" => 60_000}
        })

      post_activity = fn ->
        conn
        |> put_req_header("x-api-key", tenant.api_key)
        |> post(~p"/api/v1/conversations/#{conversation.id}/activities", %{
          "sender" => "user-1",
          "text" => "hi"
        })
      end

      assert json_response(post_activity.(), 201)
      limited = post_activity.()
      assert json_response(limited, 429)["error"] =~ "Too many requests"
      assert [_seconds] = get_resp_header(limited, "retry-after")
    end

    test "inbound webhooks are limited per channel", %{conn: conn} do
      tenant = tenant_fixture()
      channel = webhook_channel_fixture(tenant, %{mode: "duplex"})
      other_channel = webhook_channel_fixture(tenant, %{mode: "duplex"})

      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{
          "inbound" => %{"limit" => 1, "scale_ms" => 60_000}
        })

      inbound = fn ch ->
        signed_post(conn, ~p"/api/v1/channels/#{ch.id}/inbound", ch, %{
          "text" => "hello",
          "sender" => "user1"
        })
      end

      assert json_response(inbound.(channel), 201)
      assert response(inbound.(channel), 429)
      # a different channel has its own bucket
      assert json_response(inbound.(other_channel), 201)
    end
  end

  describe "portal login lockout" do
    setup do
      tenant = tenant_fixture()

      {:ok, user} =
        Accounts.create_tenant_user(%{
          email: "user-#{System.unique_integer([:positive])}@test.com",
          password: "correctpassword",
          name: "User",
          tenant_id: tenant.id
        })

      %{tenant: tenant, user: user}
    end

    defp portal_login(ip, tenant, email, password) do
      build_conn()
      |> Map.put(:remote_ip, ip)
      |> post(~p"/portal/login", %{
        "tenant_name" => tenant.name,
        "email" => email,
        "password" => password
      })
    end

    test "locks the account after 5 failures, even with the right password",
         %{tenant: tenant, user: user} do
      for _ <- 1..5 do
        conn = portal_login(unique_ip(), tenant, user.email, "wrong-password")
        assert html_response(conn, 200) =~ "Invalid tenant, email, or password."
      end

      conn = portal_login(unique_ip(), tenant, user.email, "correctpassword")
      assert html_response(conn, 429) =~ "Too many failed login attempts"
      assert [_] = get_resp_header(conn, "retry-after")
    end

    test "locks the client IP after 5 failures across accounts", %{tenant: tenant, user: user} do
      ip = unique_ip()

      for n <- 1..5 do
        conn = portal_login(ip, tenant, "nobody-#{n}@test.com", "wrong-password")
        assert html_response(conn, 200)
      end

      assert html_response(portal_login(ip, tenant, user.email, "correctpassword"), 429)

      # another IP can still log in to the (not locked) account
      conn = portal_login(unique_ip(), tenant, user.email, "correctpassword")
      assert redirected_to(conn) == "/portal"
    end

    test "successful logins are not counted", %{tenant: tenant, user: user} do
      ip = unique_ip()

      for _ <- 1..6 do
        assert redirected_to(portal_login(ip, tenant, user.email, "correctpassword")) == "/portal"
      end
    end
  end

  describe "admin login lockout" do
    test "locks the admin account after 5 failures" do
      {:ok, admin} =
        Accounts.create_admin_user(%{
          email: "admin-#{System.unique_integer([:positive])}@test.com",
          password: "correctpassword",
          name: "Admin",
          role: "super_admin"
        })

      login = fn password ->
        build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> post(~p"/admin/login", %{"email" => admin.email, "password" => password})
      end

      for _ <- 1..5 do
        assert html_response(login.("wrong-password"), 200) =~ "Invalid email or password."
      end

      assert html_response(login.("correctpassword"), 429) =~ "Too many failed login attempts"
    end
  end
end
