defmodule Converger.Repo.Migrations.AddOptedOutAtToParticipants do
  use Ecto.Migration

  # SMS opt-out (#41, ADR-0045): set when a participant sends STOP, cleared on
  # START; the pipeline fails deliveries to an opted-out participant fast.
  # A nullable column without a default is metadata-only.
  def change do
    alter table(:participants) do
      add :opted_out_at, :utc_datetime_usec
    end
  end
end
