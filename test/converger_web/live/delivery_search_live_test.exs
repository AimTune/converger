defmodule ConvergerWeb.DeliverySearchLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Ecto.Query

  alias Converger.{Accounts, Deliveries, Repo}
  alias Converger.Deliveries.Delivery

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
    channel = webhook_channel_fixture(tenant)

    old = dead_letter(tenant, channel, "connection refused by upstream", ~U[2026-01-01 10:00:00Z])
    new = dead_letter(tenant, channel, "HTTP 500 from provider", ~U[2026-01-02 10:00:00Z])

    %{tenant: tenant, channel: channel, old: old, new: new}
  end

  defp dead_letter(tenant, channel, error, updated_at) do
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    activity = activity_fixture(tenant, conversation)

    {:ok, delivery} =
      activity.id
      |> Deliveries.get_or_create_delivery(channel.id)
      |> Delivery.changeset(%{status: "failed", attempts: 5, last_error: error})
      |> Repo.update()

    from(d in Delivery, where: d.id == ^delivery.id)
    |> Repo.update_all(set: [updated_at: updated_at])

    Repo.get!(Delivery, delivery.id)
  end

  defp admin_conn(conn, role) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "dls-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: role
      })

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin)
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Portal",
        email: "dls-#{System.unique_integer([:positive])}@example.com",
        password: "password-123456",
        role: role
      })

    log_in_tenant_user(conn, user)
  end

  defp row_ids(view) do
    ~r/id="deliveries-([0-9a-f-]{36})"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> List.flatten()
  end

  describe "search" do
    test "matches error text and patches the URL", %{conn: conn, old: old, new: new} do
      {:ok, view, _html} = live(admin_conn(conn, "viewer"), ~p"/admin/deliveries")
      assert has_element?(view, "#deliveries-#{old.id}")
      assert has_element?(view, "#deliveries-#{new.id}")

      view
      |> form("#delivery-filter-form", %{"filters" => %{"q" => "REFUSED"}})
      |> render_change()

      assert assert_patch(view) =~ "q=REFUSED"
      assert has_element?(view, "#deliveries-#{old.id}")
      refute has_element?(view, "#deliveries-#{new.id}")
      assert has_element?(view, "#export-deliveries[href*='q=REFUSED']")
    end

    test "matches an exact activity id", %{conn: conn, old: old, new: new} do
      {:ok, view, _html} =
        live(admin_conn(conn, "viewer"), ~p"/admin/deliveries?#{[q: new.activity_id]}")

      assert has_element?(view, "#deliveries-#{new.id}")
      refute has_element?(view, "#deliveries-#{old.id}")
    end

    test "shows the empty state when nothing matches", %{conn: conn} do
      {:ok, _view, html} =
        live(admin_conn(conn, "viewer"), ~p"/admin/deliveries?#{[q: "no such error"]}")

      assert html =~ "No deliveries found"
    end

    test "portal search stays tenant-scoped", %{conn: conn, tenant: tenant, old: old} do
      other = tenant_fixture()

      foreign =
        dead_letter(
          other,
          webhook_channel_fixture(other),
          "connection refused",
          DateTime.utc_now()
        )

      {:ok, view, _html} =
        live(portal_conn(conn, tenant, "viewer"), ~p"/portal/deliveries?#{[q: "refused"]}")

      assert has_element?(view, "#deliveries-#{old.id}")
      refute has_element?(view, "#deliveries-#{foreign.id}")
    end
  end

  describe "sort" do
    test "newest first by default, oldest first on request", %{conn: conn, old: old, new: new} do
      conn = admin_conn(conn, "viewer")

      {:ok, view, _html} = live(conn, ~p"/admin/deliveries")
      assert row_ids(view) == [new.id, old.id]

      view
      |> form("#delivery-filter-form", %{"filters" => %{"sort" => "oldest"}})
      |> render_change()

      assert row_ids(view) == [old.id, new.id]
    end

    test "Load more keeps the sort", %{conn: conn, old: old, new: new} do
      previous = Application.get_env(:converger, :pagination)
      on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

      Application.put_env(
        :converger,
        :pagination,
        Keyword.merge(previous || [], default_limit: 1)
      )

      {:ok, view, _html} =
        live(admin_conn(conn, "viewer"), ~p"/admin/deliveries?#{[sort: "oldest"]}")

      assert row_ids(view) == [old.id]
      view |> element("#load-more-deliveries") |> render_click()
      assert row_ids(view) == [old.id, new.id]
      refute has_element?(view, "#load-more-deliveries")
    end

    test "an invalid sort falls back with an error", %{conn: conn} do
      {:ok, _view, html} =
        live(admin_conn(conn, "viewer"), ~p"/admin/deliveries?#{[sort: "sideways"]}")

      assert html =~ "Invalid sort"
    end
  end

  test "bulk retry only replays the searched deliveries", %{conn: conn, old: old, new: new} do
    {:ok, view, _html} =
      live(admin_conn(conn, "admin"), ~p"/admin/deliveries?#{[q: "refused"]}")

    assert view |> element("#bulk-retry") |> render_click() =~ "Re-enqueued 1 deliveries"
    assert Repo.get!(Delivery, old.id).status == "pending"
    assert Repo.get!(Delivery, new.id).status == "failed"
  end

  test "the CSV export applies q and sort", %{conn: conn, old: old, new: new} do
    conn = admin_conn(conn, "viewer")

    csv = conn |> get(~p"/admin/deliveries/export?#{[q: "provider"]}") |> response(200)
    assert csv =~ new.id
    refute csv =~ old.id

    csv =
      conn
      |> get(~p"/admin/deliveries/export?#{[sort: "oldest", status: "failed"]}")
      |> response(200)

    [_header, first, second] = String.split(csv, "\r\n", trim: true)
    assert first =~ old.id
    assert second =~ new.id

    assert conn |> get(~p"/admin/deliveries/export?#{[sort: "bad"]}") |> response(400) =~
             "Invalid sort"
  end
end
