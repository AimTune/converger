defmodule ConvergerWeb.AuditLogLiveTest do
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.AuditLogsFixtures
  import Ecto.Query

  alias Converger.{Accounts, Repo}
  alias Converger.AuditLogs.AuditLog

  setup %{conn: conn} do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "audit-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Admin",
        role: "viewer"
      })

    conn = conn |> Map.put(:remote_ip, {127, 0, 0, 1}) |> log_in_admin(admin)

    old = log_at(%{actor_id: "alice@example.com", action: "create"}, ~U[2026-01-01 10:00:00Z])
    new = log_at(%{actor_id: "bob@example.com", action: "delete"}, ~U[2026-02-01 10:00:00Z])

    %{conn: conn, old: old, new: new}
  end

  defp log_at(attrs, inserted_at) do
    log = audit_log_fixture(attrs)

    from(a in AuditLog, where: a.id == ^log.id)
    |> Repo.update_all(set: [inserted_at: inserted_at])

    Repo.get!(AuditLog, log.id)
  end

  # The fixture rows in page order (other entries, e.g. from the admin
  # login, are ignored).
  defp row_ids(view, %{old: old, new: new}) do
    ~r/id="audit_logs-([0-9a-f-]{36})"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&(&1 in [old.id, new.id]))
  end

  test "searches the actor and patches the URL", %{conn: conn, old: old, new: new} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin/audit_logs")
    assert row_ids(view, ctx) == [new.id, old.id]

    view
    |> form("#audit-filter-form", %{"filters" => %{"q" => "ALICE"}})
    |> render_change()

    assert assert_patch(view) =~ "q=ALICE"
    assert row_ids(view, ctx) == [old.id]
  end

  test "searches an exact resource id", %{conn: conn, old: old, new: new} do
    {:ok, view, _html} = live(conn, ~p"/admin/audit_logs?#{[q: new.resource_id]}")
    assert has_element?(view, "#audit_logs-#{new.id}")
    refute has_element?(view, "#audit_logs-#{old.id}")
  end

  test "sorts oldest first", %{conn: conn, old: old, new: new} = ctx do
    {:ok, view, _html} = live(conn, ~p"/admin/audit_logs")

    view
    |> form("#audit-filter-form", %{"filters" => %{"sort" => "oldest"}})
    |> render_change()

    assert row_ids(view, ctx) == [old.id, new.id]
  end

  test "filters by date range and action from the URL", %{conn: conn, old: old, new: new} do
    {:ok, view, _html} =
      live(conn, ~p"/admin/audit_logs?#{[from: "2026-01-15", to: "2026-02-01"]}")

    assert has_element?(view, "#audit_logs-#{new.id}")
    refute has_element?(view, "#audit_logs-#{old.id}")

    {:ok, view, _html} = live(conn, ~p"/admin/audit_logs?#{[action: "create", to: "2026-01-01"]}")
    assert has_element?(view, "#audit_logs-#{old.id}")
    refute has_element?(view, "#audit_logs-#{new.id}")
  end

  test "invalid ids and dates match nothing instead of crashing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/audit_logs?#{[tenant_id: "nope", from: "x"]}")
    assert html =~ "No audit logs found"
  end

  test "Load more keeps the filters and sort", %{conn: conn, old: old, new: new} = ctx do
    previous = Application.get_env(:converger, :pagination)
    on_exit(fn -> Application.put_env(:converger, :pagination, previous) end)
    Application.put_env(:converger, :pagination, Keyword.merge(previous || [], default_limit: 1))

    {:ok, view, _html} =
      live(conn, ~p"/admin/audit_logs?#{[q: "example.com", sort: "oldest"]}")

    assert row_ids(view, ctx) == [old.id]

    view |> element("#load-more-audit-logs") |> render_click()
    assert row_ids(view, ctx) == [old.id, new.id]
    refute has_element?(view, "#load-more-audit-logs")
  end
end
