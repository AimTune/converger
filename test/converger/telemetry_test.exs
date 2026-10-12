defmodule Converger.TelemetryTest do
  # Mutates global pipeline/adapter config and attaches global handlers.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  alias Converger.{Activities, Deliveries, Inbound, Repo}
  alias Converger.Channels.Circuit
  alias ConvergerWeb.ClientConnections

  @delivery_events [
    [:converger, :delivery, :attempt],
    [:converger, :delivery, :stop],
    [:converger, :delivery, :exception],
    [:converger, :pipeline, :lag]
  ]

  setup do
    previous = Application.get_env(:converger, :webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :webhook_req_options, previous),
        else: Application.delete_env(:converger, :webhook_req_options)
    end)

    Application.put_env(:converger, :webhook_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    %{tenant: tenant_fixture()}
  end

  defp attach(events), do: :telemetry_test.attach_event_handlers(self(), events)

  defp stub_status(status), do: Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, status, ""))

  # Creating an activity delivers it inline (test pipeline backend).
  defp deliver(tenant, channel) do
    conversation = conversation_fixture(tenant, channel)

    {:ok, activity} =
      Activities.create_activity(%{
        sender: "user-1",
        text: "hello",
        tenant_id: tenant.id,
        conversation_id: conversation.id
      })

    activity
  end

  describe "delivery events" do
    test "a sent delivery emits attempt, stop (sent) and pipeline lag", %{tenant: tenant} do
      stub_status(200)
      channel = webhook_channel_fixture(tenant)
      ref = attach(@delivery_events)

      activity = deliver(tenant, channel)
      channel_id = channel.id

      assert_receive {[:converger, :delivery, :attempt], ^ref, %{count: 1},
                      %{channel_id: ^channel_id, attempt: 1, retry: false} = meta}

      assert meta.channel_type == "webhook"
      assert meta.tenant_id == tenant.id
      assert meta.activity_id == activity.id

      assert_receive {[:converger, :delivery, :stop], ^ref, %{duration: duration},
                      %{channel_id: ^channel_id, status: "sent"}}

      assert is_integer(duration) and duration >= 0

      assert_receive {[:converger, :pipeline, :lag], ^ref, %{duration: lag},
                      %{channel_id: ^channel_id, status: "sent"}}

      assert is_integer(lag) and lag >= 0
    end

    test "a retryable failure stops with status failed and no lag", %{tenant: tenant} do
      stub_status(503)
      channel = webhook_channel_fixture(tenant)
      ref = attach(@delivery_events)

      deliver(tenant, channel)
      channel_id = channel.id

      assert_receive {[:converger, :delivery, :stop], ^ref, _,
                      %{channel_id: ^channel_id, status: "failed"}}

      refute_received {[:converger, :pipeline, :lag], ^ref, _, %{channel_id: ^channel_id}}
    end

    test "a permanent failure stops with status dead", %{tenant: tenant} do
      stub_status(400)
      channel = webhook_channel_fixture(tenant)
      ref = attach(@delivery_events)

      deliver(tenant, channel)
      channel_id = channel.id

      assert_receive {[:converger, :delivery, :stop], ^ref, _,
                      %{channel_id: ^channel_id, status: "dead"}}
    end

    test "a retry is reported as attempt 2", %{tenant: tenant} do
      stub_status(503)
      channel = webhook_channel_fixture(tenant)
      activity = deliver(tenant, channel)

      stub_status(200)
      ref = attach(@delivery_events)
      assert :ok = Converger.Pipeline.deliver(activity, channel)

      assert_receive {[:converger, :delivery, :attempt], ^ref, _, %{attempt: 2, retry: true}}
      assert_receive {[:converger, :pipeline, :lag], ^ref, _, %{retry: true}}
    end

    test "an adapter exception emits delivery exception and is re-raised" do
      ref = attach(@delivery_events)
      delivery = %{id: "d", attempts: 0}
      activity = %{id: "a"}
      channel = %{id: "c", type: "webhook", tenant_id: "t"}

      assert_raise RuntimeError, "boom", fn ->
        Converger.Telemetry.delivery_attempt(delivery, activity, channel, fn -> raise "boom" end)
      end

      assert_receive {[:converger, :delivery, :exception], ^ref, %{duration: _},
                      %{channel_id: "c", kind: :error, reason: %RuntimeError{}}}
    end

    test "logs inside the adapter call carry the OpenTelemetry trace id" do
      delivery = %{id: "d", attempts: 0}
      activity = %{id: "a"}
      channel = %{id: "c", type: "webhook", tenant_id: "t"}

      {metadata, _duration} =
        Converger.Telemetry.delivery_attempt(delivery, activity, channel, fn ->
          Logger.metadata()
        end)

      assert metadata[:otel_trace_id]
      assert metadata[:otel_span_id]
    end
  end

  describe "inbound events" do
    test "reports created, duplicate and error outcomes", %{tenant: tenant} do
      channel = channel_fixture(tenant, %{type: "webhook", config: %{"url" => "https://e.x/h"}})
      stub_status(200)
      ref = attach([[:converger, :inbound, :received]])
      channel_id = channel.id
      message = %{"sender" => "u1", "text" => "hi", "idempotency_key" => "k1"}

      assert {:created, _} = Inbound.receive_message(channel, message)
      assert {:duplicate, _} = Inbound.receive_message(channel, message)

      outbound = webhook_channel_fixture(tenant, %{mode: "outbound"})
      assert {:error, :inbound_not_supported} = Inbound.receive_message(outbound, message)

      assert_receive {_, ^ref, %{count: 1},
                      %{channel_id: ^channel_id, channel_type: "webhook", outcome: :created}}

      assert_receive {_, ^ref, _, %{channel_id: ^channel_id, outcome: :duplicate}}
      assert_receive {_, ^ref, _, %{outcome: :error}}
    end
  end

  describe "circuit state changes" do
    test "a manual pause and resume are reported", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      ref = attach([[:converger, :circuit, :state_change]])
      channel_id = channel.id

      {:ok, channel} = Circuit.pause(channel)
      {:ok, _channel} = Circuit.resume(channel)

      assert_receive {_, ^ref, %{count: 1},
                      %{channel_id: ^channel_id, to: "paused", reason: :manual}}

      assert_receive {_, ^ref, _, %{channel_id: ^channel_id, to: "closed", reason: :manual}}
    end
  end

  describe "polled gauges" do
    test "dead letters and open circuits per channel type, zero-filled", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel_fixture(tenant, %{mode: "inbound"}))
      activity = activity_fixture(tenant, conversation)

      activity.id
      |> Deliveries.get_or_create_delivery(channel.id)
      |> Deliveries.mark_dead("boom")

      {:ok, _} = Circuit.pause(channel)

      ref = attach([[:converger, :deliveries, :dead_letters], [:converger, :channels, :circuit]])
      assert :ok = Converger.Telemetry.measure_storage()

      assert_receive {[:converger, :deliveries, :dead_letters], ^ref, %{size: 1},
                      %{channel_type: "webhook"}}

      assert_receive {[:converger, :deliveries, :dead_letters], ^ref, %{size: 0},
                      %{channel_type: "echo"}}

      assert_receive {[:converger, :channels, :circuit], ^ref, %{count: 1},
                      %{channel_type: "webhook", state: "paused"}}

      assert_receive {[:converger, :channels, :circuit], ^ref, %{count: 0},
                      %{channel_type: "webhook", state: "open"}}
    end

    test "Oban queue depth per queue and state, zero-filled" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, _job} =
          %{activity_id: Ecto.UUID.generate(), channel_id: Ecto.UUID.generate()}
          |> Converger.Workers.ActivityDeliveryWorker.new(queue: :deliveries_bulk)
          |> Oban.insert()
      end)

      ref = attach([[:converger, :oban, :queue]])
      assert :ok = Converger.Telemetry.measure_queues()

      assert_receive {_, ^ref, %{depth: 1}, %{queue: "deliveries_bulk", state: "available"}}
      assert_receive {_, ^ref, %{depth: 0}, %{queue: "deliveries_high", state: "available"}}
      assert_receive {_, ^ref, %{depth: 0}, %{queue: "deliveries", state: "retryable"}}
    end

    test "a failing poll is skipped instead of raising" do
      assert :ok = ConvergerWeb.Telemetry.safely(Repo, :unknown_function_for_test)
    end
  end

  describe "client connections" do
    test "the gauge follows the registered processes, however they exit" do
      ref = attach([[:converger, :ws, :connected], [:converger, :ws, :connections]])
      before = ClientConnections.counts()[{"protocol", "sse"}]
      test = self()

      pid =
        spawn(fn ->
          ClientConnections.connected("protocol", "sse")
          send(test, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      assert_receive {[:converger, :ws, :connected], ^ref, %{count: 1}, %{socket: "protocol"}}
      assert ClientConnections.counts()[{"protocol", "sse"}] == before + 1

      ClientConnections.measure()
      count = before + 1

      assert_receive {[:converger, :ws, :connections], ^ref, %{count: ^count},
                      %{socket: "protocol", transport: "sse"}}

      Process.exit(pid, :kill)
      wait_until(fn -> ClientConnections.counts()[{"protocol", "sse"}] == before end)
    end
  end

  describe "Prometheus export" do
    test "every metric registers and the SLO series are exported" do
      name = :"telemetry_test_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TelemetryMetricsPrometheus.Core,
         metrics: ConvergerWeb.Telemetry.metrics(), name: name, start_async: false}
      )

      # A duplicate name or invalid definition is skipped (logged), not raised.
      assert length(TelemetryMetricsPrometheus.Core.Registry.metrics(name)) ==
               length(ConvergerWeb.Telemetry.metrics())

      metadata = %{
        channel_id: "c",
        channel_type: "webhook",
        tenant_id: "t",
        delivery_id: "d",
        activity_id: "a",
        attempt: 1,
        retry: false
      }

      :telemetry.execute([:converger, :delivery, :attempt], %{count: 1}, metadata)

      :telemetry.execute(
        [:converger, :delivery, :stop],
        %{duration: System.convert_time_unit(120, :millisecond, :native)},
        Map.put(metadata, :status, "sent")
      )

      :telemetry.execute(
        [:converger, :pipeline, :lag],
        %{duration: 800},
        Map.put(metadata, :status, "sent")
      )

      :telemetry.execute([:converger, :oban, :queue], %{depth: 3}, %{
        queue: "deliveries",
        state: "available"
      })

      ClientConnections.measure()

      scrape = TelemetryMetricsPrometheus.Core.scrape(name)

      assert scrape =~
               ~s(converger_delivery_attempt_count{channel_type="webhook",retry="false"} 1)

      assert scrape =~
               ~s(converger_delivery_stop_duration_bucket{channel_type="webhook",status="sent",le="250"} 1)

      assert scrape =~
               ~s(converger_pipeline_lag_duration_bucket{channel_type="webhook",retry="false",le="1000"} 1)

      assert scrape =~ ~s(converger_oban_queue_depth{queue="deliveries",state="available"} 3)

      assert scrape =~
               ~s(converger_ws_connections_count{socket="converger",transport="websocket"})
    end
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      true ->
        flunk("condition not met")
    end
  end
end
