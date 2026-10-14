defmodule Converger.Backbone.Bootstrap do
  @moduledoc """
  Declares the boot subscriptions (`Converger.Backbone.boot_subscriptions/0`)
  on this node when the application starts, before Oban and the endpoint, so
  no event is published before its subscriptions exist.

  On a node with `consumers: false` (`BACKBONE_CONSUMERS=false`) the
  subscriptions are declared but no broker consumer is started; the Native
  backbone still needs the declarations to enqueue jobs. A consumer that
  cannot start (broker unreachable) is retried every `retry_ms` (5 s).
  """

  use GenServer

  require Logger

  alias Converger.Backbone
  alias Converger.Backbone.{Registry, Subscription}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    pending =
      for {name, topics, handler, opts} <- Backbone.boot_subscriptions(),
          not start(name, topics, handler, opts),
          do: {name, topics, handler, opts}

    {:ok, schedule(pending)}
  end

  @impl true
  def handle_info(:retry, pending) do
    still =
      for {name, topics, handler, opts} = entry <- pending,
          not start(name, topics, handler, opts),
          do: entry

    {:noreply, schedule(still)}
  end

  defp schedule([]), do: []

  defp schedule(pending) do
    Process.send_after(self(), :retry, Backbone.config(:retry_ms, 5_000))
    pending
  end

  # true when the subscription is declared (and its consumer started, when
  # this node runs consumers).
  defp start(name, topics, handler, opts) do
    if Backbone.consumers?() do
      case Backbone.subscribe(topics, handler, Keyword.put(opts, :name, name)) do
        {:ok, _subscription} ->
          true

        {:error, reason} ->
          Logger.warning("Backbone subscription not started; retrying",
            subscription: name,
            error: inspect(reason)
          )

          false
      end
    else
      case Subscription.new(topics, handler, Keyword.put(opts, :name, name)) do
        {:ok, subscription} ->
          Registry.put(subscription)
          true

        {:error, reason} ->
          raise ArgumentError, "invalid backbone subscription #{name}: #{reason}"
      end
    end
  end
end
