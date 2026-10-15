defmodule ConvergerWeb.ConversationPresence do
  @moduledoc """
  Cluster-wide presence of the participants of a conversation, under the
  topic `"conversation:<conversation_id>:presence"`, keyed by participant id
  with one meta per live connection (`role`, `name`, `online_at`).

  Fed by `ConvergerWeb.ConvergerChannel` when the conversation's channel has
  presence enabled; each joined connection turns presence diffs into
  `presence` frames. Separate from `ConvergerWeb.SocketPresence`, which tracks
  sockets per channel for forced disconnects.
  """

  use Phoenix.Presence,
    otp_app: :converger,
    pubsub_server: Converger.PubSub

  @doc "Presence topic of a conversation."
  def topic(conversation_id), do: "conversation:#{conversation_id}:presence"
end
