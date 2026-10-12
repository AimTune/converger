defmodule Converger.WebhooksTest do
  # Mutates the global :platform_webhook_req_options / :retry_policy config.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.Channels.{Health, HealthCheck, InboundSignature}
  alias Converger.{Deliveries, Participants, Repo, Retention, Tenants, Webhooks}
  alias Converger.Pipeline.RetryPolicy
  alias Converger.Webhooks.{Event, Subscription}
  alias Converger.Workers.WebhookEventWorker

  @url "https://hooks.example.com/converger-events"

  setup do
    for key <- [:platform_webhook_req_options, :retry_policy] do
      previous = Application.get_env(:converger, key)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, key, previous),
          else: Application.delete_env(:converger, key)
      end)
    end

    Application.put_env(:converger, :platform_webhook_req_options, plug: {Req.Test, __MODULE__})

    respond(200)
    %{tenant: tenant_fixture()}
  end

  # Every request is sent to the test process; the stub answers `status`.
  defp respond(status, headers \\ []) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook, conn, body})

      headers
      |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
      |> Plug.Conn.send_resp(status, "{}")
    end)
  end

  defp subscribe(tenant, events, attrs \\ %{}) do
    {:ok, subscription} =
      Webhooks.create_subscription(
        tenant.id,
        Map.merge(%{"url" => @url, "events" => events}, attrs)
      )

    subscription
  end

  defp events_of(subscription) do
    Repo.all(
      from e in Event, where: e.subscription_id == ^subscription.id, order_by: e.inserted_at
    )
  end

  defp dead_letter_delivery(tenant) do
    channel = webhook_channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel_fixture(tenant))
    activity = activity_fixture(tenant, conversation)
    delivery = Deliveries.get_or_create_delivery(activity.id, channel.id)

    {:ok, dead} =
      Deliveries.mark_attempt_failed(delivery, "provider exploded", %RetryPolicy{max_attempts: 1})

    {dead, activity}
  end

  describe "subscriptions" do
    test "creating generates a secret stored encrypted", %{tenant: tenant} do
      subscription = subscribe(tenant, ["delivery.failed"])

      assert "whsec_" <> _ = subscription.secret
      assert subscription.enabled

      %{rows: [[raw]]} =
        Repo.query!("SELECT secret FROM webhook_subscriptions WHERE id = $1", [
          Ecto.UUID.dump!(subscription.id)
        ])

      refute raw == subscription.secret
      refute String.contains?(raw, subscription.secret)
      assert Repo.get!(Subscription, subscription.id).secret == subscription.secret
    end

    test "validates events, url and headers", %{tenant: tenant} do
      assert {:error, changeset} =
               Webhooks.create_subscription(tenant.id, %{
                 "url" => "http://metadata.test/x",
                 "events" => ["delivery.failed", "bogus.event"],
                 "headers" => %{"x-converger-signature" => "forged"}
               })

      errors = errors_on(changeset)
      assert [message] = errors.events
      assert message =~ "bogus.event"
      assert [url_error] = errors.url
      assert url_error =~ "not allowed"
      assert [headers_error] = errors.headers
      assert headers_error =~ "reserved"

      assert {:error, changeset} =
               Webhooks.create_subscription(tenant.id, %{"url" => @url, "events" => []})

      assert errors_on(changeset).events != []
    end

    test "update and delete", %{tenant: tenant} do
      subscription = subscribe(tenant, ["*"])

      assert {:ok, updated} =
               Webhooks.update_subscription(subscription, %{"enabled" => false}, %{
                 type: "tenant_api",
                 id: tenant.id
               })

      refute updated.enabled
      assert {:ok, _} = Webhooks.delete_subscription(updated)
      assert Webhooks.list_subscriptions(tenant.id) == []
    end
  end

  describe "delivery.failed" do
    test "a dead-lettered delivery sends a signed POST", %{tenant: tenant} do
      subscription = subscribe(tenant, ["delivery.failed"])

      {dead, activity} = dead_letter_delivery(tenant)

      assert_received {:webhook, conn, body}
      assert conn.method == "POST"
      assert conn.request_path == "/converger-events"

      assert InboundSignature.verify(subscription, conn.req_headers, body) == :ok

      assert InboundSignature.verify(%{secret: "wrong"}, conn.req_headers, body) ==
               {:error, :invalid_signature}

      assert Plug.Conn.get_req_header(conn, "x-converger-event") == ["delivery.failed"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

      [event] = events_of(subscription)
      assert Plug.Conn.get_req_header(conn, "x-converger-delivery-id") == [event.id]
      assert Plug.Conn.get_req_header(conn, "x-converger-event-id") == [event.event_id]

      payload = Jason.decode!(body)
      assert payload["id"] == event.event_id
      assert payload["type"] == "delivery.failed"
      assert payload["tenant_id"] == tenant.id
      assert payload["data"]["delivery_id"] == dead.id
      assert payload["data"]["activity_id"] == activity.id
      assert payload["data"]["conversation_id"] == activity.conversation_id
      assert payload["data"]["status"] == "failed"
      assert payload["data"]["last_error"] == "provider exploded"

      assert %Event{status: "delivered", attempts: 1, response_status: 200} = event
      refute_received {:webhook, _, _}
    end

    test "events go only to the tenant's enabled subscriptions for that type", %{tenant: tenant} do
      other_tenant = tenant_fixture()
      other = subscribe(other_tenant, ["delivery.failed"])
      wrong_type = subscribe(tenant, ["delivery.read"])
      disabled = subscribe(tenant, ["delivery.failed"], %{"enabled" => false})
      wildcard = subscribe(tenant, ["*"])

      dead_letter_delivery(tenant)

      assert events_of(other) == []
      assert events_of(wrong_type) == []
      assert events_of(disabled) == []
      assert "delivery.failed" in Enum.map(events_of(wildcard), & &1.type)
    end
  end

  describe "retries and dead letters" do
    test "a transient failure is retried until the shared policy is exhausted", %{tenant: tenant} do
      Application.put_env(:converger, :retry_policy, max_attempts: 2, base_ms: 1_000)
      respond(503)

      subscription = subscribe(tenant, ["delivery.failed"])
      dead_letter_delivery(tenant)

      [event] = events_of(subscription)
      assert %Event{status: "pending", attempts: 1, response_status: 503} = event
      assert event.last_error =~ "503"

      assert {:cancel, _} =
               perform_job(WebhookEventWorker, %{"webhook_event_id" => event.id}, attempt: 2)

      assert %Event{status: "failed", attempts: 2} = Repo.reload!(event)
    end

    test "a permanent failure dead-letters at once", %{tenant: tenant} do
      respond(400)
      subscription = subscribe(tenant, ["delivery.failed"])
      dead_letter_delivery(tenant)

      assert [%Event{status: "failed", attempts: 1, response_status: 400}] =
               events_of(subscription)
    end

    test "events of a disabled subscription are dead-lettered", %{tenant: tenant} do
      respond(503)
      subscription = subscribe(tenant, ["delivery.failed"])
      dead_letter_delivery(tenant)
      [event] = events_of(subscription)

      {:ok, _} = Webhooks.update_subscription(subscription, %{"enabled" => false})

      assert {:cancel, :subscription_disabled} =
               perform_job(WebhookEventWorker, %{"webhook_event_id" => event.id})

      assert %Event{status: "failed", last_error: "subscription disabled"} = Repo.reload!(event)
    end

    test "backoff follows the shared policy, Retry-After wins" do
      Application.put_env(:converger, :retry_policy, base_ms: 2_000, backoff: :linear)

      assert WebhookEventWorker.backoff(%Oban.Job{attempt: 3}) == 6

      error = %Converger.Channels.DeliveryError{reason: "429", retry_after_ms: 42_000}

      assert WebhookEventWorker.backoff(%Oban.Job{
               attempt: 1,
               unsaved_error: %{reason: error}
             }) == 42
    end

    test "redeliver sends a dead-lettered event again", %{tenant: tenant} do
      respond(400)
      subscription = subscribe(tenant, ["delivery.failed"])
      dead_letter_delivery(tenant)
      [event] = events_of(subscription)
      assert event.status == "failed"
      assert_received {:webhook, _, _}

      respond(204)
      actor = %{type: "tenant_api", id: tenant.id}
      assert {:ok, redelivered} = Webhooks.redeliver(event, actor)

      assert_received {:webhook, conn, _body}
      assert Plug.Conn.get_req_header(conn, "x-converger-delivery-id") == [event.id]
      assert %Event{status: "delivered", attempts: 1, response_status: 204} = redelivered
      assert redelivered.redelivered_at

      assert {:error, :not_failed} = Webhooks.redeliver(redelivered, actor)

      assert Repo.exists?(
               from a in Converger.AuditLogs.AuditLog,
                 where: a.action == "redeliver" and a.resource_id == ^event.id
             )
    end
  end

  describe "event sources" do
    test "activity, conversation and opt-out events", %{tenant: tenant} do
      subscription =
        subscribe(tenant, [
          "activity.created",
          "conversation.created",
          "conversation.closed",
          "conversation.reopened",
          "participant.opted_out"
        ])

      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      activity = activity_fixture(tenant, conversation)
      {:ok, closed} = Converger.Conversations.close_conversation(conversation)
      {:ok, _} = Converger.Conversations.reopen_conversation(closed)
      {:ok, _} = Participants.set_opted_out(channel, "+15550001111", true)
      # Opting out again is not a new event.
      {:ok, _} = Participants.set_opted_out(channel, "+15550001111", true)

      events = events_of(subscription)
      types = Enum.map(events, & &1.type)

      assert Enum.count(types, &(&1 == "conversation.created")) == 1
      assert "conversation.closed" in types
      assert "conversation.reopened" in types
      assert Enum.count(types, &(&1 == "participant.opted_out")) == 1

      created =
        Enum.find(events, &(&1.type == "activity.created" and &1.payload["id"] == activity.id))

      assert created.payload["conversation_id"] == conversation.id

      closed_event = Enum.find(events, &(&1.type == "conversation.closed"))
      assert closed_event.payload["conversation_id"] == conversation.id
      assert closed_event.payload["reason"] == "manual"

      opted_out = Enum.find(events, &(&1.type == "participant.opted_out"))
      assert opted_out.payload["external_id"] == "+15550001111"
      assert opted_out.payload["channel_id"] == channel.id
    end
  end

  describe "legacy alert_webhook_url" do
    test "is kept as a managed subscription with the legacy body", %{tenant: tenant} do
      {:ok, tenant} =
        Tenants.update_tenant(tenant, %{alert_webhook_url: "https://alerts.example.com/h"})

      assert [%Subscription{managed_by: "alert_webhook_url"} = managed] =
               Webhooks.list_subscriptions(tenant.id)

      assert managed.url == "https://alerts.example.com/h"
      assert "channel.health_changed" in managed.events

      channel = webhook_channel_fixture(tenant)

      check = %HealthCheck{
        status: "unhealthy",
        failure_rate: 0.75,
        total_deliveries: 4,
        failed_deliveries: 3,
        checked_at: ~U[2026-10-12 10:00:00.000000Z]
      }

      Health.broadcast_health_change(channel, check, "healthy")

      assert_received {:webhook, conn, body}
      assert InboundSignature.verify(managed, conn.req_headers, body) == :ok

      assert %{
               "event" => "channel_health_changed",
               "channel_id" => channel_id,
               "previous_status" => "healthy",
               "new_status" => "unhealthy",
               "failure_rate" => 0.75
             } = Jason.decode!(body)

      assert channel_id == channel.id

      # A breaker re-opened by a failed probe never reached the legacy URL.
      Webhooks.emit(tenant.id, "channel.circuit_opened", %{reason: "probe_failed"})
      refute_received {:webhook, _, _}

      Webhooks.emit(tenant.id, "channel.circuit_opened", %{
        channel_id: channel.id,
        reason: "unhealthy"
      })

      assert_received {:webhook, _conn, body}
      assert %{"event" => "channel.circuit_opened", "reason" => "unhealthy"} = Jason.decode!(body)

      {:ok, tenant} =
        Tenants.update_tenant(tenant, %{alert_webhook_url: "https://alerts.example.com/new"})

      assert [%{url: "https://alerts.example.com/new"}] = Webhooks.list_subscriptions(tenant.id)

      {:ok, tenant} = Tenants.update_tenant(tenant, %{alert_webhook_url: ""})
      assert Webhooks.list_subscriptions(tenant.id) == []
    end
  end

  describe "retention" do
    test "events older than the window are pruned", %{tenant: tenant} do
      respond(400)
      subscription = subscribe(tenant, ["delivery.failed"])
      dead_letter_delivery(tenant)
      dead_letter_delivery(tenant)
      [old, recent] = events_of(subscription)

      from(e in Event, where: e.id == ^old.id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -8, :day)])

      assert %{webhook_events: 1} = Retention.prune()
      assert [%Event{id: id}] = events_of(subscription)
      assert id == recent.id

      assert %{webhook_events: nil} = Retention.prune(webhook_event_days: 0)
    end
  end
end
