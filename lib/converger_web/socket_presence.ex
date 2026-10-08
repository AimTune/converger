defmodule ConvergerWeb.SocketPresence do
  @moduledoc """
  Cluster-wide tracking of joined client sockets, keyed by socket id under the
  topic `"sockets:channel:<channel_id>"`. Used to disconnect every socket of
  a channel and to count connections. See `ConvergerWeb.Sockets`.
  """

  use Phoenix.Presence,
    otp_app: :converger,
    pubsub_server: Converger.PubSub
end
