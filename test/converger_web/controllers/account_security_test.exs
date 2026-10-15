defmodule ConvergerWeb.AccountSecurityTest do
  @moduledoc """
  Server-side sessions, TOTP 2FA login/enrollment and required 2FA for the
  admin panel and the tenant portal (issue #52, ADR-0058).
  """
  # Changes the global admin IP whitelist and :require_2fa_roles.
  use ConvergerWeb.ConnCase, async: false

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Converger.Accounts.{AdminUser, Sessions, TenantUser, TOTP, UserSession}
  alias Converger.{AuditLogs, Repo}

  setup %{conn: conn} do
    # Each test logs in from its own IP, so login throttling counters of
    # other tests never interfere.
    put_env(:admin_ip_whitelist, ["127.0.0.1", "::1", "10.0.0.0/8"])
    %{conn: %{conn | remote_ip: unique_ip()}}
  end

  defp put_env(key, value) do
    previous = Application.get_env(:converger, key)
    Application.put_env(:converger, key, value)
    on_exit(fn -> Application.put_env(:converger, key, previous) end)
  end

  defp admin_login(conn, admin, password \\ valid_password()) do
    post(conn, ~p"/admin/login", %{"email" => admin.email, "password" => password})
  end

  defp portal_login(conn, tenant, user) do
    post(conn, ~p"/portal/login", %{
      "tenant_name" => tenant.name,
      "email" => user.email,
      "password" => valid_password()
    })
  end

  # Follows a login: a fresh conn carrying the cookie session of `conn`.
  defp continue(conn), do: recycle(conn) |> Map.put(:remote_ip, conn.remote_ip)

  describe "server-side sessions" do
    test "login creates a session row; the cookie only holds its token", %{conn: conn} do
      admin = admin_user_fixture()
      conn = admin_login(conn, admin)
      assert redirected_to(conn) == "/admin"

      assert [%UserSession{user_type: "admin", ip: ip} = session] =
               Sessions.list("admin", admin.id)

      assert ip =~ "10."
      token = get_session(conn, :admin_session_token)
      assert session.token_hash == :crypto.hash(:sha256, token)
      assert get_session(conn, :live_socket_id) == "user_sessions:" <> session.id
      refute get_session(conn, :admin_user_id)

      assert conn |> continue() |> get(~p"/admin/security") |> html_response(200) =~
               "Active sessions"
    end

    test "logout deletes the session row", %{conn: conn} do
      admin = admin_user_fixture()
      conn = admin_login(conn, admin) |> continue()
      conn = delete(conn, ~p"/admin/logout")
      assert redirected_to(conn) == "/admin/login"
      assert Sessions.list("admin", admin.id) == []
    end

    test "an expired session is rejected by the plug and the LiveView hook", %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_admin(conn, admin)
      [session] = Sessions.list("admin", admin.id)

      Repo.update_all(
        from(s in UserSession, where: s.id == ^session.id),
        set: [
          last_seen_at: DateTime.add(DateTime.utc_now(), -Sessions.idle_timeout_seconds() - 1)
        ]
      )

      assert conn |> get(~p"/admin/tenants") |> redirected_to() == "/admin/login"
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin")
    end

    test "a stale cookie with a user id (pre-ADR-0058 session) is not accepted", %{conn: conn} do
      admin = admin_user_fixture()
      conn = init_test_session(conn, %{admin_user_id: admin.id})
      assert conn |> get(~p"/admin/tenants") |> redirected_to() == "/admin/login"
    end

    test "log out everywhere ends other sessions and disconnects their LiveViews",
         %{conn: conn} do
      admin = admin_user_fixture()
      laptop = log_in_admin(build_conn(), admin)
      phone = log_in_admin(conn, admin)

      assert {:ok, _view, _html} = live(laptop, ~p"/admin")
      [laptop_session | _] = Sessions.list("admin", admin.id) |> Enum.reverse()
      ConvergerWeb.Endpoint.subscribe(Sessions.live_socket_id(laptop_session))

      conn = delete(phone, ~p"/admin/security/sessions")
      assert redirected_to(conn) == "/admin/login"

      assert Sessions.list("admin", admin.id) == []
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert laptop |> get(~p"/admin/tenants") |> redirected_to() == "/admin/login"
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(laptop, ~p"/admin")

      assert [%{action: "revoke_sessions"}] =
               AuditLogs.list_audit_logs(%{"action" => "revoke_sessions"})
    end

    test "a single other session can be signed out from the security page", %{conn: conn} do
      admin = admin_user_fixture()
      other = log_in_admin(build_conn(), admin)
      conn = log_in_admin(conn, admin)
      [_, _] = sessions = Sessions.list("admin", admin.id)
      other_id = get_session(other |> get(~p"/admin/security"), :live_socket_id)
      other_session = Enum.find(sessions, &("user_sessions:" <> &1.id == other_id))

      conn = delete(conn, ~p"/admin/security/sessions/#{other_session.id}")
      assert redirected_to(conn) == "/admin/security"
      assert [_] = Sessions.list("admin", admin.id)
      assert other |> get(~p"/admin/tenants") |> redirected_to() == "/admin/login"
    end

    test "portal: log out everywhere and own password change", %{conn: conn} do
      tenant = tenant_fixture()
      user = tenant_user_fixture(tenant)
      other = log_in_tenant_user(build_conn(), user)
      conn = log_in_tenant_user(conn, user)

      conn =
        put(conn, ~p"/portal/security/password", %{
          "password" => %{
            "current_password" => valid_password(),
            "password" => "a-new-portal-password",
            "password_confirmation" => "a-new-portal-password"
          }
        })

      assert redirected_to(conn) == "/portal/security"
      # the current session stays, the other one ends
      assert conn |> continue() |> get(~p"/portal/security") |> html_response(200)
      assert other |> get(~p"/portal/security") |> redirected_to() == "/portal/login"

      conn = conn |> continue() |> delete(~p"/portal/security/sessions")
      assert redirected_to(conn) == "/portal/login"
      assert Sessions.list("tenant", user.id) == []
    end

    test "deactivating an admin from the users page ends their sessions", %{conn: conn} do
      boss = admin_user_fixture()
      target = admin_user_fixture(%{role: "admin"})
      target_conn = log_in_admin(build_conn(), target)

      {:ok, view, _} = live(log_in_admin(conn, boss), ~p"/admin/users")

      view
      |> element(~s{button[phx-click="toggle_status"][phx-value-id="#{target.id}"]})
      |> render_click()

      assert Sessions.list("admin", target.id) == []
      assert target_conn |> get(~p"/admin/tenants") |> redirected_to() == "/admin/login"
    end
  end

  describe "2FA login" do
    test "admins with 2FA need a code after the password", %{conn: conn} do
      admin = admin_user_fixture() |> enable_totp()

      conn = admin_login(conn, admin)
      assert redirected_to(conn) == "/admin/login/totp"
      # no session yet: the admin panel is still closed
      assert Sessions.list("admin", admin.id) == []
      refute get_session(conn, :admin_session_token)
      assert conn |> continue() |> get(~p"/admin") |> redirected_to() == "/admin/login"

      conn = conn |> continue()
      assert conn |> get(~p"/admin/login/totp") |> html_response(200) =~ "authenticator app"

      conn = post(conn, ~p"/admin/login/totp", %{"code" => "000000"})
      assert html_response(conn, 422) =~ "Invalid or already used code"
      assert Sessions.list("admin", admin.id) == []

      code = totp_code(admin)
      conn = conn |> continue() |> post(~p"/admin/login/totp", %{"code" => code})
      assert redirected_to(conn) == "/admin"
      assert [_] = Sessions.list("admin", admin.id)
      assert conn |> continue() |> get(~p"/admin/tenants") |> html_response(200)

      # the same code cannot be used for a second login
      second = admin_login(build_conn() |> Map.put(:remote_ip, unique_ip()), admin) |> continue()
      assert second |> post(~p"/admin/login/totp", %{"code" => code}) |> html_response(422)
    end

    test "the code step is throttled per account", %{conn: conn} do
      admin = admin_user_fixture() |> enable_totp()
      pending = admin_login(conn, admin) |> continue()

      for _ <- 1..5 do
        assert pending |> post(~p"/admin/login/totp", %{"code" => "111111"}) |> html_response(422)
      end

      conn = post(pending, ~p"/admin/login/totp", %{"code" => totp_code(admin)})
      assert html_response(conn, 429) =~ "Too many failed attempts"
      assert [_seconds] = get_resp_header(conn, "retry-after")

      # also from another IP: the lock is on the account
      other =
        admin_login(build_conn() |> Map.put(:remote_ip, unique_ip()), admin) |> continue()

      assert other |> post(~p"/admin/login/totp", %{"code" => totp_code(admin)}) |> response(429)
    end

    test "a pending login expires after five minutes", %{conn: conn} do
      admin = admin_user_fixture() |> enable_totp()

      conn =
        conn
        |> init_test_session(%{
          "pending_2fa" => %{
            "type" => "admin",
            "id" => admin.id,
            "at" => System.system_time(:second) - 301
          }
        })
        |> post(~p"/admin/login/totp", %{"code" => totp_code(admin)})

      assert redirected_to(conn) == "/admin/login"
    end

    test "a pending admin login does not open the portal", %{conn: conn} do
      admin = admin_user_fixture() |> enable_totp()
      conn = admin_login(conn, admin) |> continue()
      assert conn |> get(~p"/portal/login/totp") |> redirected_to() == "/portal/login"
    end

    test "portal users with 2FA need a code", %{conn: conn} do
      tenant = tenant_fixture()
      user = tenant_user_fixture(tenant) |> enable_totp()

      conn = portal_login(conn, tenant, user)
      assert redirected_to(conn) == "/portal/login/totp"

      conn = conn |> continue() |> post(~p"/portal/login/totp", %{"code" => totp_code(user)})
      assert redirected_to(conn) == "/portal"
      assert [_] = Sessions.list("tenant", user.id)
    end
  end

  describe "2FA enrollment" do
    test "an admin enrolls from the security page", %{conn: conn} do
      admin = admin_user_fixture()
      conn = log_in_admin(conn, admin)

      assert conn |> get(~p"/admin/security") |> html_response(200) =~
               "Set up two-factor authentication"

      conn = post(conn, ~p"/admin/security/totp/setup")
      assert redirected_to(conn) =~ "/admin/security"

      html = conn |> continue() |> get(~p"/admin/security") |> html_response(200)
      admin = Repo.get!(AdminUser, admin.id)
      assert html =~ TOTP.base32_secret(admin)
      assert html =~ "otpauth://totp/"

      assert conn
             |> continue()
             |> post(~p"/admin/security/totp", %{"code" => "000000"})
             |> html_response(422) =~ "not valid"

      conn = conn |> continue() |> post(~p"/admin/security/totp", %{"code" => totp_code(admin)})
      assert redirected_to(conn) == "/admin/security"
      assert TOTP.enabled?(Repo.get!(AdminUser, admin.id))

      # turning it off needs the password or a code
      assert conn
             |> continue()
             |> delete(~p"/admin/security/totp", %{"code_or_password" => "x"})
             |> html_response(422)

      conn =
        conn
        |> continue()
        |> delete(~p"/admin/security/totp", %{"code_or_password" => valid_password()})

      assert redirected_to(conn) == "/admin/security"
      refute TOTP.enabled?(Repo.get!(AdminUser, admin.id))
    end

    test "a tenant user enrolls from the portal security page", %{conn: conn} do
      tenant = tenant_fixture()
      user = tenant_user_fixture(tenant)
      conn = log_in_tenant_user(conn, user)

      post(conn, ~p"/portal/security/totp/setup")
      user = Repo.get!(TenantUser, user.id)

      conn = post(conn, ~p"/portal/security/totp", %{"code" => totp_code(user)})
      assert redirected_to(conn) == "/portal/security"
      assert TOTP.enabled?(Repo.get!(TenantUser, user.id))
    end
  end

  describe "required 2FA (require_2fa_roles)" do
    setup do
      put_env(:require_2fa_roles, ["super_admin"])
      :ok
    end

    test "a super_admin without 2FA is sent to enrollment before any admin page",
         %{conn: conn} do
      admin = admin_user_fixture(%{role: "super_admin"})
      conn = admin_login(conn, admin) |> continue()

      assert conn |> get(~p"/admin/tenants") |> redirected_to() == "/admin/security"
      assert {:error, {:redirect, %{to: "/admin/security"}}} = live(conn, ~p"/admin")
      assert {:error, {:redirect, %{to: "/admin/security"}}} = live(conn, ~p"/admin/users")
      assert conn |> get(~p"/admin/oban") |> redirected_to() == "/admin/security"

      html = conn |> get(~p"/admin/security") |> html_response(200)
      assert html =~ "Your role requires two-factor authentication"

      # enrolling lifts the restriction
      post(conn, ~p"/admin/security/totp/setup")
      admin = Repo.get!(AdminUser, admin.id)
      post(conn, ~p"/admin/security/totp", %{"code" => totp_code(admin)})
      assert conn |> get(~p"/admin/tenants") |> html_response(200)
    end

    test "a super_admin cannot log in without 2FA once enabled", %{conn: conn} do
      admin = admin_user_fixture(%{role: "super_admin"}) |> enable_totp()

      conn = admin_login(conn, admin)
      assert redirected_to(conn) == "/admin/login/totp"
      conn = continue(conn)

      # the password alone opens nothing
      assert conn |> get(~p"/admin/tenants") |> redirected_to() == "/admin/login"
      assert conn |> get(~p"/admin/security") |> redirected_to() == "/admin/login"
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin")

      conn = post(conn, ~p"/admin/login/totp", %{"code" => totp_code(admin)})
      assert redirected_to(conn) == "/admin"
      assert conn |> continue() |> get(~p"/admin/tenants") |> html_response(200)
    end

    test "other roles are not forced", %{conn: conn} do
      admin = admin_user_fixture(%{role: "admin"})
      assert conn |> log_in_admin(admin) |> get(~p"/admin/tenants") |> html_response(200)
    end
  end

  describe "2FA reset by another user" do
    test "a super_admin resets an admin's 2FA from the users page (audit-logged)",
         %{conn: conn} do
      boss = admin_user_fixture()
      target = admin_user_fixture(%{role: "admin"}) |> enable_totp()

      {:ok, view, _} = live(log_in_admin(conn, boss), ~p"/admin/users")

      view
      |> element(~s{button[phx-click="reset_2fa"][phx-value-id="#{target.id}"]})
      |> render_click()

      refute TOTP.enabled?(Repo.get!(AdminUser, target.id))

      assert [%{actor_id: actor_id, resource_id: resource_id}] =
               AuditLogs.list_audit_logs(%{"action" => "reset_2fa"})

      assert actor_id == boss.email and resource_id == target.id
    end

    test "only a super_admin can reset 2FA", %{conn: conn} do
      admin = admin_user_fixture(%{role: "admin"})
      target = admin_user_fixture(%{role: "admin"}) |> enable_totp()

      {:ok, view, _} = live(log_in_admin(conn, admin), ~p"/admin/users")
      render_click(view, "reset_2fa", %{"id" => target.id})
      assert TOTP.enabled?(Repo.get!(AdminUser, target.id))
    end

    test "a tenant owner resets a member's 2FA, but not in another tenant", %{conn: conn} do
      tenant = tenant_fixture()
      owner = tenant_user_fixture(tenant, %{role: "owner"})
      member = tenant_user_fixture(tenant, %{role: "member"}) |> enable_totp()
      stranger = tenant_user_fixture(tenant_fixture()) |> enable_totp()

      {:ok, view, _} = live(log_in_tenant_user(conn, owner), ~p"/portal/users")

      view
      |> element(~s{button[phx-click="reset_2fa"][phx-value-id="#{member.id}"]})
      |> render_click()

      refute TOTP.enabled?(Repo.get!(TenantUser, member.id))

      render_click(view, "reset_2fa", %{"id" => stranger.id})
      assert TOTP.enabled?(Repo.get!(TenantUser, stranger.id))
    end

    test "the release helper resets an admin's 2FA by email" do
      admin = admin_user_fixture() |> enable_totp()
      {:ok, _, _} = Sessions.create("admin", admin)

      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Converger.Release.reset_admin_2fa(admin.email)
        assert {:error, :not_found} = Converger.Release.reset_admin_2fa("nobody@test.com")
      end)

      refute TOTP.enabled?(Repo.get!(AdminUser, admin.id))
      assert Sessions.list("admin", admin.id) == []
    end
  end
end
