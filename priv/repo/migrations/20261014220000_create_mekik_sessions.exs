defmodule Converger.Repo.Migrations.CreateMekikSessions do
  @moduledoc """
  The upstream mekik conversation of each (mekik channel, Converger
  conversation) pair (`mekik` channel adapter, Mode A of #64, ADR-0066).

  A mekik/1 server mints its own `conversationId` on the first connect and
  adopts an asserted one only when it exists and belongs to the connecting
  `userId`, so the adapter has to remember both to resume the same mekik
  conversation (and its parked interrupts) after a restart. `watermark` is
  the highest mekik persistent-frame `seq` the adapter has handled; it is
  written lazily, a lagging value only replays frames whose storage is
  idempotent.
  """
  use Ecto.Migration

  def change do
    create table(:mekik_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :mekik_conversation_id, :text, null: false
      add :mekik_user_id, :text, null: false
      add :watermark, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mekik_sessions, [:channel_id, :conversation_id])
    create index(:mekik_sessions, [:conversation_id])
    create index(:mekik_sessions, [:tenant_id])
  end
end
