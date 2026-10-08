defmodule Converger.Repo.Migrations.CreateParticipants do
  use Ecto.Migration

  # An external party (phone number, chat id, email) on a channel. Inbound
  # messages without a conversation_id resolve their conversation through it,
  # and outbound adapters read the recipient from it.
  def change do
    create table(:participants, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :tenant_id, references(:tenants, on_delete: :delete_all, type: :uuid), null: false
      add :channel_id, references(:channels, on_delete: :delete_all, type: :uuid), null: false
      add :external_id, :text, null: false
      add :display_name, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:participants, [:channel_id, :external_id])
    create index(:participants, [:tenant_id])

    alter table(:conversations) do
      add :participant_id, references(:participants, on_delete: :nilify_all, type: :uuid)
    end

    create index(:conversations, [:participant_id, :status])
  end
end
