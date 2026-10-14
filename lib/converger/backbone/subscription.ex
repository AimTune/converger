defmodule Converger.Backbone.Subscription do
  @moduledoc """
  A subscription to one or more backbone topics.

    * `name` - identifies the subscription across nodes and restarts: the
      consumer group (Kafka), durable consumer (NATS JetStream), queue
      (RabbitMQ) or Oban job argument (Native), and the scope of its
      idempotency receipts. Lowercase letters, digits, `_` and `-`, at most
      64 characters. It is never built from user input.
    * `topics` - the topics it consumes.
    * `handler` - a module implementing `Converger.Backbone.Handler`, or a
      one-argument function returning `:ok` or `{:error, reason}`.
    * `mode` - `:shared` (default): every event is handled once by the
      cluster, durably, with the backbone's `guarantee/0`. `:broadcast`:
      every node handles every event, best effort (real-time fan-out to
      local processes); nothing is kept for a node that is down.
    * `filter` - an optional `(Event.t() -> boolean)` deciding whether the
      subscription wants an event. A module handler's `accept?/1` is used
      when there is no filter.
    * `dedup` - handle an event id at most once (receipts in
      `backbone_receipts`, see `Converger.Backbone.Dispatch`). Default `true`
      for `:shared`, `false` for `:broadcast`.
    * `concurrency` - consumer processors on each node (brokers), default 4.
  """

  @enforce_keys [:name, :topics, :handler]
  defstruct [
    :name,
    :topics,
    :handler,
    :filter,
    :ref,
    mode: :shared,
    dedup: true,
    concurrency: 4
  ]

  @type handler :: module() | (Converger.Backbone.Event.t() -> :ok | {:error, term()})

  @type t :: %__MODULE__{
          name: String.t(),
          topics: [Converger.Backbone.topic()],
          handler: handler(),
          filter: (Converger.Backbone.Event.t() -> boolean()) | nil,
          mode: :shared | :broadcast,
          dedup: boolean(),
          concurrency: pos_integer(),
          ref: term()
        }

  @name_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  @doc """
  Build a subscription. `topics` is a topic or a list of topics; `opts` as
  the struct fields (`:name` is required).
  """
  @spec new(Converger.Backbone.topic() | [Converger.Backbone.topic()], handler(), keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def new(topics, handler, opts) do
    topics = List.wrap(topics)
    name = Keyword.get(opts, :name)
    mode = Keyword.get(opts, :mode, :shared)

    cond do
      not (is_binary(name) and Regex.match?(@name_pattern, name)) ->
        {:error, "subscription name must match #{inspect(@name_pattern.source)}"}

      topics == [] or Enum.any?(topics, &(&1 not in Converger.Backbone.topics())) ->
        {:error, "subscription topics must be in #{inspect(Converger.Backbone.topics())}"}

      mode not in [:shared, :broadcast] ->
        {:error, "subscription mode must be :shared or :broadcast"}

      not valid_handler?(handler) ->
        {:error, "handler must be a Converger.Backbone.Handler module or a 1-arity function"}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           topics: Enum.uniq(topics),
           handler: handler,
           mode: mode,
           filter: Keyword.get(opts, :filter),
           dedup: Keyword.get(opts, :dedup, mode == :shared),
           concurrency: Keyword.get(opts, :concurrency, 4)
         }}
    end
  end

  defp valid_handler?(fun) when is_function(fun, 1), do: true

  defp valid_handler?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :handle_event, 1)
  end

  defp valid_handler?(_), do: false

  @doc "Whether the subscription consumes `topic`."
  def topic?(%__MODULE__{topics: topics}, topic), do: topic in topics
end
