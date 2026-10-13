defmodule Converger.AuditLogsSearchTest do
  use Converger.DataCase, async: true

  import Converger.AuditLogsFixtures
  import Ecto.Query

  alias Converger.AuditLogs
  alias Converger.AuditLogs.AuditLog

  setup do
    old = log_at(%{actor_id: "ops_50%@example.com"}, ~U[2026-01-01 12:00:00Z])
    new = log_at(%{actor_id: "dev@example.com"}, ~U[2026-03-01 12:00:00Z])
    %{old: old, new: new}
  end

  defp log_at(attrs, inserted_at) do
    log = audit_log_fixture(attrs)

    from(a in AuditLog, where: a.id == ^log.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    Repo.get!(AuditLog, log.id)
  end

  defp ids(filters) do
    {:ok, page} = AuditLogs.paginate_audit_logs(filters)
    Enum.map(page.entries, & &1.id)
  end

  test "q matches the actor (contains, literal) or the exact resource id", %{old: old, new: new} do
    assert ids(%{"q" => "OPS_50%"}) == [old.id]
    assert ids(%{"q" => "example.com"}) == [new.id, old.id]
    assert ids(%{"q" => new.resource_id}) == [new.id]
  end

  test "sort oldest first", %{old: old, new: new} do
    assert ids(%{"sort" => "oldest"}) == [old.id, new.id]
    assert ids(%{"sort" => "newest"}) == [new.id, old.id]
  end

  test "from/to are inclusive dates", %{old: old, new: new} do
    assert ids(%{"from" => "2026-03-01"}) == [new.id]
    assert ids(%{"to" => "2026-01-01"}) == [old.id]
    assert ids(%{"from" => "2026-01-02", "to" => "2026-02-28"}) == []
  end

  test "invalid uuids and dates match nothing" do
    assert ids(%{"tenant_id" => "nope"}) == []
    assert ids(%{"resource_id" => "nope"}) == []
    assert ids(%{"from" => "yesterday"}) == []
  end
end
