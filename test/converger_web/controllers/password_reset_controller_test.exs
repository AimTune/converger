defmodule ConvergerWeb.PasswordResetControllerTest do
  # Changes the global admin IP whitelist.
  use ConvergerWeb.ConnCase, async: false

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures
  import Swoosh.TestAssertions

  alias Converger.Accounts
  alias Converger.Accounts.Sessions

  setup %{conn: conn} do
    previous = Application.get_env(:converger, :admin_ip_whitelist)
    Application.put_env(:converger, :admin_ip_whitelist, ["127.0.0.1", "::1", "10.0.0.0/8"])
    on_exit(fn -> Application.put_env(:converger, :admin_ip_whitelist, previous) end)

    %{conn: %{conn | remote_ip: unique_ip()}}
  end

  defp mailed_token do
    assert_email_sent(fn email ->
      [_, token] = Regex.run(~r{/password/reset/([A-Za-z0-9_-]+)}, email.text_body)
      send(self(), {:token, token})
    end)

    assert_received {:token, token}
    token
  end

  defp without_csrf(html),
    do: Regex.replace(~r/(csrf-token" content|_csrf_token" value)="[^"]*"/, html, "")

  test "the login pages link to the reset form", %{conn: conn} do
    assert conn |> get(~p"/admin/login") |> html_response(200) =~ "/admin/password/reset"
    assert conn |> get(~p"/portal/login") |> html_response(200) =~ "/portal/password/reset"
    assert conn |> get(~p"/portal/password/reset") |> html_response(200) =~ "Tenant Name"
  end

  test "admin reset: same answer for unknown accounts, link resets once", %{conn: conn} do
    admin = admin_user_fixture()
    other = admin_user_fixture()
    {:ok, _, _} = Sessions.create("admin", other)

    unknown = post(conn, ~p"/admin/password/reset", %{"reset" => %{"email" => "no@test.com"}})
    assert_no_email_sent()

    known = post(conn, ~p"/admin/password/reset", %{"reset" => %{"email" => other.email}})
    assert without_csrf(html_response(unknown, 200)) == without_csrf(html_response(known, 200))
    assert html_response(known, 200) =~ "If an account matches"

    token = mailed_token()
    assert token =~ ~r/^[A-Za-z0-9_-]{43}$/

    assert conn |> get(~p"/admin/password/reset/#{token}") |> html_response(200) =~
             "Choose a new password"

    attrs = %{"password" => "brand-new-password", "password_confirmation" => "brand-new-password"}

    conn2 = put(conn, ~p"/admin/password/reset/#{token}", %{"reset" => attrs})
    assert redirected_to(conn2) == "/admin/login"
    assert {:ok, _} = Accounts.authenticate_admin(other.email, "brand-new-password")
    assert Sessions.list("admin", other.id) == []

    # used up
    conn3 = put(conn, ~p"/admin/password/reset/#{token}", %{"reset" => attrs})
    assert redirected_to(conn3) == "/admin/password/reset"

    assert conn |> get(~p"/admin/password/reset/#{token}") |> redirected_to() ==
             "/admin/password/reset"

    # the unaffected admin keeps the old password
    assert {:ok, _} = Accounts.authenticate_admin(admin.email, valid_password())
  end

  test "policy errors are shown and keep the link usable", %{conn: conn} do
    admin = admin_user_fixture()
    post(conn, ~p"/admin/password/reset", %{"reset" => %{"email" => admin.email}})
    token = mailed_token()

    conn2 =
      put(conn, ~p"/admin/password/reset/#{token}", %{
        "reset" => %{"password" => "short", "password_confirmation" => "short"}
      })

    assert html_response(conn2, 422) =~ "at least 12 characters"
    assert conn |> get(~p"/admin/password/reset/#{token}") |> html_response(200)
  end

  test "portal reset needs the tenant name", %{conn: conn} do
    tenant = tenant_fixture()
    user = tenant_user_fixture(tenant)

    post(conn, ~p"/portal/password/reset", %{
      "reset" => %{"tenant_name" => "other-tenant", "email" => user.email}
    })

    assert_no_email_sent()

    post(conn, ~p"/portal/password/reset", %{
      "reset" => %{"tenant_name" => tenant.name, "email" => user.email}
    })

    token = mailed_token()
    # an admin route does not take a tenant token
    assert conn |> get(~p"/admin/password/reset/#{token}") |> redirected_to() ==
             "/admin/password/reset"

    conn =
      put(conn, ~p"/portal/password/reset/#{token}", %{
        "reset" => %{
          "password" => "brand-new-password",
          "password_confirmation" => "brand-new-password"
        }
      })

    assert redirected_to(conn) == "/portal/login"

    assert {:ok, _} =
             Accounts.authenticate_tenant_user_by_name(
               user.email,
               "brand-new-password",
               tenant.name
             )
  end

  test "requests are rate limited per IP", %{conn: conn} do
    for _ <- 1..5 do
      conn
      |> post(~p"/portal/password/reset", %{
        "reset" => %{"tenant_name" => "t", "email" => "a@b.c"}
      })
      |> html_response(200)
    end

    limited =
      post(conn, ~p"/portal/password/reset", %{
        "reset" => %{"tenant_name" => "t", "email" => "a@b.c"}
      })

    assert html_response(limited, 429) =~ "Too many requests"
    assert [_] = get_resp_header(limited, "retry-after")
  end

  test "mails per account are limited, without changing the answer", %{conn: conn} do
    admin = admin_user_fixture()

    for _ <- 1..3 do
      conn
      |> Map.put(:remote_ip, unique_ip())
      |> post(~p"/admin/password/reset", %{"reset" => %{"email" => admin.email}})

      assert_email_sent(to: admin.email)
    end

    conn =
      conn
      |> Map.put(:remote_ip, unique_ip())
      |> post(~p"/admin/password/reset", %{"reset" => %{"email" => admin.email}})

    assert html_response(conn, 200) =~ "If an account matches"
    assert_no_email_sent()
  end

  test "the admin reset form is behind the IP whitelist", %{conn: conn} do
    conn = %{conn | remote_ip: {192, 0, 2, 1}}
    assert conn |> get(~p"/admin/password/reset") |> response(403)
  end
end
