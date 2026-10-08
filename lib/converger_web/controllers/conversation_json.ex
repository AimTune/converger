defmodule ConvergerWeb.ConversationJSON do
  alias Converger.Conversations.Conversation
  alias Converger.Participants.Participant

  @doc """
  Renders a list of conversations.
  """
  def index(%{conversations: conversations}) do
    %{data: for(conversation <- conversations, do: data(conversation))}
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
      tenant_id: conversation.tenant_id,
      participant_id: conversation.participant_id,
      participant: participant(conversation.participant),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  defp participant(%Participant{} = participant) do
    %{
      id: participant.id,
      external_id: participant.external_id,
      display_name: participant.display_name
    }
  end

  defp participant(_not_loaded_or_nil), do: nil
end
