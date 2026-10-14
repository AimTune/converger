defmodule Converger.Repo.Migrations.AddInterruptIndexToActivities do
  use Ecto.Migration

  # `welcome.data.pending` re-announces a conversation's open mekik interrupts
  # on every handshake (#63, #65): `Converger.Activities.open_interrupts/1`
  # looks up the conversation's `interrupt` and `interrupt_resolved`
  # activities. This partial index holds only those rows, so the lookup does
  # not read the whole conversation. `activities` is partitioned by month
  # (ADR-0034), which rules out CONCURRENTLY: the build scans every partition
  # (blocking writes meanwhile) but writes only the few interrupt rows.
  def change do
    create_if_not_exists index(:activities, [:conversation_id, :seq],
                           name: :activities_interrupts_index,
                           where: "message_type IN ('interrupt', 'interrupt_resolved')"
                         )
  end
end
