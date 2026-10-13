defmodule ConvergerWeb.ChannelLiveTest do
  # Lowers the page size through the :pagination app env.
  use ConvergerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.HealthCheckFixtures

  alias Converger.Accounts
  alias Converger.Channels
  alias Converger.Deliveries

  setup do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "channels-admin-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: "super_admin"
      })

    %{admin: admin, tenant: tenant_fixture()}
  end

  defp put_page_size(n) do
    Application.put_env(
      :converger,
      :pagination,
      Keyword.merge(Application.get_env(:converger, :pagination, []), default_limit: n)
    )
  end

  defp admin_conn(conn, admin) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin)
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        email: "channels-#{role}-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "User",
        role: role,
        tenant_id: tenant.id
      })

    log_in_tenant_user(conn, user)
  end

  # Distinct creation times: on some platforms consecutive inserts can share
  # a timestamp, which would make the (inserted_at, id) order random.
  defp created(channel, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    Converger.Repo.update_all(
      from(c in Converger.Channels.Channel, where: c.id == ^channel.id),
      set: [inserted_at: at]
    )

    channel
  end

  defp row_ids(html) do
    ~r/id="channel-([0-9a-f-]{36})"/ |> Regex.scan(html) |> Enum.map(&List.last/1)
  end

  describe "admin list" do
    test "searches, filters by tenant, sorts and loads more", %{
      conn: conn,
      admin: admin,
      tenant: tenant
    } do
      put_page_size(2)
      other = tenant_fixture()
      a = channel_fixture(tenant, name: "Alpha support") |> created(30)
      b = channel_fixture(tenant, name: "Beta") |> created(20)
      c = channel_fixture(other, name: "Gamma support") |> created(10)

      {:ok, view, html} = live(admin_conn(conn, admin), ~p"/admin/channels")
      assert row_ids(html) == [c.id, b.id]
      assert html =~ "Showing 2 channels"

      html = view |> element("#load-more-channels") |> render_click()
      assert row_ids(html) == [c.id, b.id, a.id]
      refute has_element?(view, "#load-more-channels")

      html = view |> form("#channel-filter", filters: %{q: "SUPPORT"}) |> render_change()
      assert_patch(view)
      assert Enum.sort(row_ids(html)) == Enum.sort([a.id, c.id])

      html =
        view
        |> form("#channel-filter", filters: %{q: "support", tenant_id: tenant.id})
        |> render_change()

      assert row_ids(html) == [a.id]

      {:ok, _view, html} = live(admin_conn(conn, admin), ~p"/admin/channels?sort=asc")
      assert row_ids(html) == [a.id, b.id]

      {:ok, _view, html} = live(admin_conn(conn, admin), ~p"/admin/channels?q=nothing-like-it")
      assert html =~ "No channels found."
    end

    test "filters by mode and status", %{conn: conn, admin: admin, tenant: tenant} do
      inbound = channel_fixture(tenant, mode: "inbound")
      duplex = channel_fixture(tenant, status: "inactive")

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/channels")

      html = view |> form("#channel-filter", filters: %{mode: "inbound"}) |> render_change()
      assert row_ids(html) == [inbound.id]

      html =
        view
        |> form("#channel-filter", filters: %{mode: "", status: "inactive"})
        |> render_change()

      assert row_ids(html) == [duplex.id]
    end

    test "renders the health sparkline with a text alternative", %{
      conn: conn,
      admin: admin,
      tenant: tenant
    } do
      channel = channel_fixture(tenant)
      quiet = channel_fixture(tenant)
      now = DateTime.utc_now()

      health_check_fixture(channel, %{failure_rate: 0.0, checked_at: DateTime.add(now, -60)})

      health_check_fixture(channel, %{
        status: "degraded",
        failure_rate: 0.25,
        checked_at: now
      })

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/channels")

      sparkline = view |> element("#health-sparkline-#{channel.id}") |> render()
      assert sparkline =~ "<svg"
      assert sparkline =~ ~s(viewBox="0 0 100 24")
      assert sparkline =~ "<polyline"
      assert sparkline =~ "last 2 health check(s): latest 25.0%, peak 25.0%"
      assert sparkline =~ "text-warning"
      refute sparkline =~ "style="

      assert view |> element("#health-sparkline-#{quiet.id}") |> render() =~ "No health history"
    end

    test "sends a test message and shows the delivery result", %{
      conn: conn,
      admin: admin,
      tenant: tenant
    } do
      channel = channel_fixture(tenant, type: "echo")
      inbound = channel_fixture(tenant, mode: "inbound")

      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/channels")

      assert has_element?(view, "#send-test-#{inbound.id}[disabled]")
      assert view |> element("#send-test-#{inbound.id}") |> render() =~ "Inbound-only"

      view |> element("#send-test-#{channel.id}") |> render_click()
      assert has_element?(view, "#test-message-panel")

      html =
        view
        |> form("#test-message-form", test: %{text: "Hello from the test"})
        |> render_submit()

      assert html =~ "test-message-result"
      assert has_element?(view, "#test-delivery-status", "sent")

      {:ok, conversation} = Converger.Channels.TestMessage.test_conversation(channel)

      # The first activity is the test message (the echo adapter replies after it).
      activity =
        Converger.Repo.one!(
          from(a in Converger.Activities.Activity,
            where: a.conversation_id == ^conversation.id,
            order_by: [asc: a.seq],
            limit: 1
          )
        )

      assert activity.text == "Hello from the test"
      assert activity.metadata["converger_test"] == true

      assert Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id).status ==
               "sent"

      # A delivery status broadcast updates the result live.
      ConvergerWeb.Endpoint.broadcast!(
        "conversation:#{activity.conversation_id}",
        "delivery_status",
        %{
          activity_id: activity.id,
          channel_id: channel.id,
          status: "delivered",
          attempts: 1,
          last_error: nil
        }
      )

      assert has_element?(view, "#test-delivery-status", "delivered")

      # Rejected for an inbound channel even when the event is forced.
      html =
        render_submit(view, "send_test_message", %{
          "test" => %{"channel_id" => inbound.id, "text" => "hi"}
        })

      assert html =~ "Inbound-only channels receive messages"
    end

    test "rotates the secret, shown once", %{conn: conn, admin: admin, tenant: tenant} do
      channel = channel_fixture(tenant)
      {:ok, view, _html} = live(admin_conn(conn, admin), ~p"/admin/channels")

      assert view |> element("#rotate-secret-#{channel.id}") |> render() =~ "data-confirm"

      html = view |> element("#rotate-secret-#{channel.id}") |> render_click()
      assert html =~ "Secret rotated"

      rotated = Channels.get_channel!(channel.id)
      assert rotated.secret != channel.secret
      assert html =~ rotated.secret
      assert Channels.get_channel_by_secret(channel.secret) == nil

      html = view |> element("button[phx-click='dismiss_secret']") |> render_click()
      refute html =~ rotated.secret
    end
  end

  describe "portal list" do
    test "lists only the tenant's channels, with search and Load more", %{
      conn: conn,
      tenant: tenant
    } do
      put_page_size(1)
      a = channel_fixture(tenant, name: "Portal A") |> created(20)
      b = channel_fixture(tenant, name: "Portal B") |> created(10)
      foreign = channel_fixture(tenant_fixture(), name: "Portal Foreign")

      {:ok, view, html} = live(portal_conn(conn, tenant, "viewer"), ~p"/portal/channels")
      assert row_ids(html) == [b.id]
      refute html =~ foreign.name

      html = view |> element("#load-more-channels") |> render_click()
      assert row_ids(html) == [b.id, a.id]

      html = view |> form("#channel-filter", filters: %{q: "portal a"}) |> render_change()
      assert row_ids(html) == [a.id]
    end

    test "owners pause/resume deliveries, rotate secrets and send tests", %{
      conn: conn,
      tenant: tenant
    } do
      channel = channel_fixture(tenant, type: "echo")
      {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/channels")

      assert view
             |> element("button[phx-click='pause_deliveries'][phx-value-id='#{channel.id}']")
             |> render_click() =~ "Deliveries paused"

      assert Channels.get_channel!(channel.id).circuit_state == "paused"

      assert view
             |> element("button[phx-click='resume_deliveries'][phx-value-id='#{channel.id}']")
             |> render_click() =~ "Deliveries resumed"

      assert Channels.get_channel!(channel.id).circuit_state == "closed"

      html = view |> element("#rotate-secret-#{channel.id}") |> render_click()
      assert html =~ Channels.get_channel!(channel.id).secret

      view |> element("#send-test-#{channel.id}") |> render_click()
      view |> form("#test-message-form", test: %{text: "portal test"}) |> render_submit()
      assert has_element?(view, "#test-delivery-status", "sent")
    end

    test "members and viewers cannot manage deliveries or secrets", %{
      conn: conn,
      tenant: tenant
    } do
      channel = channel_fixture(tenant, type: "echo")

      for role <- ~w(member viewer) do
        {:ok, view, _html} = live(portal_conn(conn, tenant, role), ~p"/portal/channels")

        refute has_element?(view, "button[phx-click='pause_deliveries']")
        refute has_element?(view, "#rotate-secret-#{channel.id}")
        refute has_element?(view, "#send-test-#{channel.id}")

        assert render_click(view, "pause_deliveries", %{"id" => channel.id}) =~
                 "permission"

        assert render_click(view, "rotate_secret", %{"id" => channel.id}) =~ "permission"

        assert render_submit(view, "send_test_message", %{
                 "test" => %{"channel_id" => channel.id, "text" => "x"}
               }) =~ "permission"
      end

      reloaded = Channels.get_channel!(channel.id)
      assert reloaded.circuit_state == "closed"
      assert reloaded.secret == channel.secret
    end

    test "cannot act on another tenant's channel", %{conn: conn, tenant: tenant} do
      foreign = channel_fixture(tenant_fixture())
      {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/channels")

      assert render_click(view, "rotate_secret", %{"id" => foreign.id}) =~ "Unauthorized"
      assert render_click(view, "pause_deliveries", %{"id" => foreign.id}) =~ "Unauthorized"
      assert Channels.get_channel!(foreign.id).secret == foreign.secret
    end
  end
end
