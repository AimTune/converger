defmodule Converger.Conversations do
  @moduledoc """
  The Conversations context.
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.Conversations.Conversation

  def list_conversations(filters \\ %{}) do
    Conversation
    |> apply_filters(filters)
    |> Repo.all()
  end

  def list_conversations_for_tenant(tenant_id) do
    list_conversations(%{"tenant_id" => tenant_id})
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {"tenant_id", value}, q when value != "" -> where(q, tenant_id: ^value)
      {:tenant_id, value}, q when value != "" -> where(q, tenant_id: ^value)
      {"channel_id", value}, q when value != "" -> where(q, channel_id: ^value)
      {:channel_id, value}, q when value != "" -> where(q, channel_id: ^value)
      {"status", value}, q when value != "" -> where(q, status: ^value)
      {:status, value}, q when value != "" -> where(q, status: ^value)
      {_, _}, q -> q
    end)
  end

  def get_conversation(id), do: Repo.get(Conversation, id)

  def get_conversation!(id), do: Repo.get!(Conversation, id)

  def get_conversation!(id, tenant_id) do
    Repo.get_by!(Conversation, id: id, tenant_id: tenant_id)
  end

  def create_conversation(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  def close_conversation(%Conversation{} = conversation) do
    update_conversation(conversation, %{status: "closed"})
  end

  def delete_conversation(%Conversation{} = conversation) do
    Repo.delete(conversation)
  end

  def change_conversation(%Conversation{} = conversation, attrs \\ %{}) do
    Conversation.changeset(conversation, attrs)
  end
end
