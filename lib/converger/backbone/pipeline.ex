defmodule Converger.Backbone.Pipeline do
  @moduledoc """
  The Broadway consumer of one backbone subscription on a broker backbone
  (Kafka, NATS JetStream, RabbitMQ), started under
  `Converger.Backbone.Consumers`. The producer comes from the backbone
  implementation; every message is decoded (`Converger.Backbone.Event.decode/1`)
  and handed to `Converger.Backbone.Dispatch.consume/2`, which returns only
  once the event is handled, a duplicate, filtered out or parked in Postgres.
  The message is then acknowledged (offset committed, `+ACK`, `basic.ack`).
  A message that is not a backbone event is logged and acknowledged.

  The pipeline is named `:"converger_backbone_<subscription>"`: Broadway and
  `BroadwayKafka` derive process and client names from it.
  """

  use Broadway

  require Logger

  alias Converger.Backbone.{Dispatch, Event, Subscription}

  @doc """
  Start the pipeline of `subscription` with `producer` (a
  `{module, options}` Broadway producer). `opts`: `:name` (default
  `name/1`), `:producer_concurrency` (default 1).
  """
  def start_link({%Subscription{} = subscription, producer, opts}) do
    options = [
      name: Keyword.get(opts, :name, name(subscription)),
      producer: [module: producer, concurrency: Keyword.get(opts, :producer_concurrency, 1)],
      processors: [default: [concurrency: subscription.concurrency]],
      context: %{subscription: subscription}
    ]

    start(options, 50)
  end

  # After a crash the processes of the previous incarnation may still hold
  # their names for a moment (supervisors shutting their children down):
  # wait for them instead of failing the restart.
  defp start(options, tries) do
    case Broadway.start_link(__MODULE__, options) do
      {:error, reason} = error ->
        if tries > 0 and inspect(reason) =~ "already_started" do
          Process.sleep(100)
          start(options, tries - 1)
        else
          error
        end

      ok ->
        ok
    end
  end

  def child_spec({%Subscription{} = subscription, _producer, _opts} = arg) do
    %{
      id: {__MODULE__, subscription.name},
      start: {__MODULE__, :start_link, [arg]},
      restart: :transient,
      shutdown: 30_000,
      type: :supervisor
    }
  end

  @doc "The Broadway name of a subscription's pipeline."
  # Subscription names are validated (Subscription.new/3) and come from code
  # or config, never from user input: one atom per subscription.
  # sobelow_skip ["DOS.BinToAtom"]
  def name(%Subscription{name: name}), do: :"converger_backbone_#{name}"

  @doc """
  Stop the pipelines named `names` (the `ref` of a broker subscription),
  wherever their supervisor restarted them.
  """
  @spec stop([atom()]) :: :ok
  def stop(names) do
    for name <- List.wrap(names), pid = Process.whereis(name), is_pid(pid) do
      DynamicSupervisor.terminate_child(Converger.Backbone.Consumers, pid)
    end

    :ok
  end

  @impl true
  def handle_message(_processor, %Broadway.Message{data: data} = message, %{
        subscription: subscription
      }) do
    case Event.decode(data) do
      {:ok, event} ->
        _outcome = Dispatch.consume(subscription, event)
        message

      {:error, reason} ->
        Logger.error("Backbone message is not an event; acknowledged and dropped",
          subscription: subscription.name,
          error: inspect(reason)
        )

        :telemetry.execute([:converger, :backbone, :poison], %{count: 1}, %{
          subscription: subscription.name
        })

        message
    end
  end
end
