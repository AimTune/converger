defmodule Converger.Conversations do
  @moduledoc """
  The Conversations context.
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.Conversations.Conversation

  @doc """
  First page of conversations matching `filters`, newest first.

  Bounded by the configured page size; use `paginate_conversations/2` to get
  the cursor for further pages. Options: `:limit`, `:direction`, `:preload`.
  """
  def list_conversations(filters \\ %{}, opts \\ []) do
    {:ok, page} = paginate_conversations(filters, Keyword.delete(opts, :cursor))
    page.entries
  end

  def list_conversations_for_tenant(tenant_id, opts \\ []) do
    list_conversations(%{"tenant_id" => tenant_id}, opts)
  end

  @doc """
  Keyset-paginated conversations on `(inserted_at, id)`, newest first by default.

  Filters (string or atom keys, `""` ignored): `tenant_id`, `channel_id`,
  `status`, and `q` (a conversation id; anything that is not a UUID matches
  nothing). Options: `:limit`, `:cursor`, `:direction` (`:desc` | `:asc`),
  `:preload`. See `Converger.Pagination.keyset/2`.

  Returns `{:ok, %Converger.Pagination.Page{}}` or `{:error, :invalid_cursor}`.
  """
  def paginate_conversations(filters \\ %{}, opts \\ []) do
    Conversation
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(opts)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {key, value}, q when key in ["q", :q] and is_binary(value) and value != "" ->
        case Ecto.UUID.cast(String.trim(value)) do
          {:ok, id} -> where(q, id: ^id)
          :error -> where(q, [c], false)
        end

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
