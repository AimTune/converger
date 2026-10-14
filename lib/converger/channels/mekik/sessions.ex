defmodule Converger.Channels.Mekik.Sessions do
  @moduledoc """
  Persistence of the upstream mekik conversations of the `mekik` channel
  adapter (`mekik_sessions`, ADR-0066).

  A mekik/1 server mints its own `conversationId` on a first connect and
  adopts an asserted one only when it exists and belongs to the connecting
  `userId` (mekik/1 section 1). The adapter records the pair the server
  returned in `welcome`, so a restarted connection resumes the same mekik
  conversation, with its parked interrupts, and asks for the frames it
  missed with the recorded `watermark`.
  """

  import Ecto.Query

  alias Converger.Channels.Mekik.Session
  alias Converger.Repo

  @doc "The session of `channel_id` in `conversation_id`, or nil."
  @spec get(String.t(), String.t()) :: Session.t() | nil
  def get(channel_id, conversation_id),
    do: Repo.get_by(Session, channel_id: channel_id, conversation_id: conversation_id)

  @doc """
  Record the mekik conversation the server returned in `welcome`. A changed
  mekik conversation resets the watermark to `watermark` (usually 0).
  """
  @spec put(map(), String.t(), String.t(), non_neg_integer()) :: :ok
  def put(
        %{channel_id: _, conversation_id: _, tenant_id: _} = key,
        mekik_conv,
        mekik_user,
        watermark
      ) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Session,
      [
        %{
          id: Ecto.UUID.generate(),
          channel_id: key.channel_id,
          conversation_id: key.conversation_id,
          tenant_id: key.tenant_id,
          mekik_conversation_id: mekik_conv,
          mekik_user_id: mekik_user,
          watermark: watermark,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict:
        from(s in Session,
          update: [
            set: [
              mekik_conversation_id: ^mekik_conv,
              mekik_user_id: ^mekik_user,
              watermark: ^watermark,
              updated_at: ^now
            ]
          ]
        ),
      conflict_target: [:channel_id, :conversation_id]
    )

    :ok
  end

  @doc """
  Advance the stored watermark of a session (never backwards, and only for
  the same mekik conversation).
  """
  @spec advance(String.t(), String.t(), String.t(), non_neg_integer()) :: :ok
  def advance(channel_id, conversation_id, mekik_conv, watermark) do
    from(s in Session,
      where:
        s.channel_id == ^channel_id and s.conversation_id == ^conversation_id and
          s.mekik_conversation_id == ^mekik_conv and s.watermark < ^watermark
    )
    |> Repo.update_all(set: [watermark: watermark, updated_at: DateTime.utc_now()])

    :ok
  end
end
