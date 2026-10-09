defmodule Converger.ReceiptsTest do
  use Converger.DataCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.{Activities, Receipts}

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    for text <- ~w(one two three) do
      {:ok, _} =
        Activities.create_activity(%{
          "tenant_id" => tenant.id,
          "conversation_id" => conversation.id,
          "sender" => "bot",
          "text" => text
        })
    end

    %{conversation: conversation}
  end

  test "the read watermark only moves forward", %{conversation: conversation} do
    assert {:ok, :advanced, 2} = Receipts.mark_read(conversation, "user-1", 2)
    assert {:ok, :unchanged, 2} = Receipts.mark_read(conversation, "user-1", 1)
    assert {:ok, :unchanged, 2} = Receipts.mark_read(conversation, "user-1", 2)
    assert {:ok, :advanced, 3} = Receipts.mark_read(conversation, "user-1", 3)
    assert Receipts.read_seq(conversation.id, "user-1") == 3
  end

  test "a watermark above the head is capped at the head seq", %{conversation: conversation} do
    assert {:ok, :advanced, 3} = Receipts.mark_read(conversation, "user-1", 99)
  end

  test "readers are independent", %{conversation: conversation} do
    {:ok, :advanced, 3} = Receipts.mark_read(conversation, "user-1", 3)
    assert {:ok, :advanced, 1} = Receipts.mark_read(conversation, "agent-7", 1)

    assert [%{reader_id: "agent-7", read_seq: 1}, %{reader_id: "user-1", read_seq: 3}] =
             Receipts.list_read_positions(conversation.id)
  end

  test "an empty conversation has nothing to read" do
    tenant = tenant_fixture()
    conversation = conversation_fixture(tenant, channel_fixture(tenant))

    assert {:ok, :unchanged, 0} = Receipts.mark_read(conversation, "user-1", 5)
    assert Receipts.read_seq(conversation.id, "user-1") == 0
  end

  test "invalid watermarks are rejected", %{conversation: conversation} do
    assert {:error, :invalid_watermark} = Receipts.mark_read(conversation, "user-1", 0)
    assert {:error, :invalid_watermark} = Receipts.mark_read(conversation, "user-1", "3")
  end
end
