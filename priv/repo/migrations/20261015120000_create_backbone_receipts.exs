defmodule Converger.Repo.Migrations.CreateBackboneReceipts do
  @moduledoc """
  Idempotency receipts of the event backbone (issue #66, ADR-0070): one row
  per (subscription, event id) that a deduplicating subscription handled,
  written in the same transaction as the handler's own writes. A
  redelivered event (broker redelivery after a crash, a parked retry, the
  mirror of a dual-publish migration) finds its receipt and is skipped.
  Pruned after `Converger.Retention` `:backbone_receipt_days` (7).
  """
  use Ecto.Migration

  def change do
    create table(:backbone_receipts) do
      add :subscription, :text, null: false
      add :event_id, :uuid, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:backbone_receipts, [:subscription, :event_id])
    create index(:backbone_receipts, [:inserted_at])
  end
end
