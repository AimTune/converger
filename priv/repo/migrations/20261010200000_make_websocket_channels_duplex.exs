defmodule Converger.Repo.Migrations.MakeWebsocketChannelsDuplex do
  use Ecto.Migration

  # `websocket` channels could only be created in mode `outbound`, so the mode
  # of existing ones was never a choice. They become `duplex`, the default for
  # new channels: their clients can send over the socket and the channel can
  # be a routing rule source. Data-only and safe during a rolling deploy:
  # older code never reads the mode of a websocket channel for delivery.
  def up do
    execute("UPDATE channels SET mode = 'duplex' WHERE type = 'websocket' AND mode = 'outbound'")
  end

  # Channels set to `duplex` here cannot be told apart from those created as
  # `duplex` later, so the rollback leaves modes as they are.
  def down, do: :ok
end
