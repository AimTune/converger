defmodule ConvergerWeb.ConversationJSON do
  alias Converger.Conversations.Conversation
  alias Converger.Participants.Participant

  @doc """
  Renders a list of conversations.
  """
  def index(%{conversations: conversations} = assigns) do
    body = %{data: for(conversation <- conversations, do: data(conversation))}

    case assigns do
      %{meta: %{} = meta} -> Map.put(body, :meta, meta)
      _ -> body
    end
  end

  @doc """
  Renders a single conversation.
  """
  def show(%{conversation: conversation}) do
    %{data: data(conversation)}
  end

  defp data(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      status: conversation.status,
      metadata: conversation.metadata,
      channel_id: conversation.channel_id,
      origin_channel_id: Conversation.origin_channel_id(conversation),
      tenant_id: conversation.tenant_id,
      participant_id: conversation.participant_id,
      participant: participant(conversation.participant),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
    |> put_channels(conversation.conversation_channels)
  end

  # Only `show` preloads the channels a conversation spans (ADR-0046).
  defp put_channels(data, channels) when is_list(channels) do
    Map.put(
      data,
      :channels,
      Enum.map(channels, fn cc ->
        %{
          channel_id: cc.channel_id,
          role: cc.role,
          participant_id: cc.participant_id,
          inserted_at: cc.inserted_at
        }
      end)
    )
  end

  defp put_channels(data, _not_loaded), do: data

  defp participant(%Participant{} = participant) do
    %{
      id: participant.id,
      external_id: participant.external_id,
      display_name: participant.display_name,
      opted_out_at: participant.opted_out_at
    }
  end

  defp participant(_not_loaded_or_nil), do: nil
end
