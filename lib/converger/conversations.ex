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

  @doc """
  A tenant's conversations matching `filters` (`"channel_id"`, `"status"`,
  `"external_id"`), newest first, at most `limit`, with the participant
  preloaded. The tenant always comes from `tenant_id`, never from `filters`.
  """
  def search_conversations(tenant_id, filters, limit) do
    filters
    |> Map.drop(["tenant_id", :tenant_id])
    |> Map.put("tenant_id", tenant_id)
    |> then(&apply_filters(Conversation, &1))
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> preload(:participant)
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
      {"external_id", value}, q when is_binary(value) -> where_external_id(q, value)
      {:external_id, value}, q when is_binary(value) -> where_external_id(q, value)
      {_, _}, q -> q
    end)
  end

  # Conversations whose participant (on the conversation's channel) has this
  # external id, e.g. a WhatsApp phone number.
  defp where_external_id(query, external_id) do
    from(c in query,
      join: p in assoc(c, :participant),
      where: p.external_id == ^external_id and p.channel_id == c.channel_id
    )
  end

  def get_conversation(id), do: Repo.get(Conversation, id)

  def get_conversation(id, tenant_id) do
    Repo.get_by(Conversation, id: id, tenant_id: tenant_id)
  end

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
