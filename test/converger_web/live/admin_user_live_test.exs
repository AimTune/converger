defmodule ConvergerWeb.Admin.AdminUserLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.AccountsFixtures

  alias Converger.Accounts
  alias Converger.Accounts.{AdminUser, Sessions, TOTP}
  alias Converger.Repo

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)
    %{admin: admin_user_fixture(%{name: "Boss"})}
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin)
  end

  defp row_count(html), do: ~r/id="admin-user-[0-9a-f-]{36}"/ |> Regex.scan(html) |> length()

  describe "list" do
    test "searches by name and email and filters by role and status", %{
      conn: conn,
      admin: admin
    } do
      alice = admin_user_fixture(%{name: "Alice Ops", role: "admin"})
      bob = admin_user_fixture(%{name: "Bob", email: "bob-find-me@test.com", role: "viewer"})

      {:ok, carol} =
        Accounts.update_admin_user(admin_user_fixture(%{name: "Carol"}), %{status: "inactive"})

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/users")

      view |> form("#admin-user-filter", filters: %{q: "alice"}) |> render_change()
      assert_patch(view, ~p"/admin/users?q=alice")
      assert has_element?(view, "#admin-user-#{alice.id}")
      refute has_element?(view, "#admin-user-#{bob.id}")

      {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/users?q=find-me")
      assert has_element?(view, "#admin-user-#{bob.id}")
      refute has_element?(view, "#admin-user-#{alice.id}")

      {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/users?role=viewer")
      assert has_element?(view, "#admin-user-#{bob.id}")
      refute has_element?(view, "#admin-user-#{alice.id}")

      {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/users?status=inactive")
      assert has_element?(view, "#admin-user-#{carol.id}")
      refute has_element?(view, "#admin-user-#{admin.id}")

      {:ok, view, _} = live(admin_conn(conn, admin), ~p"/admin/users?q=zzz-nobody")
      assert has_element?(view, "p", "No admin users found.")
    end

    test "sorts and loads more pages", %{conn: conn, admin: admin} do
      Application.put_env(:converger, :pagination, default_limit: 2)
      for _ <- 1..2, do: admin_user_fixture()

      {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/users?sort=asc")
      assert row_count(html) == 2
      # Oldest first: the setup admin comes first.
      assert html =~ "admin-user-#{admin.id}"

      html = view |> element("#load-more-admin-users") |> render_click()
      assert row_count(html) == 3
      assert html =~ "Showing 3 admin users"
      refute has_element?(view, "#load-more-admin-users")

      {:ok, _view, html} = live(admin_conn(conn, admin), ~p"/admin/users")
      refute html =~ "admin-user-#{admin.id}"
    end
  end

  describe "actions" do
    test "creates, toggles, resets 2FA, signs out and deletes", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/users")

      html =
        view
        |> form("#admin-user-form",
          admin_user: %{
            name: "New Admin",
            email: "new-admin@test.com",
            password: valid_password(),
            role: "admin"
          }
        )
        |> render_submit()

      assert html =~ "Admin user created"
      user = Accounts.get_admin_user_by_email("new-admin@test.com")
      assert has_element?(view, "#admin-user-#{user.id}", "New Admin")

      view
      |> element(~s{button[phx-click="toggle_status"][phx-value-id="#{user.id}"]})
      |> render_click()

      assert Repo.get!(AdminUser, user.id).status == "inactive"
      assert has_element?(view, "#admin-user-#{user.id}", "Enable")

      enable_totp(Repo.get!(AdminUser, user.id))
      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/users")

      assert view
             |> element(~s{button[phx-click="reset_2fa"][phx-value-id="#{user.id}"]})
             |> render_click() =~ "Two-factor authentication reset"

      refute TOTP.enabled?(Repo.get!(AdminUser, user.id))
      refute has_element?(view, ~s{button[phx-click="reset_2fa"][phx-value-id="#{user.id}"]})

      {:ok, _} = Accounts.update_admin_user(Repo.get!(AdminUser, user.id), %{status: "active"})
      {:ok, _token, _session} = Sessions.create("admin", Repo.get!(AdminUser, user.id))

      assert view
             |> element(~s{button[phx-click="revoke_sessions"][phx-value-id="#{user.id}"]})
             |> render_click() =~ "out of 1 session(s)"

      assert Sessions.list("admin", user.id) == []

      assert view
             |> element(~s{button[phx-click="delete"][phx-value-id="#{user.id}"]})
             |> render_click() =~ "Admin user deleted"

      refute Repo.get(AdminUser, user.id)
      refute has_element?(view, "#admin-user-#{user.id}")
    end

    test "cannot delete yourself", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/users")
      assert render_click(view, "delete", %{"id" => admin.id}) =~ "cannot delete your own"
      assert Repo.get(AdminUser, admin.id)
    end

    test "a viewer cannot manage admin users", %{conn: conn} do
      viewer = admin_user_fixture(%{role: "viewer"})
      target = admin_user_fixture(%{role: "admin"}) |> enable_totp()

      {:ok, view, _html} = live(admin_conn(conn, viewer), ~p"/admin/users")
      refute has_element?(view, "#admin-user-form")
      refute has_element?(view, ~s{button[phx-click="toggle_status"]})
      assert has_element?(view, "#admin-user-#{target.id}")

      assert render_submit(view, "save", %{
               "admin_user" => %{
                 "name" => "X",
                 "email" => "x-denied@test.com",
                 "password" => valid_password()
               }
             }) =~ "Only super_admin can create admin users."

      refute Accounts.get_admin_user_by_email("x-denied@test.com")

      render_click(view, "toggle_status", %{"id" => target.id})
      render_click(view, "reset_2fa", %{"id" => target.id})
      render_click(view, "revoke_sessions", %{"id" => target.id})

      assert render_click(view, "delete", %{"id" => target.id}) =~
               "Only super_admin can delete admin users."

      target = Repo.get!(AdminUser, target.id)
      assert target.status == "active"
      assert TOTP.enabled?(target)
    end
  end
end
