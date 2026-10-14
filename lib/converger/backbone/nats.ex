defmodule Converger.Backbone.Nats do
  @moduledoc """
  NATS JetStream as the event backbone.

    * **Streams**: one per topic, `<PREFIX>_ACTIVITIES`, `<PREFIX>_DELIVERIES`,
      `<PREFIX>_EVENTS` (prefix `CONVERGER`), each capturing the subject
      `<prefix>.<topic>`, created at boot when missing (`replicas`,
      `max_age_seconds`, `duplicate_window_seconds`).
    * **Publish**: a JetStream publish with `Nats-Msg-Id` set to the event id,
      so the stream drops a duplicate publish (a parked event published
      again) within the duplicate window. Returns once the stream stored it.
    * **Shared subscriptions**: a durable pull consumer per subscription and
      stream (`<prefix>_<subscription>`, explicit acks), pulled by a
      Broadway pipeline on every node running consumers
      (`Converger.Channels.Broker.NatsProducer`). An event is acknowledged
      after it is handled or parked; an unacknowledged one is redelivered
      after `ack_wait_seconds`, and the subscription's receipts skip it if it
      was handled.
    * **Broadcast subscriptions**: a durable consumer per node
      (`<prefix>_<subscription>_<node>`) delivering new messages only.

  Ordering: a stream keeps publish order; with consumer `concurrency` above 1
  events of a conversation may be handled out of order. Set the
  subscription's `concurrency: 1` when order matters.

  ## Configuration

      config :converger, Converger.Backbone.Nats,
        servers: "nats://nats-1:4222,nats://nats-2:4222",
        username: nil, password: nil, token: nil, creds: nil, nkey_seed: nil,
        tls: false, tls_verify: true, tls_ca_cert: nil,
        replicas: 1,
        max_age_seconds: 604_800,
        duplicate_window_seconds: 120,
        ack_wait_seconds: 30,
        batch_size: 10,
        publish_timeout_ms: 10_000

  Set from `BACKBONE_NATS_*` in `config/runtime.exs`. Servers come from the
  operator, so the webhook SSRF guard does not apply to them.
  """

  @behaviour Converger.Backbone

  alias Converger.Backbone
  alias Converger.Backbone.{Event, Subscription}
  alias Converger.Backbone.Nats.Connection
  alias Converger.Channels.Broker.{NatsProducer, NatsPublisher}

  @impl true
  def guarantee, do: :at_least_once

  @impl true
  def child_specs, do: [{Connection, config()}]

  @impl true
  def publish(topic, %Event{} = event) do
    timeout = Keyword.get(config(), :publish_timeout_ms, 10_000)
    headers = [{"Nats-Msg-Id", event.id} | Event.headers(event)]

    with {:ok, conn} <- Connection.conn(),
         {:ok, %{body: body}} <-
           Gnat.request(conn, subject(topic), Event.encode(event),
             headers: headers,
             receive_timeout: timeout
           ),
         {:ok, _ack} <- NatsPublisher.publish_ack(body) do
      :ok
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def subscribe(%Subscription{} = subscription) do
    # One pipeline per stream: a JetStream consumer reads one stream.
    results =
      for topic <- subscription.topics do
        producer =
          {NatsProducer,
           [
             config: channel_config(config()),
             stream: stream(topic),
             subject: subject(topic),
             durable_name: durable_name(subscription),
             dlq_subject: subject(topic),
             declare: false,
             deliver_policy: if(subscription.mode == :broadcast, do: :new, else: :all),
             ack_wait_ms: Keyword.get(config(), :ack_wait_seconds, 30) * 1_000,
             batch_size: Keyword.get(config(), :batch_size, 10),
             connect_opts: [guard: false]
           ]}

        DynamicSupervisor.start_child(
          Converger.Backbone.Consumers,
          {Converger.Backbone.Pipeline,
           {subscription, producer, [name: pipeline_name(subscription, topic)]}}
        )
      end

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {_ok, []} ->
        {:ok,
         %{subscription | ref: Enum.map(subscription.topics, &pipeline_name(subscription, &1))}}

      {ok, [{:error, reason} | _]} ->
        for {:ok, pid} <- ok,
            do: DynamicSupervisor.terminate_child(Converger.Backbone.Consumers, pid)

        {:error, reason}
    end
  end

  @impl true
  def unsubscribe(%Subscription{ref: names}) when is_list(names),
    do: Converger.Backbone.Pipeline.stop(names)

  def unsubscribe(_subscription), do: :ok

  # Names are validated and come from code or config: one atom per
  # subscription and topic.
  # sobelow_skip ["DOS.BinToAtom"]
  defp pipeline_name(subscription, topic),
    do: :"converger_backbone_#{subscription.name}_#{topic}"

  @doc "The stream of a topic (`CONVERGER_ACTIVITIES`)."
  def stream(topic),
    do: "#{prefix_token() |> String.upcase()}_#{topic |> Atom.to_string() |> String.upcase()}"

  @doc "The subject of a topic (`converger.activities`)."
  def subject(topic), do: Backbone.topic_name(topic)

  @doc "The durable consumer of a subscription."
  def durable_name(%Subscription{mode: :shared, name: name}), do: "#{prefix_token()}_#{name}"

  def durable_name(%Subscription{mode: :broadcast, name: name}),
    do: "#{prefix_token()}_#{name}_#{node_slug()}"

  defp prefix_token, do: Backbone.topic_prefix() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

  defp node_slug, do: node() |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

  @doc "The config as a NATS channel config map, to reuse the adapter's connection code."
  def channel_config(config) do
    %{
      "servers" => Keyword.get(config, :servers, "nats://localhost:4222"),
      "username" => Keyword.get(config, :username),
      "password" => Keyword.get(config, :password),
      "token" => Keyword.get(config, :token),
      "creds" => Keyword.get(config, :creds),
      "nkey_seed" => Keyword.get(config, :nkey_seed),
      "tls" => Keyword.get(config, :tls, false),
      "tls_verify" => Keyword.get(config, :tls_verify, true),
      "tls_ca_cert" => Keyword.get(config, :tls_ca_cert)
    }
  end

  @doc false
  def config, do: Application.get_env(:converger, __MODULE__, [])
end
