defmodule ConvergerWeb.AdminPasswordControllerTest do
  use ConvergerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Converger.Accounts

  setup %{conn: conn} do
    {:ok, user, :generated, password} = Accounts.bootstrap_super_admin([])
    conn = %{conn | remote_ip: {127, 0, 0, 1}}
    %{conn: conn, user: user, password: password}
  end

  test "login with a generated password redirects to the password page", %{
    conn: conn,
    user: user,
    password: password
  } do
    conn = post(conn, ~p"/admin/login", %{"email" => user.email, "password" => password})
    assert redirected_to(conn) == "/admin/password"
  end

  test "admin pages are blocked until the password is changed", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{admin_user_id: user.id})

    assert {:error, {:redirect, %{to: "/admin/password"}}} =
             live(conn, ~p"/admin")

    assert conn |> get(~p"/admin/tenants") |> redirected_to() == "/admin/password"

    assert conn |> get(~p"/admin/password") |> html_response(200) =~ "temporary password"
  end

  test "changing the password lifts the restriction", %{conn: conn, user: user, password: pw} do
    conn = init_test_session(conn, %{admin_user_id: user.id})

    conn =
      put(conn, ~p"/admin/password", %{
        "admin_password" => %{
          "current_password" => pw,
          "password" => "brand-new-password",
          "password_confirmation" => "brand-new-password"
        }
      })

    assert redirected_to(conn) == "/admin"
    refute Accounts.get_admin_user!(user.id).must_change_password
  end

  test "a wrong current password is rejected", %{conn: conn, user: user} do
    conn = init_test_session(conn, %{admin_user_id: user.id})

    conn =
      put(conn, ~p"/admin/password", %{
        "admin_password" => %{
          "current_password" => "nope",
          "password" => "brand-new-password",
          "password_confirmation" => "brand-new-password"
        }
      })

    assert html_response(conn, 422) =~ "Current password is not valid"
    assert Accounts.get_admin_user!(user.id).must_change_password
  end

  test "requires a session", %{conn: conn} do
    assert conn |> get(~p"/admin/password") |> redirected_to() == "/admin/login"
  end
end
