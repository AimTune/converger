defmodule Converger.Receipts do
  @moduledoc """
  Read receipts of conversation participants.

  A participant marks every activity up to a `seq` as read (the WebSocket
  `read {watermark}` frame). The position is stored per
  `(conversation, reader)` in `conversation_reads` and never moves
  backwards: an older or equal watermark is a no-op, so receipts arriving
  out of order or from several tabs of one user are harmless.

  Delivery receipts of external providers (WhatsApp `delivered` / `read`)
  are tracked per delivery in `Converger.Deliveries`, not here.
  """

  import Ecto.Query, warn: false

  alias Converger.Conversations.Conversation
  alias Converger.Receipts.ReadPosition
  alias Converger.Repo

  @doc """
  Move `reader_id`'s read watermark in `conversation` forward to
  `watermark`, capped at the conversation's head `seq`.

  Returns `{:ok, :advanced, read_seq}` when the stored position moved,
  `{:ok, :unchanged, read_seq}` when it was already at or past the
  watermark (`read_seq` is the stored position, `0` when nothing has been
  read yet), or `{:error, :invalid_watermark}` for a watermark that is not a
  positive integer.
  """
  def mark_read(%Conversation{} = conversation, reader_id, watermark)
      when is_binary(reader_id) and is_integer(watermark) and watermark >= 1 do
    case min(watermark, head_seq(conversation.id)) do
      0 ->
        {:ok, :unchanged, 0}

      read_seq ->
        now = DateTime.utc_now()

        row = %{
          id: Ecto.UUID.generate(),
          tenant_id: conversation.tenant_id,
          conversation_id: conversation.id,
          reader_id: reader_id,
          read_seq: read_seq,
          read_at: now,
          inserted_at: now,
          updated_at: now
        }

        # ON CONFLICT ... DO UPDATE ... WHERE: the row is only touched when the
        # new watermark is ahead, which makes the update monotonic under
        # concurrency without a separate lock.
        on_conflict =
          from(r in ReadPosition,
            where: r.read_seq < ^read_seq,
            update: [set: [read_seq: ^read_seq, read_at: ^now, updated_at: ^now]]
          )

        case Repo.insert_all(ReadPosition, [row],
               on_conflict: on_conflict,
               conflict_target: [:conversation_id, :reader_id]
             ) do
          {1, _} -> {:ok, :advanced, read_seq}
          {0, _} -> {:ok, :unchanged, read_seq(conversation.id, reader_id)}
        end
    end
  end

  def mark_read(_conversation, _reader_id, _watermark), do: {:error, :invalid_watermark}

  @doc "The stored read watermark of `reader_id` in a conversation, `0` when none."
  def read_seq(conversation_id, reader_id) do
    from(r in ReadPosition,
      where: r.conversation_id == ^conversation_id and r.reader_id == ^reader_id,
      select: r.read_seq
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc "Every read position of a conversation."
  def list_read_positions(conversation_id) do
    from(r in ReadPosition,
      where: r.conversation_id == ^conversation_id,
      order_by: [asc: r.reader_id]
    )
    |> Repo.all()
  end

  # Read fresh: the conversation struct the caller holds may predate the
  # activities the reader has seen.
  defp head_seq(conversation_id) do
    from(c in Conversation, where: c.id == ^conversation_id, select: c.last_seq)
    |> Repo.one()
    |> Kernel.||(0)
  end
end
