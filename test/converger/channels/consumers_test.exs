defmodule Converger.Channels.ConsumersTest do
  # Consumer lifecycle: Converger.Channels.Consumers and its manager start,
  # restart and stop broker consumers as channels change. Uses the
  # test_broker adapter (Broadway.DummyProducer), no broker.
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Channels.Broker.{Consumer, Pipeline}
  alias Converger.Channels.Consumers
  alias Converger.Channels.Consumers.Manager
  alias Converger.TestBrokerAdapter

  setup do
    put_env(:adapters, [TestBrokerAdapter])
    put_env(:test_broker_pid, self())

    on_exit(fn ->
      for id <- Consumers.local_channel_ids(), do: Consumers.stop_consumer(id)
    end)

    tenant = tenant_fixture()
    %{tenant: tenant, channel: broker_channel(tenant)}
  end

  defp put_env(key, value) do
    previous = Application.get_env(:converger, key)
    Application.put_env(:converger, key, value)
    on_exit(fn -> Application.put_env(:converger, key, previous) end)
  end

  defp broker_channel(tenant, attrs \\ %{}) do
    {:ok, channel} =
      %{
        name: unique_channel_name(),
        type: "test_broker",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{"topic_in" => "in"}
      }
      |> Map.merge(attrs)
      |> Channels.create_channel()

    channel
  end

  defp start_manager do
    start_supervised!({Manager, initial_delay_ms: 600_000, interval_ms: 600_000})
  end

  # PubSub delivered the change notification to the manager's mailbox
  # before update_channel/delete_channel returned; a call waits until it
  # has been handled.
  defp sync(manager), do: :sys.get_state(manager)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  test "the manager starts a consumer for every consuming channel", %{
    tenant: tenant,
    channel: channel
  } do
    outbound = broker_channel(tenant, %{mode: "outbound"})
    inactive = broker_channel(tenant, %{status: "inactive"})
    _websocket = channel_fixture(tenant)

    start_manager()
    :ok = Manager.reconcile()

    assert {pid, _fingerprint} = Consumers.local(channel.id)
    assert Consumer.whereis(channel.id) == pid
    assert Consumers.node_of(channel.id) == node()
    assert Consumers.local(outbound.id) == nil
    assert Consumers.local(inactive.id) == nil
    assert Consumers.local_channel_ids() == [channel.id]
  end

  test "a consumed message becomes an activity and is acknowledged", %{channel: channel} do
    {:ok, _pid} = Consumers.start_consumer(channel)

    ref =
      Broadway.test_message(Pipeline.name(channel.id), ~s({"text": "from the topic"}),
        metadata: %{id: "in/0/1"}
      )

    assert_receive {:ack, ^ref, [_], []}, 5_000

    assert %Activity{text: "from the topic"} =
             Repo.get_by(Activity, idempotency_key: "test_broker:in/0/1")

    # A poison message is dead-lettered and acknowledged as well.
    ref = Broadway.test_message(Pipeline.name(channel.id), "{bad", metadata: %{id: "in/0/2"})
    assert_receive {:ack, ^ref, [_], []}, 5_000
    assert_received {:test_broker_dead_letter, _, %{message_id: "in/0/2"}, _reason}
  end

  test "a channel has one consumer in the cluster", %{channel: channel} do
    assert {:ok, pid} = Consumers.start_consumer(channel)
    assert {:error, {:already_started, ^pid}} = Consumers.start_consumer(channel)
    assert :global.whereis_name({Consumer, channel.id}) == pid
  end

  test "channels that do not consume get no consumer", %{tenant: tenant} do
    assert {:error, :not_a_consumer_channel} = Consumers.start_consumer(channel_fixture(tenant))

    assert {:error, :not_a_consumer_channel} =
             Consumers.start_consumer(broker_channel(tenant, %{mode: "outbound"}))
  end

  test "updating the config restarts the consumer", %{channel: channel} do
    manager = start_manager()
    :ok = Manager.reconcile()
    {pid, fingerprint} = Consumers.local(channel.id)

    {:ok, _} = Channels.update_channel(channel, %{config: %{"topic_in" => "other"}})
    sync(manager)

    assert {new_pid, new_fingerprint} = Consumers.local(channel.id)
    assert new_pid != pid
    assert new_fingerprint != fingerprint
    refute Process.alive?(pid)

    # A change that does not affect the consumer keeps it running.
    {:ok, _} = Channels.update_channel(Channels.get_channel!(channel.id), %{name: "renamed"})
    sync(manager)
    assert {^new_pid, ^new_fingerprint} = Consumers.local(channel.id)
  end

  test "disabling, switching to outbound and deleting stop the consumer", %{
    tenant: tenant,
    channel: channel
  } do
    other = broker_channel(tenant)
    third = broker_channel(tenant)
    manager = start_manager()
    :ok = Manager.reconcile()

    {:ok, _} = Channels.update_channel(channel, %{status: "inactive"})
    {:ok, _} = Channels.update_channel(other, %{mode: "outbound"})
    {:ok, _} = Channels.delete_channel(third)
    sync(manager)

    assert Consumers.local_channel_ids() == []

    # Enabling it again starts it again.
    {:ok, _} = Channels.update_channel(Channels.get_channel!(channel.id), %{status: "active"})
    sync(manager)
    assert Consumers.local(channel.id)
  end

  test "a creation starts the consumer at once", %{tenant: tenant} do
    manager = start_manager()
    channel = broker_channel(tenant)
    sync(manager)
    assert Consumers.local(channel.id)
  end

  test "periodic reconciliation restarts a consumer that stopped", %{channel: channel} do
    start_manager()
    :ok = Manager.reconcile()
    {pid, _} = Consumers.local(channel.id)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # :global drops the name asynchronously, and the pipeline (linked to the
    # killed supervisor) goes down after it.
    wait_until(fn ->
      Consumer.whereis(channel.id) == nil and Process.whereis(Pipeline.name(channel.id)) == nil
    end)

    :ok = Manager.reconcile()
    assert {new_pid, _} = Consumers.local(channel.id)
    assert new_pid != pid
  end

  test "ownership spreads channels over the nodes" do
    ids = for _ <- 1..90, do: Ecto.UUID.generate()

    # Alone, this node owns every channel.
    assert Enum.all?(ids, &Manager.owner?(&1, [node()]))

    # With two more nodes it owns a share, and the owner does not depend on
    # the order of the node list.
    nodes = [node(), :converger_b@host, :converger_c@host]
    owned = Enum.count(ids, &Manager.owner?(&1, nodes))
    assert owned > 0 and owned < length(ids)
    assert Enum.all?(ids, &(Manager.owner?(&1, nodes) == Manager.owner?(&1, Enum.reverse(nodes))))
  end
end
