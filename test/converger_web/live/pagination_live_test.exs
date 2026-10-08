defmodule ConvergerWeb.PaginationLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Converger.AuditLogsFixtures

  alias Converger.Accounts

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "page-admin-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: "super_admin"
      })

    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    %{admin: admin, tenant: tenant, channel: channel}
  end

  defp put_limits(overrides) do
    Application.put_env(
      :converger,
      :pagination,
      Keyword.merge(Application.get_env(:converger, :pagination, []), overrides)
    )
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> init_test_session(%{admin_user_id: admin.id})
  end

  defp row_count(html, prefix) do
    ~r/id="#{prefix}-[0-9a-f-]{36}"/ |> Regex.scan(html) |> length()
  end

  describe "admin conversations" do
    test "loads pages with Load more", %{conn: conn, admin: admin, tenant: t, channel: ch} do
      for _ <- 1..30, do: conversation_fixture(t, ch)

      {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/conversations?per_page=25")
      assert row_count(html, "conversations") == 25
      assert html =~ "Showing 25 conversations"

      html = view |> element("#load-more-conversations") |> render_click()
      assert row_count(html, "conversations") == 30
      refute has_element?(view, "#load-more-conversations")
    end

    test "searches by id", %{conn: conn, admin: admin, tenant: t, channel: ch} do
      target = conversation_fixture(t, ch)
      _other = conversation_fixture(t, ch)

      {:ok, _view, html} = live(admin_conn(conn, admin), ~p"/admin/conversations?q=#{target.id}")
      assert row_count(html, "conversations") == 1
      assert html =~ target.id
    end

    test "conversation detail opens on recent activities and loads earlier ones", %{
      conn: conn,
      admin: admin,
      tenant: t,
      channel: ch
    } do
      put_limits(activity_default_limit: 3)
      conversation = conversation_fixture(t, ch)
      for i <- 1..5, do: activity_fixture(t, conversation, %{text: "msg-#{i}"})

      {:ok, view, html} =
        live(admin_conn(conn, admin), ~p"/admin/conversations/#{conversation.id}")

      assert row_count(html, "activities") == 3
      refute html =~ "msg-2"
      assert html =~ "msg-5"

      html = view |> element("#load-older-activities") |> render_click()
      assert row_count(html, "activities") == 5
      assert html =~ "msg-1"
      refute has_element?(view, "#load-older-activities")

      # Chronological order is kept after prepending.
      positions = for i <- 1..5, do: :binary.match(html, "msg-#{i}") |> elem(0)
      assert positions == Enum.sort(positions)
    end
  end

  test "admin audit logs page with Load more", %{conn: conn, admin: admin} do
    put_limits(default_limit: 2)
    for _ <- 1..3, do: audit_log_fixture()

    {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/audit_logs")
    assert row_count(html, "audit_logs") == 2

    html = view |> element("#load-more-audit-logs") |> render_click()
    assert row_count(html, "audit_logs") == 3
    refute has_element?(view, "#load-more-audit-logs")
  end

  test "admin tenant users page with Load more", %{conn: conn, admin: admin, tenant: t} do
    put_limits(default_limit: 2)

    for i <- 1..3 do
      {:ok, _} =
        Accounts.create_tenant_user(%{
          tenant_id: t.id,
          name: "User #{i}",
          email: "lu#{i}-#{System.unique_integer([:positive])}@example.com",
          password: "password123"
        })
    end

    {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/tenant_users")
    assert row_count(html, "tenant_users") == 2

    html = view |> element("#load-more-tenant-users") |> render_click()
    assert row_count(html, "tenant_users") == 3
  end

  test "portal conversations page with Load more", %{conn: conn, tenant: t, channel: ch} do
    put_limits(default_limit: 2)
    for _ <- 1..3, do: conversation_fixture(t, ch)
    _foreign = conversation_fixture(tenant_fixture(), channel_fixture(tenant_fixture()))

    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: t.id,
        name: "Portal",
        email: "portal-#{System.unique_integer([:positive])}@example.com",
        password: "password123",
        role: "owner"
      })

    conn = init_test_session(conn, %{tenant_user_id: user.id})
    {:ok, view, html} = live(conn, ~p"/portal/conversations")
    assert row_count(html, "conversations") == 2

    html = view |> element("#load-more-conversations") |> render_click()
    assert row_count(html, "conversations") == 3
    refute has_element?(view, "#load-more-conversations")
  end
end
