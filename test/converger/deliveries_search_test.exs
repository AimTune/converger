defmodule Converger.DeliveriesSearchTest do
  # Mutates the global :webhook_req_options (retried jobs run inline).
  use Converger.DataCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures
  import Ecto.Query

  alias Converger.Deliveries
  alias Converger.Deliveries.Delivery

  setup do
    previous = Application.get_env(:converger, :webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :webhook_req_options, previous),
        else: Application.delete_env(:converger, :webhook_req_options)
    end)

    Application.put_env(:converger, :webhook_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end,
      retry: false
    )

    tenant = tenant_fixture()
    channel = webhook_channel_fixture(tenant)
    old = failed(tenant, channel, "timeout 50%_done", ~U[2026-01-01 00:00:00Z])
    new = failed(tenant, channel, "HTTP 500", ~U[2026-01-02 00:00:00Z])
    %{old: old, new: new}
  end

  defp failed(tenant, channel, error, updated_at) do
    activity = activity_fixture(tenant, conversation_fixture(tenant, channel_fixture(tenant)))

    {:ok, delivery} =
      activity.id
      |> Deliveries.get_or_create_delivery(channel.id)
      |> Delivery.changeset(%{status: "failed", last_error: error})
      |> Repo.update()

    from(d in Delivery, where: d.id == ^delivery.id)
    |> Repo.update_all(set: [updated_at: updated_at])

    Repo.get!(Delivery, delivery.id)
  end

  defp ids(filters) do
    {:ok, page} = Deliveries.search_deliveries(Map.put(filters, :status, "failed"))
    Enum.map(page.entries, & &1.id)
  end

  describe "cast_search_params/1" do
    test "casts q and sort on top of the filters" do
      assert {:ok, %{status: "failed", q: "boom", direction: :asc}} =
               Deliveries.cast_search_params(%{
                 "status" => "failed",
                 "q" => "boom",
                 "sort" => "oldest"
               })

      assert {:ok, filters} = Deliveries.cast_search_params(%{"q" => "  ", "sort" => ""})
      assert filters == %{direction: :desc}

      assert {:error, "Invalid sort"} = Deliveries.cast_search_params(%{"sort" => "x"})
      assert {:error, "Invalid status"} = Deliveries.cast_search_params(%{"status" => "x"})
    end
  end

  describe "search_deliveries/2 with :q and :direction" do
    test "matches error text literally and case-insensitively", %{old: old, new: new} do
      assert ids(%{q: "50%_"}) == [old.id]
      assert ids(%{q: "http"}) == [new.id]
      assert ids(%{q: "%"}) == [old.id]
    end

    test "matches an exact activity id", %{old: old} do
      assert ids(%{q: old.activity_id}) == [old.id]
    end

    test "orders by updated_at in the requested direction", %{old: old, new: new} do
      assert ids(%{}) == [new.id, old.id]
      assert ids(%{direction: :asc}) == [old.id, new.id]
    end
  end

  test "retry_dead_letters/2 applies the search", %{old: old, new: new} do
    assert {:ok, %{retried: 1}} =
             Deliveries.retry_dead_letters(%{q: "timeout"}, %{type: "system", id: "test"})

    assert Repo.get!(Delivery, old.id).status == "pending"
    assert Repo.get!(Delivery, new.id).status == "failed"
  end
end
