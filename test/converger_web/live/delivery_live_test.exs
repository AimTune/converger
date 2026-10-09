defmodule ConvergerWeb.DeliveryLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.{Accounts, Deliveries, Repo}
  alias Converger.Deliveries.Delivery

  # Retries clicked in the LiveView run in its own process, where Oban's
  # testing mode is :inline, so the replayed job executes right away. The
  # webhook answers 503 (transient): the delivery stays pending.
  setup do
    previous = Application.get_env(:converger, :webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :webhook_req_options, previous),
        else: Application.delete_env(:converger, :webhook_req_options)
    end)

    Application.put_env(:converger, :webhook_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end,
      retry: false
    )

    tenant = tenant_fixture()
    %{tenant: tenant, channel: webhook_channel_fixture(tenant)}
  end

  defp dead_letter(tenant, channel, attrs \\ %{}) do
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    activity = activity_fixture(tenant, conversation, %{metadata: %{"api_key" => "sk-live-123"}})

    {:ok, delivery} =
      activity.id
      |> Deliveries.get_or_create_delivery(channel.id)
      |> Delivery.changeset(
        Map.merge(%{status: "failed", attempts: 5, last_error: "=HYPERLINK(\"x\")"}, attrs)
      )
      |> Repo.update()

    delivery
  end

  defp admin_conn(conn, role) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "dlq-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: role
      })

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> init_test_session(%{admin_user_id: admin.id})
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Portal",
        email: "dlq-#{System.unique_integer([:positive])}@example.com",
        password: "password123",
        role: role
      })

    init_test_session(conn, %{tenant_user_id: user.id})
  end

  describe "admin" do
    test "shows dead letters with redacted payload and retries one", %{
      conn: conn,
      tenant: tenant,
      channel: channel
    } do
      dead = dead_letter(tenant, channel)

      {:ok, view, html} = live(admin_conn(conn, "admin"), ~p"/admin/deliveries")
      assert html =~ "=HYPERLINK"
      assert html =~ "[REDACTED]"
      refute html =~ "sk-live-123"

      assert view |> element("#retry-#{dead.id}") |> render_click() =~ "Delivery re-enqueued"

      # Replayed: attempts restarted, and the first new attempt hit the 503.
      assert %{status: "pending", attempts: 1, retry_count: 1, retried_by: by} =
               Repo.get!(Delivery, dead.id)

      assert by =~ "admin:dlq-"
    end

    test "bulk retry follows the filters", %{conn: conn, tenant: tenant, channel: channel} do
      mine = dead_letter(tenant, channel)
      other = tenant_fixture()
      theirs = dead_letter(other, webhook_channel_fixture(other))

      {:ok, view, _html} =
        live(admin_conn(conn, "super_admin"), ~p"/admin/deliveries?tenant_id=#{tenant.id}")

      assert view |> element("#bulk-retry") |> render_click() =~ "Re-enqueued 1 deliveries"

      assert Repo.get!(Delivery, mine.id).status == "pending"
      assert Repo.get!(Delivery, theirs.id).status == "failed"
    end

    test "viewers cannot retry", %{conn: conn, tenant: tenant, channel: channel} do
      dead = dead_letter(tenant, channel)

      {:ok, view, html} = live(admin_conn(conn, "viewer"), ~p"/admin/deliveries")
      assert html =~ dead.activity_id |> String.slice(0..7)
      refute has_element?(view, "#retry-#{dead.id}")
      refute has_element?(view, "#bulk-retry")

      assert render_click(view, "retry", %{"id" => dead.id}) =~ "permission"
      assert Repo.get!(Delivery, dead.id).status == "failed"
    end

    test "exports CSV with the page filters", %{conn: conn, tenant: tenant, channel: channel} do
      dead = dead_letter(tenant, channel)
      sent = dead_letter(tenant, channel, %{status: "sent"})

      csv =
        conn
        |> admin_conn("viewer")
        |> get(~p"/admin/deliveries/export?status=failed")
        |> response(200)

      [header | rows] = String.split(csv, "\r\n", trim: true)
      assert header =~ ~s("id","tenant_id","channel_id")
      assert Enum.any?(rows, &(&1 =~ dead.id))
      refute Enum.any?(rows, &(&1 =~ sent.id))
      # Formula-looking error text is neutralised for spreadsheets.
      assert csv =~ ~S|"'=HYPERLINK(""x"")"|
    end
  end

  describe "portal" do
    test "is scoped to the tenant and members can retry", %{
      conn: conn,
      tenant: tenant,
      channel: channel
    } do
      dead = dead_letter(tenant, channel)
      other = tenant_fixture()
      foreign = dead_letter(other, webhook_channel_fixture(other))

      {:ok, view, _html} = live(portal_conn(conn, tenant, "member"), ~p"/portal/deliveries")
      assert has_element?(view, "#retry-#{dead.id}")
      refute has_element?(view, "#retry-#{foreign.id}")

      # A forged event for another tenant's delivery is refused.
      assert render_click(view, "retry", %{"id" => foreign.id}) =~ "Delivery not found"
      assert Repo.get!(Delivery, foreign.id).status == "failed"

      view |> element("#retry-#{dead.id}") |> render_click()

      assert Repo.get!(Delivery, dead.id).status == "pending"
    end

    test "viewers cannot retry and the export is tenant-scoped", %{
      conn: conn,
      tenant: tenant,
      channel: channel
    } do
      dead = dead_letter(tenant, channel)
      other = tenant_fixture()
      foreign = dead_letter(other, webhook_channel_fixture(other))
      conn = portal_conn(conn, tenant, "viewer")

      {:ok, view, _html} = live(conn, ~p"/portal/deliveries")
      refute has_element?(view, "#retry-#{dead.id}")
      refute has_element?(view, "#bulk-retry")

      csv = conn |> get(~p"/portal/deliveries/export?tenant_id=#{other.id}") |> response(200)
      assert csv =~ dead.id
      refute csv =~ foreign.id
    end
  end
end
