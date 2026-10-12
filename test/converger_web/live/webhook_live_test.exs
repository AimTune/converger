defmodule ConvergerWeb.WebhookLiveTest do
  # Mutates the global :platform_webhook_req_options config. Redeliveries
  # clicked in the LiveView run in its own process (Oban :inline), so the
  # receiver is a plain plug function rather than a per-process stub.
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Ecto.Query

  alias Converger.{Accounts, Repo, Webhooks}
  alias Converger.Webhooks.{Event, Subscription}

  setup do
    previous = Application.get_env(:converger, :platform_webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :platform_webhook_req_options, previous),
        else: Application.delete_env(:converger, :platform_webhook_req_options)
    end)

    Application.put_env(:converger, :platform_webhook_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 400, "nope") end
    )

    %{tenant: tenant_fixture()}
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Portal",
        email: "wh-#{System.unique_integer([:positive])}@example.com",
        password: "password123",
        role: role
      })

    init_test_session(conn, %{tenant_user_id: user.id})
  end

  defp admin_conn(conn) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "wh-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: "admin"
      })

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> init_test_session(%{admin_user_id: admin.id})
  end

  defp failed_event(tenant) do
    {:ok, subscription} =
      Webhooks.create_subscription(tenant.id, %{
        "url" => "https://hooks.example.com/events",
        "events" => ["conversation.closed"]
      })

    Webhooks.emit(tenant.id, "conversation.closed", %{conversation_id: "c-1"})
    event = Repo.one!(from e in Event, where: e.subscription_id == ^subscription.id)
    assert event.status == "failed"
    {subscription, event}
  end

  test "portal owner creates a subscription and sees the secret once", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/webhooks")

    html =
      view
      |> form("#webhook-subscription-form", %{
        "subscription" => %{
          "url" => "https://hooks.example.com/new",
          "events" => ["delivery.failed"]
        }
      })
      |> render_submit()

    [subscription] = Webhooks.list_subscriptions(tenant.id)
    assert subscription.events == ["delivery.failed"]
    assert html =~ subscription.secret
    assert has_element?(view, "#subscription-#{subscription.id}")

    refute render_click(view, "dismiss_secret", %{}) =~ subscription.secret
  end

  test "portal shows recent events with status and redelivers a failed one", %{
    conn: conn,
    tenant: tenant
  } do
    {_subscription, event} = failed_event(tenant)

    {:ok, view, html} = live(portal_conn(conn, tenant, "admin"), ~p"/portal/webhooks")
    assert html =~ "conversation.closed"
    assert has_element?(view, "#webhook-event-#{event.id}", "failed")

    Application.put_env(:converger, :platform_webhook_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end
    )

    view
    |> element("#webhook-event-#{event.id} button", "Redeliver")
    |> render_click()

    assert %Event{status: "delivered"} = Repo.reload!(event)
    assert has_element?(view, "#webhook-event-#{event.id}", "delivered")
  end

  test "portal members can browse but not change anything", %{conn: conn, tenant: tenant} do
    {subscription, event} = failed_event(tenant)

    {:ok, view, html} = live(portal_conn(conn, tenant, "member"), ~p"/portal/webhooks")
    assert html =~ "hooks.example.com/events"
    refute has_element?(view, "#webhook-subscription-form")
    refute has_element?(view, "#webhook-event-#{event.id} button")

    render_click(view, "redeliver", %{"id" => event.id})
    render_click(view, "delete", %{"id" => subscription.id})
    assert Repo.reload!(event).status == "failed"
    assert Repo.get(Subscription, subscription.id)
  end

  test "portal cannot touch another tenant's subscription", %{conn: conn, tenant: tenant} do
    {theirs, their_event} = failed_event(tenant_fixture())

    {:ok, view, html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/webhooks")
    refute html =~ theirs.id

    assert render_click(view, "toggle", %{"id" => theirs.id}) =~ "Unauthorized"
    assert render_click(view, "redeliver", %{"id" => their_event.id}) =~ "Unauthorized"
    assert Repo.reload!(theirs).enabled
    assert Repo.reload!(their_event).status == "failed"
  end

  test "admin sees every tenant's subscriptions", %{conn: conn, tenant: tenant} do
    {subscription, _event} = failed_event(tenant)

    {:ok, view, html} = live(admin_conn(conn), ~p"/admin/webhooks")
    assert html =~ tenant.name
    assert has_element?(view, "#subscription-#{subscription.id}")

    view |> element("#subscription-#{subscription.id} button", "Disable") |> render_click()
    refute Repo.reload!(subscription).enabled
  end
end
