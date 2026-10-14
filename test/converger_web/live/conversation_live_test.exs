defmodule ConvergerWeb.ConversationLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.{Accounts, AuditLogs, Conversations, Deliveries, Participants}

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)

    {:ok, conversation} =
      Participants.resolve_conversation(channel, %{
        "external_id" => "+905551112233",
        "display_name" => "Ayse Customer"
      })

    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp admin_conn(conn, role) do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "conv-#{role}-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Conv #{role}",
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
        name: "Portal #{role}",
        email: "conv-portal-#{System.unique_integer([:positive])}@example.com",
        password: "password-123456",
        role: role
      })

    log_in_tenant_user(conn, user)
  end

  defp row_count(html, prefix) do
    ~r/id="#{prefix}-[0-9a-f-]{36}"/ |> Regex.scan(html) |> length()
  end

  describe "admin conversation list" do
    test "searches by participant external id and keeps the id search", %{
      conn: conn,
      tenant: t,
      channel: ch,
      conversation: conversation
    } do
      other = conversation_fixture(t, ch)
      conn = admin_conn(conn, "super_admin")

      {:ok, view, html} = live(conn, ~p"/admin/conversations?tenant_id=#{t.id}")
      assert row_count(html, "conversations") == 2
      assert html =~ "+905551112233"

      html =
        view
        |> form("#filter-form", filters: %{q: "5551112"})
        |> render_change()

      assert row_count(html, "conversations") == 1
      assert html =~ conversation.id

      {:ok, _view, html} = live(conn, ~p"/admin/conversations?q=#{other.id}")
      assert row_count(html, "conversations") == 1
      assert html =~ other.id

      {:ok, _view, html} = live(conn, ~p"/admin/conversations?tenant_id=#{t.id}&q=nobody")
      assert row_count(html, "conversations") == 0
      assert html =~ "No conversations found"
    end
  end

  describe "admin conversation detail" do
    test "shows the participant panel and tails new activities live", %{
      conn: conn,
      tenant: t,
      conversation: conversation
    } do
      {:ok, view, html} =
        live(admin_conn(conn, "super_admin"), ~p"/admin/conversations/#{conversation.id}")

      assert html =~ "Ayse Customer"
      assert view |> element("#participant-external-id") |> render() =~ "+905551112233"
      assert has_element?(view, "#live-indicator", "Live")
      refute render(view) =~ "hello from the tail"

      activity = activity_fixture(t, conversation, %{text: "hello from the tail"})

      assert has_element?(view, "#activities-#{activity.id}", "hello from the tail")
    end

    test "updates the delivery badge on delivery_status broadcasts", %{
      conn: conn,
      tenant: t,
      conversation: conversation
    } do
      activity = activity_fixture(t, conversation, %{text: "track me"})
      hook = channel_fixture(t, %{type: "echo"})
      delivery = Deliveries.get_or_create_delivery(activity.id, hook.id)

      {:ok, view, _html} =
        live(admin_conn(conn, "super_admin"), ~p"/admin/conversations/#{conversation.id}")

      {:ok, _} = Deliveries.mark_sent(delivery)
      assert has_element?(view, "#delivery-#{activity.id}[data-status=sent]")

      ConvergerWeb.Endpoint.broadcast!("conversation:#{conversation.id}", "delivery_status", %{
        delivery_id: delivery.id,
        activity_id: activity.id,
        status: "read",
        sent_at: nil,
        delivered_at: nil,
        read_at: DateTime.utc_now()
      })

      badge = view |> element("#delivery-#{activity.id}") |> render()
      assert badge =~ ~s(data-status="read")
      # The status is text, not only a symbol.
      assert badge =~ "Delivery status:"
      assert badge =~ "read"
    end

    test "admins close and reopen with an audit entry", %{conn: conn, conversation: conversation} do
      {:ok, view, _html} =
        live(admin_conn(conn, "admin"), ~p"/admin/conversations/#{conversation.id}")

      html = view |> element("#close-conversation") |> render_click()
      assert html =~ "Conversation closed"
      assert Conversations.get_conversation!(conversation.id).status == "closed"
      assert has_element?(view, "#reopen-conversation")
      # The lifecycle event shows up in the transcript.
      assert row_count(render(view), "activities") == 1

      view |> element("#reopen-conversation") |> render_click()
      assert Conversations.get_conversation!(conversation.id).status == "active"
      assert row_count(render(view), "activities") == 2

      actions =
        %{"resource_id" => conversation.id, "resource_type" => "conversation"}
        |> AuditLogs.list_audit_logs()
        |> Enum.map(& &1.action)
        |> Enum.sort()

      assert actions == ["close", "reopen"]
    end

    test "viewers cannot close conversations", %{conn: conn, conversation: conversation} do
      {:ok, view, _html} =
        live(admin_conn(conn, "viewer"), ~p"/admin/conversations/#{conversation.id}")

      refute has_element?(view, "#close-conversation")

      assert render_click(view, "close", %{}) =~ "You don&#39;t have permission"
      assert Conversations.get_conversation!(conversation.id).status == "active"
    end
  end

  describe "portal conversations" do
    test "searches by external id and sorts", %{
      conn: conn,
      tenant: t,
      channel: ch,
      conversation: conversation
    } do
      older = conversation_fixture(t, ch)
      _foreign = conversation_fixture(tenant_fixture(), channel_fixture(tenant_fixture()))

      {:ok, view, html} = live(portal_conn(conn, t, "owner"), ~p"/portal/conversations")
      assert row_count(html, "conversations") == 2

      html =
        view |> form("#portal-conversation-filter", filters: %{q: "+90555"}) |> render_change()

      assert row_count(html, "conversations") == 1
      assert html =~ conversation.id

      html =
        view
        |> form("#portal-conversation-filter", filters: %{q: "", sort: "asc"})
        |> render_change()

      assert row_count(html, "conversations") == 2
      {first, _} = :binary.match(html, conversation.id)
      {second, _} = :binary.match(html, older.id)
      assert first < second
    end

    test "detail shows participant, badges and live activities", %{
      conn: conn,
      tenant: t,
      conversation: conversation
    } do
      activity = activity_fixture(t, conversation, %{text: "earlier"})
      hook = channel_fixture(t, %{type: "echo"})
      delivery = Deliveries.get_or_create_delivery(activity.id, hook.id)
      {:ok, _} = Deliveries.mark_sent(delivery)

      {:ok, view, html} =
        live(portal_conn(conn, t, "member"), ~p"/portal/conversations/#{conversation.id}")

      assert html =~ "Ayse Customer"
      assert has_element?(view, "#delivery-#{activity.id}[data-status=sent]")
      assert has_element?(view, "#live-indicator", "Live")

      live_one = activity_fixture(t, conversation, %{text: "fresh reply"})
      assert has_element?(view, "#activities-#{live_one.id}", "fresh reply")
    end

    test "close/reopen refreshes the transcript", %{conn: conn, tenant: t, conversation: c} do
      activity_fixture(t, c, %{text: "before close"})

      {:ok, view, html} = live(portal_conn(conn, t, "owner"), ~p"/portal/conversations/#{c.id}")
      assert row_count(html, "activities") == 1

      html = view |> element("#close-conversation") |> render_click()
      assert html =~ "Conversation closed"
      assert row_count(html, "activities") == 2
      assert has_element?(view, "#reopen-conversation")

      html = view |> element("#reopen-conversation") |> render_click()
      assert row_count(html, "activities") == 3

      [_, _] =
        AuditLogs.list_audit_logs(%{"resource_id" => c.id, "actor_type" => "tenant_user"})
    end

    test "viewers cannot close", %{conn: conn, tenant: t, conversation: c} do
      {:ok, view, _html} = live(portal_conn(conn, t, "viewer"), ~p"/portal/conversations/#{c.id}")

      refute has_element?(view, "#close-conversation")
      assert render_click(view, "close", %{}) =~ "You don&#39;t have permission"
      assert Conversations.get_conversation!(c.id).status == "active"
    end

    test "another tenant's conversation is not found", %{conn: conn, conversation: c} do
      conn = portal_conn(conn, tenant_fixture(), "owner")

      assert {:error, {:live_redirect, %{to: "/portal/conversations"}}} =
               live(conn, ~p"/portal/conversations/#{c.id}")
    end
  end

  describe "rich messages in the transcript (#68)" do
    @interrupt_id "approve/0:interrupt#0"

    defp typed_fixture(tenant, conversation, message_type, payload) do
      activity_fixture(tenant, conversation, %{
        text: nil,
        sender: "bot",
        message_type: message_type,
        payload: payload
      })
    end

    defp interrupt_payload do
      %{
        "id" => @interrupt_id,
        "data" => %{
          "payload" => %{"title" => "Refund 249.90 TRY?"},
          "actions" => [%{"label" => "Approve", "value" => %{"approved" => true}}]
        }
      }
    end

    test "admin renders typed messages natively and resolves interrupts live", %{
      conn: conn,
      tenant: t,
      conversation: c
    } do
      card =
        typed_fixture(t, c, "card", %{
          "data" => %{
            "title" => "<script>alert(1)</script>",
            "subtitle" => "249.90 USD",
            "buttons" => [%{"label" => "Track", "value" => "/track"}]
          }
        })

      tool =
        typed_fixture(t, c, "tool_call", %{
          "data" => %{"id" => "t1", "name" => "get_order", "status" => "running"}
        })

      interrupt = typed_fixture(t, c, "interrupt", interrupt_payload())

      {:ok, view, html} = live(admin_conn(conn, "super_admin"), ~p"/admin/conversations/#{c.id}")

      refute html =~ "<script>alert(1)"
      refute html =~ "javascript:"
      assert has_element?(view, "#activities-#{card.id} [data-message-type=card]", "249.90 USD")
      assert has_element?(view, "#activities-#{tool.id} details", "get_order")

      assert has_element?(
               view,
               "#activities-#{interrupt.id} [data-interrupt-state=open]"
             )

      resolved =
        typed_fixture(t, c, "interrupt_resolved", %{
          "id" => @interrupt_id,
          "data" => %{"answer" => %{"approved" => true}}
        })

      assert has_element?(view, "#activities-#{resolved.id}", "resolved")

      assert has_element?(
               view,
               "#activities-#{interrupt.id} [data-interrupt-state=resolved]"
             )
    end

    test "portal renders typed messages and resolved interrupts", %{
      conn: conn,
      tenant: t,
      conversation: c
    } do
      interrupt = typed_fixture(t, c, "interrupt", interrupt_payload())

      typed_fixture(t, c, "interrupt_resolved", %{"id" => @interrupt_id, "data" => %{}})

      {:ok, view, _html} = live(portal_conn(conn, t, "member"), ~p"/portal/conversations/#{c.id}")

      assert has_element?(view, "#activities-#{interrupt.id} [data-interrupt-state=resolved]")

      live_one =
        typed_fixture(t, c, "location", %{
          "data" => %{"latitude" => 41.0082, "longitude" => 28.9784, "name" => "Head office"}
        })

      assert has_element?(
               view,
               "#activities-#{live_one.id} a[href^='https://www.openstreetmap.org/']"
             )

      assert has_element?(view, "#activities-#{live_one.id}", "Head office")
    end
  end
end
