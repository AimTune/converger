defmodule Converger.Activities do
  @moduledoc """
  The Activities context.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Converger.Repo
  alias Converger.Activities.Activity

  def list_activities_for_conversation(conversation_id) do
    from(a in Activity,
      where: a.conversation_id == ^conversation_id,
      order_by: [asc: a.inserted_at, asc: a.id]
    )
    |> Repo.all()
  end

  def list_activities_after(conversation_id, last_activity_id) do
    last_activity = Repo.get(Activity, last_activity_id)

    if last_activity do
      from(a in Activity,
        where:
          a.conversation_id == ^conversation_id and a.inserted_at > ^last_activity.inserted_at,
        order_by: [asc: a.inserted_at, asc: a.id]
      )
      |> Repo.all()
    else
      list_activities_for_conversation(conversation_id)
    end
  end

  def list_activities_after_watermark(conversation_id, watermark_activity_id) do
    case Repo.get(Activity, watermark_activity_id) do
      %Activity{inserted_at: ts, id: wid} ->
        from(a in Activity,
          where:
            a.conversation_id == ^conversation_id and
              (a.inserted_at > ^ts or (a.inserted_at == ^ts and a.id > ^wid)),
          order_by: [asc: a.inserted_at, asc: a.id]
        )
        |> Repo.all()

      nil ->
        list_activities_for_conversation(conversation_id)
    end
  end

  def get_activity!(id), do: Repo.get!(Activity, id)

  def create_activity(attrs \\ %{}) do
    # 1. Optimistic fetch to avoid transaction poisoning
    case fetch_existing_activity(attrs) do
      %Activity{} = activity ->
        {:ok, activity}

      nil ->
        # 2. Persist the activity and enqueue its deliveries in one transaction
        #    (transactional outbox): either both commit or neither does.
        result =
          Repo.transaction(fn ->
            with {:ok, activity} <- %Activity{} |> Activity.changeset(attrs) |> Repo.insert(),
                 :ok <- enqueue_deliveries(activity) do
              activity
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, activity} ->
            :telemetry.execute([:converger, :activities, :create], %{count: 1}, %{
              tenant_id: activity.tenant_id
            })

            # 3. Non-durable work (PubSub broadcast etc.) AFTER successful commit
            Converger.Pipeline.after_commit(activity)
            {:ok, activity}

          {:error, :delivery_enqueue_failed} ->
            {:error, :delivery_enqueue_failed}

          {:error, changeset} ->
            if has_idempotency_error?(changeset) do
              case fetch_existing_activity(attrs) do
                %Activity{} = activity -> {:ok, activity}
                nil -> {:error, changeset}
              end
            else
              {:error, changeset}
            end
        end
    end
  end

  defp enqueue_deliveries(activity) do
    case Converger.Pipeline.enqueue(activity) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Delivery enqueue failed, rolling back activity",
          conversation_id: activity.conversation_id,
          error: inspect(reason)
        )

        {:error, :delivery_enqueue_failed}
    end
  end

  defp has_idempotency_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {msg, _}} ->
      (field == :idempotency_key or field == :conversation_id) and msg == "has already been taken"
    end)
  end

  defp fetch_existing_activity(attrs) do
    conversation_id = attrs["conversation_id"] || attrs[:conversation_id]
    idempotency_key = attrs["idempotency_key"] || attrs[:idempotency_key]

    if conversation_id && idempotency_key do
      Repo.get_by(Activity, conversation_id: conversation_id, idempotency_key: idempotency_key)
    else
      nil
    end
  end

  def update_activity(%Activity{} = activity, attrs) do
    activity
    |> Activity.changeset(attrs)
    |> Repo.update()
  end

  def delete_activity(%Activity{} = activity) do
    Repo.delete(activity)
  end

  def change_activity(%Activity{} = activity, attrs \\ %{}) do
    Activity.changeset(activity, attrs)
  end
end
