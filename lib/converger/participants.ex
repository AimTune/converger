defmodule Converger.Participants do
  @moduledoc """
  External parties of a channel (`Converger.Participants.Participant`) and
  participant-based conversation resolution for inbound messages.

  Providers such as WhatsApp never send a Converger conversation id. An
  inbound message is attached to the participant's open conversation on the
  channel instead:

    1. the participant `(channel_id, external_id)` is upserted;
    2. its most recent conversation on the channel with status `"active"` is
       reused, unless it has been idle for longer than the channel's idle
       timeout (see `idle_timeout_seconds/1`);
    3. otherwise a new conversation is created for the participant.

  Only `"active"` conversations are ever reused: closed or expired
  conversations (see the conversation lifecycle) never receive new inbound
  activities, a new conversation is started instead.

  Resolution is concurrency-safe: the upsert (`INSERT ... ON CONFLICT DO
  UPDATE` on the unique `(channel_id, external_id)` index) locks the
  participant row until the transaction commits, so concurrent messages from
  the same participant resolve one at a time and share one conversation.
  """

  import Ecto.Query, warn: false

  alias Converger.Repo
  alias Converger.Activities.Activity
  alias Converger.Conversations.Conversation
  alias Converger.Participants.Participant

  def get_participant(id), do: Repo.get(Participant, id)

  def get_participant_by_external_id(channel_id, external_id) do
    Repo.get_by(Participant, channel_id: channel_id, external_id: external_id)
  end

  @doc """
  Insert the participant `(channel, attrs["external_id"])` or return the
  existing one. A non-nil `display_name` overwrites the stored one.
  """
  def upsert_participant(channel, attrs) do
    on_conflict =
      from(p in Participant,
        update: [
          set: [
            display_name: fragment("COALESCE(EXCLUDED.display_name, ?)", p.display_name),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    %Participant{tenant_id: channel.tenant_id, channel_id: channel.id}
    |> Participant.changeset(attrs)
    |> Repo.insert(
      on_conflict: on_conflict,
      conflict_target: [:channel_id, :external_id],
      returning: true
    )
  end

  @doc """
  Resolve the conversation for an inbound message from the participant
  described by `attrs` (`"external_id"`, optional `"display_name"`) on
  `channel`. Returns `{:ok, conversation}` or `{:error, reason}`.
  """
  def resolve_conversation(channel, attrs) do
    Repo.transaction(fn ->
      with {:ok, participant} <- upsert_participant(channel, attrs),
           {:ok, conversation} <- open_or_create_conversation(channel, participant) do
        conversation
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp open_or_create_conversation(channel, participant) do
    case open_conversation(channel, participant) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        %Conversation{participant_id: participant.id}
        |> Conversation.changeset(%{
          "tenant_id" => channel.tenant_id,
          "channel_id" => channel.id,
          "metadata" => %{"source" => "inbound_webhook"}
        })
        |> Repo.insert()
    end
  end

  defp open_conversation(channel, participant) do
    conversation =
      from(c in Conversation,
        where:
          c.participant_id == ^participant.id and c.channel_id == ^channel.id and
            c.status == "active",
        order_by: [desc: c.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case {conversation, idle_timeout_seconds(channel)} do
      {nil, _} -> nil
      {conversation, nil} -> conversation
      {conversation, timeout} -> if idle?(conversation, timeout), do: nil, else: conversation
    end
  end

  defp idle?(conversation, timeout_seconds) do
    last_activity_at =
      from(a in Activity,
        where: a.conversation_id == ^conversation.id,
        select: max(a.inserted_at)
      )
      |> Repo.one()

    last = last_activity_at || conversation.inserted_at
    DateTime.diff(DateTime.utc_now(), last, :second) > timeout_seconds
  end

  @doc """
  Seconds of inactivity after which an inbound message starts a new
  conversation instead of joining the participant's active one. Read from
  the channel config key `"conversation_idle_timeout_seconds"`, then
  `config :converger, :inbound_conversation_idle_timeout_seconds`. `nil`
  (the default) means no idle timeout: the active conversation is reused
  until it is closed or expired by the conversation lifecycle.
  """
  def idle_timeout_seconds(channel) do
    case (channel.config || %{})["conversation_idle_timeout_seconds"] do
      seconds when is_integer(seconds) and seconds > 0 ->
        seconds

      _ ->
        case Application.get_env(:converger, :inbound_conversation_idle_timeout_seconds) do
          seconds when is_integer(seconds) and seconds > 0 -> seconds
          _ -> nil
        end
    end
  end

  @doc """
  The `external_id` of the participant of the activity's conversation, when
  that participant belongs to `channel_id` (e.g. the phone number to reply
  to), or nil.
  """
  def recipient_for(%{conversation_id: conversation_id}, channel_id)
      when is_binary(conversation_id) and is_binary(channel_id) do
    from(c in Conversation,
      join: p in assoc(c, :participant),
      where: c.id == ^conversation_id and p.channel_id == ^channel_id,
      select: p.external_id
    )
    |> Repo.one()
  end

  def recipient_for(_activity, _channel_id), do: nil
end
