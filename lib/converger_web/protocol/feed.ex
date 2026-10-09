defmodule ConvergerWeb.Protocol.Feed do
  @moduledoc """
  Ordered delivery of one conversation's persistent frames to one connection
  (docs/protocol/v1.md, section 6), shared by every v1 transport.

  The feed remembers the highest `seq` it has delivered (`last_seq`) and:

    * **replays** `seq > watermark` from the database in batches of
      `replayBatch`, at most `replayMax` frames, then reports truncation;
    * **de-duplicates** live frames: a frame with `seq <= last_seq` was
      already replayed or delivered and is dropped. The caller subscribes to
      the conversation topic *before* replaying, so frames committed during
      the replay are held back in the mailbox and dropped here;
    * **fills gaps**: PubSub is at-most-once across nodes, so a live frame
      with `seq > last_seq + 1` makes the feed read the missing range first;
    * applies the **echo rule** (section 6.4): turns sent on this connection
      (`own/2`) are never delivered back to it.
  """

  alias Converger.Activities
  alias ConvergerWeb.Protocol
  alias ConvergerWeb.Protocol.Frames

  defstruct [:conversation_id, :user_id, last_seq: 0, own: MapSet.new()]

  @type t :: %__MODULE__{}

  @doc "A feed for `conversation_id`, rendering frames for the end user `user_id`."
  def new(conversation_id, user_id) do
    %__MODULE__{conversation_id: conversation_id, user_id: user_id}
  end

  @doc """
  Replay every frame after `position` (`nil` for the whole conversation,
  `{:seq, n}` or a legacy `{:activity_id, id}`), bounded by `replayMax`.

  Returns `{frames, feed}`. When the bound is hit the last frame is
  `replayTruncated` and the client fetches the rest over REST or `sync`.
  Either way the feed continues live after `head_seq` (the conversation head
  read after subscribing), so a truncated remainder is not gap-filled.
  """
  def replay(%__MODULE__{} = feed, position, head_seq) do
    max = Protocol.config(:replay_max)
    batch = Converger.Pagination.config(:ws_replay_limit)
    {frames, feed} = do_replay(feed, position, head_seq, max, batch, [])
    {frames, seek(feed, head_seq)}
  end

  defp do_replay(feed, position, head_seq, remaining, batch, acc) do
    {activities, has_more} =
      Activities.page_activities_since(feed.conversation_id, position,
        limit: min(batch, remaining)
      )

    {frames, feed} = deliver(feed, activities, false)
    acc = [frames | acc]
    remaining = remaining - length(activities)

    case List.last(activities) do
      nil ->
        {finish(acc), feed}

      last when has_more and remaining > 0 ->
        do_replay(feed, {:seq, last.seq}, head_seq, remaining, batch, acc)

      last when has_more ->
        truncated = Frames.replay_truncated(last.seq, max(head_seq, last.seq))
        {finish([[truncated] | acc]), feed}

      _last ->
        {finish(acc), feed}
    end
  end

  defp finish(acc), do: acc |> Enum.reverse() |> List.flatten()

  @doc """
  A live activity (the canonical map of the `new_activity` broadcast).
  Returns the frames to push, in order: any gap first, then the activity.
  """
  def live(%__MODULE__{last_seq: last} = feed, %{seq: seq}) when is_integer(seq) and seq <= last,
    do: {[], feed}

  def live(%__MODULE__{last_seq: last} = feed, %{seq: seq} = canonical)
      when is_integer(seq) and seq == last + 1,
      do: deliver(feed, [canonical], true)

  def live(%__MODULE__{last_seq: last} = feed, %{seq: seq} = canonical) when is_integer(seq) do
    # The range (last, seq) is committed: seq is allocated under the
    # conversation row lock, so a committed seq implies all lower ones are.
    {missing, _has_more} =
      Activities.page_activities_since(feed.conversation_id, {:seq, last}, limit: seq - last - 1)

    {gap_frames, feed} = deliver(feed, missing, true)
    {frames, feed} = deliver(feed, [canonical], true)
    {gap_frames ++ frames, feed}
  end

  def live(feed, _canonical), do: {[], feed}

  @doc "Record a turn sent on this connection: it is never delivered back (echo rule)."
  def own(%__MODULE__{} = feed, seq) when is_integer(seq) do
    if seq <= feed.last_seq,
      do: feed,
      else: %{feed | own: MapSet.put(feed.own, seq)}
  end

  @doc "Advance the feed's position without delivering (used after an explicit seek)."
  def seek(%__MODULE__{} = feed, seq) when is_integer(seq) do
    %{feed | last_seq: max(feed.last_seq, seq), own: prune(feed.own, seq)}
  end

  defp deliver(feed, activities, live?) do
    {frames, feed} =
      Enum.reduce(activities, {[], feed}, fn activity, {frames, feed} ->
        seq = activity.seq
        advanced = %{feed | last_seq: max(feed.last_seq, seq)}

        if MapSet.member?(feed.own, seq) do
          {frames, %{advanced | own: MapSet.delete(feed.own, seq)}}
        else
          {[Frames.activity(activity, feed.user_id, live?) | frames], advanced}
        end
      end)

    {Enum.reverse(frames), feed}
  end

  defp prune(own, seq), do: own |> Enum.reject(&(&1 <= seq)) |> MapSet.new()
end
