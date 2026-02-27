defmodule Converger.Pipeline.Broadway.RabbitmqPush do
  @moduledoc """
  RabbitMQ message push module.

  Requires `{:amqp, "~> 3.3"}` in your deps.

  ## Configuration

      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [
          producer: :rabbitmq,
          rabbitmq: [
            queue: "converger.activities",
            connection: [host: "localhost"]
          ]
        ]
  """

  @behaviour Converger.Pipeline.Broadway.PushBehaviour

  @impl true
  def push(message, config) do
    queue = Keyword.get(config, :queue, "converger.activities")
    conn_opts = Keyword.get(config, :connection, [])

    amqp_conn = Module.concat([:AMQP, :Connection])
    amqp_chan = Module.concat([:AMQP, :Channel])
    amqp_basic = Module.concat([:AMQP, :Basic])

    case Code.ensure_loaded(amqp_conn) do
      {:module, _} ->
        {:ok, conn} = apply(amqp_conn, :open, [conn_opts])
        {:ok, chan} = apply(amqp_chan, :open, [conn])
        apply(amqp_basic, :publish, [chan, "", queue, Jason.encode!(message)])
        apply(amqp_conn, :close, [conn])
        :ok

      {:error, _} ->
        raise """
        RabbitMQ push requires the :amqp library.
        Add {:amqp, "~> 3.3"} to your mix.exs dependencies.
        """
    end
  end
end
