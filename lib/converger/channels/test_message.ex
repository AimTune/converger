defmodule Converger.Channels.TestMessage do
  @moduledoc """
  "Send test message" from the admin panel and the tenant portal.

  A test message is a plain text `message` activity posted, through the
  normal pipeline (`Converger.Activities.create_activity/2`), into a
  dedicated conversation that started on the channel: an open conversation
  of the channel whose metadata has `"converger_test" => true`, created on
  first use and reused afterwards (a new one when it was closed).

  The activity has no `source_channel_id`, so the pipeline routes it as
  inbound to the conversation's origin channel (`Converger.Pipeline.plan/2`):
  the channel itself gets a delivery like any other outbound message, plus
  the targets of routing rules of the channel that match it. The channel
  must be able to send: its mode is `outbound` or `duplex` and its adapter
  has the `:outbound` capability. A channel whose provider needs a
  recipient (WhatsApp, Telegram, SMS, ...) records a failed delivery, since
  the test conversation has no participant.

  The delivery result is reported on the conversation topic
  (`"conversation:<id>"`, event `"delivery_status"`) like every delivery.
  """

  import Ecto.Query, warn: false

  alias Converger.Activities
  alias Converger.AuditLogs
  alias Converger.Channels.{Adapter, Channel}
  alias Converger.Conversations
  alias Converger.Conversations.Conversation
  alias Converger.Deliveries
  alias Converger.Repo

  @max_text_length 1000
  @sender "bot"
  @metadata_key "converger_test"

  @doc "The sender of test message activities."
  def sender, do: @sender

  @doc "Maximum length (characters) of a test message."
  def max_text_length, do: @max_text_length

  @doc """
  Whether test messages can be sent to `channel`: `:ok` or
  `{:error, reason}` with `reason` one of `:inbound_only`,
  `:not_deliverable` (the adapter cannot send) and `:channel_inactive`.
  """
  def check_sendable(%Channel{} = channel) do
    cond do
      channel.mode not in ["outbound", "duplex"] -> {:error, :inbound_only}
      not Adapter.capability?(channel.type, :outbound) -> {:error, :not_deliverable}
      channel.status != "active" -> {:error, :channel_inactive}
      true -> :ok
    end
  end

  @doc "A human-readable explanation of a `check_sendable/1` or `send_test_message/3` error."
  def error_message(:inbound_only),
    do: "Inbound-only channels receive messages and cannot send a test message."

  def error_message(:not_deliverable), do: "This channel type cannot send outbound messages."
  def error_message(:channel_inactive), do: "Enable the channel to send a test message."
  def error_message(:blank_text), do: "Enter the text of the test message."

  def error_message(:text_too_long),
    do: "The test message can be at most #{@max_text_length} characters."

  def error_message(:conversation_closed), do: "The test conversation was closed; try again."
  def error_message(:delivery_enqueue_failed), do: "The delivery could not be enqueued."
  def error_message(%Ecto.Changeset{}), do: "The test message was rejected."
  def error_message(other), do: "Failed to send the test message: #{inspect(other)}"

  @doc """
  Post `text` as a test message to `channel` (see the moduledoc), and
  audit-log it when an `actor` (`%{type: _, id: _}`) is given.

  Returns `{:ok, %{conversation: conversation, activity: activity,
  delivery: delivery | nil}}` (the delivery to this channel when it exists
  already: with the inline pipeline it is final, with Oban it may still be
  queued) or `{:error, reason}` (see `error_message/1`).
  """
  def send_test_message(%Channel{} = channel, text, actor \\ nil) do
    with :ok <- check_sendable(channel),
         {:ok, text} <- validate_text(text),
         {:ok, conversation} <- test_conversation(channel),
         {:ok, activity} <- create_activity(channel, conversation, text, actor) do
      audit(channel, conversation, activity, actor)

      {:ok,
       %{
         conversation: conversation,
         activity: activity,
         delivery: Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
       }}
    end
  end

  defp validate_text(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, :blank_text}
      String.length(text) > @max_text_length -> {:error, :text_too_long}
      true -> {:ok, text}
    end
  end

  defp validate_text(_text), do: {:error, :blank_text}

  @doc "The open test conversation of `channel`, created when there is none."
  def test_conversation(%Channel{} = channel) do
    existing =
      from(c in Conversation,
        where:
          c.channel_id == ^channel.id and c.status == ^Conversations.open_status() and
            fragment("(?->>?) = 'true'", c.metadata, ^@metadata_key),
        order_by: [desc: c.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case existing do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        Conversations.create_conversation(%{
          tenant_id: channel.tenant_id,
          channel_id: channel.id,
          status: Conversations.open_status(),
          metadata: %{@metadata_key => true}
        })
    end
  end

  defp create_activity(channel, conversation, text, actor) do
    Activities.create_activity(%{
      "tenant_id" => channel.tenant_id,
      "conversation_id" => conversation.id,
      "type" => "message",
      "sender" => @sender,
      "text" => text,
      "metadata" => %{@metadata_key => true, "requested_by" => actor_label(actor)},
      "idempotency_key" => "test-message:#{Ecto.UUID.generate()}"
    })
  end

  defp actor_label(nil), do: nil
  defp actor_label(%{type: type, id: id}), do: "#{type}:#{id}"

  # Audited as `send_test_message` on the channel, with the activity in `changes`.
  defp audit(_channel, _conversation, _activity, nil), do: :ok

  defp audit(channel, conversation, activity, actor) do
    AuditLogs.create_audit_log(%{
      tenant_id: channel.tenant_id,
      actor_type: actor.type,
      actor_id: actor.id,
      action: "send_test_message",
      resource_type: "channel",
      resource_id: channel.id,
      changes: %{
        "before" => nil,
        "after" => %{
          "test_message" => %{
            "activity_id" => activity.id,
            "conversation_id" => conversation.id,
            "text" => activity.text
          }
        }
      }
    })
  end
end
