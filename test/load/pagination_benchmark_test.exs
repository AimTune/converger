defmodule Converger.PaginationBenchmarkTest do
  @moduledoc """
  Seeded benchmark: admin pages with 100k conversations (issue #18).

  Excluded by default; run with

      mix test test/load/pagination_benchmark_test.exs --include benchmark
  """
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Accounts, Conversations, Repo}
  alias Converger.Conversations.Conversation

  @moduletag :benchmark
  @moduletag timeout: :infinity

  @rows 100_000
  # Generous: a keyset page is an index range scan, typically a few ms.
  @budget_ms 1_000

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    base = ~U[2026-01-01 00:00:00.000000Z]

    1..@rows
    |> Stream.map(fn i ->
      ts = DateTime.add(base, i, :millisecond)

      %{
        id: Ecto.UUID.generate(),
        tenant_id: tenant.id,
        channel_id: channel.id,
        status: if(rem(i, 3) == 0, do: "closed", else: "active"),
        metadata: %{},
        last_seq: 0,
        inserted_at: ts,
        updated_at: ts
      }
    end)
    |> Stream.chunk_every(5_000)
    |> Enum.each(&Repo.insert_all(Conversation, &1))

    Repo.query!("ANALYZE conversations")

    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "bench-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Bench",
        role: "super_admin"
      })

    %{tenant: tenant, admin: admin}
  end

  defp timed(label, fun) do
    {us, result} = :timer.tc(fun)
    ms = div(us, 1000)
    IO.puts("[benchmark] #{label}: #{ms} ms")
    assert ms < @budget_ms, "#{label} took #{ms} ms (budget #{@budget_ms} ms)"
    result
  end

  test "keyset pages stay fast at any depth", %{tenant: tenant} do
    filters = %{"tenant_id" => tenant.id}

    {:ok, page} =
      timed("first page (50)", fn -> Conversations.paginate_conversations(filters, limit: 50) end)

    assert length(page.entries) == 50 and page.has_more

    # Walk 200 pages deep (10k rows), then time the next page.
    cursor =
      Enum.reduce(1..200, page.next_cursor, fn _, cursor ->
        {:ok, p} = Conversations.paginate_conversations(filters, limit: 50, cursor: cursor)
        p.next_cursor
      end)

    timed("page 202 (50)", fn ->
      Conversations.paginate_conversations(filters, limit: 50, cursor: cursor)
    end)

    timed("filtered first page (status=closed)", fn ->
      Conversations.paginate_conversations(Map.put(filters, "status", "closed"), limit: 50)
    end)
  end

  test "admin conversations LiveView mounts and loads more quickly", %{conn: conn, admin: admin} do
    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> init_test_session(%{admin_user_id: admin.id})

    {:ok, view, html} = timed("admin /conversations mount", fn -> live(conn, ~p"/admin/conversations") end)
    assert html =~ "Showing 50 conversations"

    html = timed("admin load more", fn -> view |> element("#load-more-conversations") |> render_click() end)
    assert html =~ "Showing 100 conversations"
  end
end
