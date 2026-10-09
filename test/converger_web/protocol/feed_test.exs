defmodule ConvergerWeb.Protocol.FeedTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Activities
  alias Converger.Activities.Serializer
  alias ConvergerWeb.Protocol.Feed

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    activities =
      for text <- ~w(one two three four) do
        {:ok, activity} =
          Activities.create_activity(%{
            "type" => "message",
            "text" => text,
            "sender" => "alice",
            "tenant_id" => tenant.id,
            "conversation_id" => conversation.id
          })

        activity
      end

    %{conversation: conversation, activities: activities}
  end

  defp seqs(frames), do: Enum.map(frames, & &1["seq"])

  test "replay continues live after the head", %{conversation: c, activities: activities} do
    {frames, feed} = Feed.replay(Feed.new(c.id, "alice"), {:seq, 2}, 4)
    assert seqs(frames) == [3, 4]
    assert feed.last_seq == 4

    # Already replayed: dropped.
    assert {[], _} = Feed.live(feed, Serializer.canonical(Enum.at(activities, 3)))
  end

  test "frames are rendered relative to the end user", %{conversation: c} do
    {[frame | _], _} = Feed.replay(Feed.new(c.id, "alice"), nil, 4)
    assert %{"from" => "user", "sender" => %{"id" => "alice", "role" => "user"}} = frame

    {[frame | _], _} = Feed.replay(Feed.new(c.id, "bob"), nil, 4)
    assert %{"from" => "bot", "sender" => %{"role" => "bot"}} = frame
  end

  test "a live frame after a gap reads the missing range first", ctx do
    feed = Feed.seek(Feed.new(ctx.conversation.id, "bob"), 1)
    fourth = Serializer.canonical(Enum.at(ctx.activities, 3))

    {frames, feed} = Feed.live(feed, fourth)
    assert seqs(frames) == [2, 3, 4]
    assert feed.last_seq == 4
  end

  test "own turns are never delivered back (echo rule)", ctx do
    feed = ctx.conversation.id |> Feed.new("alice") |> Feed.seek(1) |> Feed.own(3)
    fourth = Serializer.canonical(Enum.at(ctx.activities, 3))

    {frames, feed} = Feed.live(feed, fourth)
    assert seqs(frames) == [2, 4]
    assert MapSet.size(feed.own) == 0
  end

  test "replay is bounded by replayMax and reports truncation", ctx do
    Application.put_env(:converger, ConvergerWeb.Protocol, replay_max: 2)
    on_exit(fn -> Application.delete_env(:converger, ConvergerWeb.Protocol) end)

    {frames, feed} = Feed.replay(Feed.new(ctx.conversation.id, "bob"), nil, 4)

    assert [%{"seq" => 1}, %{"seq" => 2}, truncated] = frames

    assert truncated == %{
             "type" => "replayTruncated",
             "data" => %{"watermark" => 2, "headSeq" => 4}
           }

    # Live continues after the head; the client fetches 3..4 itself.
    assert feed.last_seq == 4
  end
end
