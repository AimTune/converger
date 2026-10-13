defmodule ConvergerWeb.WebhookPageLiveTest do
  # Search, secret rotation and the event log's "Load more" on the admin and
  # portal webhook pages. Mutates the global :platform_webhook_req_options.
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures

  alias Converger.{Accounts, AuditLogs, Repo, Webhooks}
  alias Converger.Webhooks.Subscription

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

    tenant = tenant_fixture()

    {:ok, alpha} =
      Webhooks.create_subscription(tenant.id, %{
        "url" => "https://alpha.example.com/hook",
        "events" => ["conversation.closed"]
      })

    {:ok, beta} =
      Webhooks.create_subscription(tenant.id, %{
        "url" => "https://beta.example.com/hook",
        "events" => ["delivery.failed"]
      })

    %{tenant: tenant, alpha: alpha, beta: beta}
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        tenant_id: tenant.id,
        name: "Portal",
        email: "whp-#{System.unique_integer([:positive])}@example.com",
        password: "password-123456",
        role: role
      })

    log_in_tenant_user(conn, user)
  end

  defp admin_conn(conn, role) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "whp-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: role
      })

    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin)
  end

  test "searches subscriptions by URL", %{conn: conn, tenant: tenant, alpha: alpha, beta: beta} do
    {:ok, view, _html} = live(portal_conn(conn, tenant, "viewer"), ~p"/portal/webhooks")
    assert has_element?(view, "#subscription-#{alpha.id}")
    assert has_element?(view, "#subscription-#{beta.id}")

    view
    |> form("#webhook-subscription-search", %{"subscriptions" => %{"q" => "BETA"}})
    |> render_change()

    refute has_element?(view, "#subscription-#{alpha.id}")
    assert has_element?(view, "#subscription-#{beta.id}")

    html =
      view
      |> form("#webhook-subscription-search", %{"subscriptions" => %{"q" => "nothing"}})
      |> render_change()

    assert html =~ "No subscriptions match the search."
  end

  describe "rotate secret" do
    test "portal owner rotates and sees the new secret once", %{
      conn: conn,
      tenant: tenant,
      alpha: alpha
    } do
      {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/webhooks")

      view |> element("#rotate-secret-#{alpha.id}") |> render_click()

      rotated = Repo.get!(Subscription, alpha.id)
      assert rotated.secret != alpha.secret
      assert String.starts_with?(rotated.secret, "whsec_")
      assert has_element?(view, "#new-webhook-secret", rotated.secret)

      assert [log] =
               AuditLogs.list_audit_logs(%{resource_id: alpha.id, action: "update"})

      assert log.actor_type == "tenant_user"
      refute Jason.encode!(log.changes) =~ rotated.secret

      refute render_click(view, "dismiss_secret", %{}) =~ rotated.secret
    end

    test "admin rotates any tenant's subscription", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(admin_conn(conn, "super_admin"), ~p"/admin/webhooks")

      view |> element("#rotate-secret-#{alpha.id}") |> render_click()

      rotated = Repo.get!(Subscription, alpha.id)
      assert rotated.secret != alpha.secret
      assert has_element?(view, "#new-webhook-secret", rotated.secret)
    end

    test "portal members cannot rotate", %{conn: conn, tenant: tenant, alpha: alpha} do
      {:ok, view, _html} = live(portal_conn(conn, tenant, "member"), ~p"/portal/webhooks")
      refute has_element?(view, "#rotate-secret-#{alpha.id}")

      assert render_click(view, "rotate_secret", %{"id" => alpha.id}) =~ "permission"
      assert Repo.get!(Subscription, alpha.id).secret == alpha.secret
    end

    test "admin viewers cannot rotate", %{conn: conn, alpha: alpha} do
      {:ok, view, _html} = live(admin_conn(conn, "viewer"), ~p"/admin/webhooks")
      refute has_element?(view, "#rotate-secret-#{alpha.id}")

      assert render_click(view, "rotate_secret", %{"id" => alpha.id}) =~ "permission"
      assert Repo.get!(Subscription, alpha.id).secret == alpha.secret
    end

    test "a portal owner cannot rotate another tenant's subscription", %{
      conn: conn,
      tenant: tenant
    } do
      other = tenant_fixture()

      {:ok, foreign} =
        Webhooks.create_subscription(other.id, %{
          "url" => "https://other.example.com/hook",
          "events" => ["*"]
        })

      {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/webhooks")

      assert render_click(view, "rotate_secret", %{"id" => foreign.id}) =~ "Unauthorized"
      assert Repo.get!(Subscription, foreign.id).secret == foreign.secret
    end
  end

  test "the event log loads more pages", %{conn: conn, tenant: tenant} do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)

    # Three events for the alpha subscription; the page size is the
    # module's 50 unless the max limit caps it.
    Application.put_env(:converger, :pagination, Keyword.merge(previous || [], max_limit: 2))

    for n <- 1..3,
        do: Webhooks.emit(tenant.id, "conversation.closed", %{conversation_id: "c-#{n}"})

    {:ok, view, html} = live(portal_conn(conn, tenant, "viewer"), ~p"/portal/webhooks")
    assert html =~ "Showing 2 events"

    html = view |> element("#load-more-webhook-events") |> render_click()
    assert html =~ "Showing 3 events"
    refute has_element?(view, "#load-more-webhook-events")
  end
end
