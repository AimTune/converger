defmodule Converger.Channels.Broker.Pipeline do
  @moduledoc """
  The Broadway consumer of one broker channel. The producer (topic or queue)
  and the processor concurrency come from the adapter
  (`c:Converger.Channels.Broker.consumer_options/1`); every message goes
  through `Converger.Channels.Broker.handle/4`, which accepts or
  dead-letters it, so every message is acknowledged as successful.

  The pipeline is named `:"converger_consumer_<channel id>"` (Broadway and
  `BroadwayKafka` derive their process and client names from it, as atoms).
  """

  use Broadway

  alias Converger.Channels.Broker

  @doc "Start the consumer pipeline of `channel`."
  def start_link(channel) do
    with {:ok, adapter} <- adapter(channel),
         {:ok, options} <- adapter.consumer_options(channel) do
      Broadway.start_link(
        __MODULE__,
        Keyword.merge(options,
          name: name(channel.id),
          context: %{channel: channel, adapter: adapter}
        )
      )
    end
  end

  defp adapter(channel) do
    case Broker.adapter(channel) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, "#{channel.type} is not a broker channel type"}
    end
  end

  @doc "The Broadway name of the consumer of `channel_id`."
  @spec name(String.t()) :: atom()
  # One atom per broker channel, from its validated UUID (not from input).
  # sobelow_skip ["DOS.BinToAtom"]
  def name(channel_id) do
    {:ok, uuid} = Ecto.UUID.cast(channel_id)
    :"converger_consumer_#{uuid}"
  end

  @impl true
  def handle_message(_processor, message, %{channel: channel, adapter: adapter}) do
    info = adapter.message_info(channel, message)
    _outcome = Broker.handle(channel, adapter, info)
    message
  end
end
