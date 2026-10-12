defmodule Converger.Webhooks do
  @moduledoc """
  Platform event webhooks (issue #49, ADR-0053).

  A tenant subscribes a URL to event types from `Converger.Webhooks.Catalog`
  (`Converger.Webhooks.Subscription`). The places where those things happen
  call `emit/3` (from the hooks that already broadcast them over PubSub),
  which writes one `Converger.Webhooks.Event` row per matching subscription
  and enqueues a `Converger.Workers.WebhookEventWorker` job for each, in one
  transaction.

  The worker POSTs the event, signed with the subscription secret using the
  outbound scheme of the webhook adapter (`x-converger-signature:
  t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`, ADR-0014), through
  the SSRF guard, and retries under the shared retry policy
  (`Converger.Pipeline.RetryPolicy.default/0`). An exhausted or permanently
  failing event is dead-lettered (`failed`) and can be redelivered
  (`redeliver/2`). Event rows are pruned after 7 days
  (`Converger.Retention.prune/1`).

  `emit/3` never raises: a failure to record an event is logged and must not
  break the operation that produced it.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Converger.AuditLogs
  alias Converger.AuditLogs.Changes
  alias Converger.Repo
  alias Converger.Webhooks.{Catalog, Event, Subscription}
  alias Converger.Workers.WebhookEventWorker
  alias Ecto.Multi

  @alert_managed_by "alert_webhook_url"
  @alert_events ["channel.health_changed", "channel.circuit_opened", "channel.circuit_closed"]

  # --- Subscriptions ---

  @doc "The tenant's subscriptions, oldest first."
  def list_subscriptions(tenant_id) do
    from(s in Subscription, where: s.tenant_id == ^tenant_id, order_by: [asc: s.inserted_at])
    |> Converger.Pagination.bounded_all()
  end

  @doc "Every subscription with its tenant (admin)."
  def list_all_subscriptions do
    from(s in Subscription, order_by: [asc: s.inserted_at])
    |> Converger.Pagination.bounded_all()
    |> Repo.preload(:tenant)
  end

  @doc "A subscription of the tenant; raises `Ecto.NoResultsError` otherwise."
  def get_subscription!(id, tenant_id),
    do: Repo.get_by!(Subscription, id: id, tenant_id: tenant_id)

  @doc "A subscription by id (admin)."
  def get_subscription!(id), do: Repo.get!(Subscription, id)

  @doc """
  Creates a subscription for `tenant_id`. Without a `secret` one is
  generated; read it from the returned struct (it is shown once by the API
  and the portal).
  """
  def create_subscription(tenant_id, attrs, actor \\ nil) do
    changeset = Subscription.changeset(%Subscription{tenant_id: tenant_id}, attrs)

    with_audit(changeset, actor, "create", fn multi ->
      Multi.insert(multi, :subscription, changeset)
    end)
  end

  @doc "Updates a subscription (url, description, secret, events, enabled, headers)."
  def update_subscription(%Subscription{} = subscription, attrs, actor \\ nil) do
    changeset = Subscription.changeset(subscription, attrs)

    with_audit(changeset, actor, "update", fn multi ->
      Multi.update(multi, :subscription, changeset)
    end)
  end

  @doc "Deletes a subscription and its event log."
  def delete_subscription(%Subscription{} = subscription, actor \\ nil) do
    with_audit(subscription, actor, "delete", fn multi ->
      Multi.delete(multi, :subscription, subscription)
    end)
  end

  @doc "A changeset for forms."
  def change_subscription(%Subscription{} = subscription, attrs \\ %{}),
    do: Subscription.changeset(subscription, attrs)

  defp with_audit(changeset_or_struct, nil, _action, fun) do
    Multi.new()
    |> fun.()
    |> Repo.transaction()
    |> unwrap_multi(changeset_or_struct)
  end

  defp with_audit(changeset_or_struct, actor, action, fun) do
    before = before_struct(changeset_or_struct)

    Multi.new()
    |> fun.()
    |> Multi.insert(:audit_log, fn %{subscription: subscription} ->
      AuditLogs.build_audit_log_entry(%{
        tenant_id: subscription.tenant_id,
        actor_type: actor.type,
        actor_id: to_string(actor.id),
        action: action,
        resource_type: "webhook_subscription",
        resource_id: subscription.id,
        changes: audit_changes(action, before, subscription)
      })
    end)
    |> Repo.transaction()
    |> unwrap_multi(changeset_or_struct)
  end

  defp unwrap_multi({:ok, %{subscription: subscription}}, _), do: {:ok, subscription}
  defp unwrap_multi({:error, :subscription, changeset, _}, _), do: {:error, changeset}

  defp before_struct(%Ecto.Changeset{data: data}), do: data
  defp before_struct(struct), do: struct

  defp audit_changes("create", _before, subscription),
    do: Changes.for_create(redact(subscription))

  defp audit_changes("delete", before, _subscription), do: Changes.for_delete(redact(before))

  defp audit_changes("update", before, subscription),
    do: Changes.for_update(redact(before), redact(subscription))

  # Header values may be credentials whatever their name.
  defp redact(%Subscription{headers: headers} = subscription) when is_map(headers),
    do: %{
      subscription
      | headers: Map.new(headers, fn {k, _} -> {k, Converger.Secrets.redacted()} end)
    }

  defp redact(subscription), do: subscription

  # --- Legacy tenants.alert_webhook_url ---

  @doc """
  Keeps the subscription managed by `tenants.alert_webhook_url` in line with
  the tenant: created on `channel.health_changed`, `channel.circuit_opened`
  and `channel.circuit_closed` when the URL is set, updated when it changes,
  deleted when it is cleared. Its requests keep the legacy alert body.
  """
  def sync_alert_subscription(%{id: tenant_id, alert_webhook_url: url}) do
    existing = Repo.get_by(Subscription, tenant_id: tenant_id, managed_by: @alert_managed_by)
    url = if is_binary(url), do: String.trim(url), else: ""

    case do_sync_alert_subscription(tenant_id, existing, url) do
      {:ok, _} = ok ->
        ok

      {:error, error} = failed ->
        Logger.warning("Could not sync the alert webhook subscription",
          tenant_id: tenant_id,
          error: inspect(error)
        )

        failed
    end
  end

  defp do_sync_alert_subscription(_tenant_id, nil, ""), do: {:ok, nil}
  defp do_sync_alert_subscription(_tenant_id, existing, ""), do: Repo.delete(existing)
  defp do_sync_alert_subscription(_tenant_id, %{url: url} = existing, url), do: {:ok, existing}

  defp do_sync_alert_subscription(tenant_id, nil, url) do
    %Subscription{tenant_id: tenant_id, managed_by: @alert_managed_by}
    |> Subscription.changeset(%{
      url: url,
      events: @alert_events,
      description: "Channel health alerts (tenants.alert_webhook_url)"
    })
    |> Repo.insert()
  end

  defp do_sync_alert_subscription(_tenant_id, existing, url),
    do: existing |> Subscription.changeset(%{url: url}) |> Repo.update()

  @doc "`managed_by` value of the subscription mirroring `tenants.alert_webhook_url`."
  def alert_managed_by, do: @alert_managed_by

  # --- Emitting ---

  @doc """
  Records an event of `type` for every enabled subscription of `tenant_id`
  that wants it and enqueues its delivery. `data` is any JSON-encodable
  map. Returns `:ok` whatever happens (errors are logged).
  """
  def emit(tenant_id, type, data) when is_binary(tenant_id) and is_map(data) do
    if enabled?() and Catalog.known?(type) do
      tenant_id
      |> subscriptions_for(type, data)
      |> enqueue(tenant_id, type, data)
    end

    :ok
  rescue
    error ->
      Logger.error("Failed to emit platform webhook event",
        tenant_id: tenant_id,
        event_type: type,
        error: Exception.message(error)
      )

      :ok
  end

  def emit(_tenant_id, _type, _data), do: :ok

  defp enabled? do
    :converger |> Application.get_env(:platform_webhooks, []) |> Keyword.get(:enabled, true)
  end

  defp subscriptions_for(tenant_id, type, data) do
    from(s in Subscription,
      where: s.tenant_id == ^tenant_id and s.enabled,
      where: ^type in s.events or "*" in s.events,
      select: {s.id, s.managed_by}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, managed_by} -> legacy_wants?(managed_by, type, data) end)
  end

  # The legacy alert URL never received a breaker re-opened by a failed probe.
  defp legacy_wants?(@alert_managed_by, "channel.circuit_" <> _, data),
    do: to_string(data_value(data, :reason)) != "probe_failed"

  defp legacy_wants?(_managed_by, _type, _data), do: true

  defp enqueue([], _tenant_id, _type, _data), do: :ok

  defp enqueue(subscriptions, tenant_id, type, data) do
    now = DateTime.utc_now()
    event_id = Ecto.UUID.generate()
    payload = data |> Jason.encode!() |> Jason.decode!()

    rows =
      for {subscription_id, _} <- subscriptions do
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          subscription_id: subscription_id,
          event_id: event_id,
          type: type,
          payload: payload,
          status: "pending",
          attempts: 0,
          inserted_at: now,
          updated_at: now
        }
      end

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.insert_all(Event, rows)
        Oban.insert_all(Enum.map(rows, &WebhookEventWorker.new(%{"webhook_event_id" => &1.id})))
      end)

    :telemetry.execute([:converger, :webhooks, :emitted], %{count: length(rows)}, %{
      tenant_id: tenant_id,
      type: type
    })

    :ok
  end

  defp data_value(data, key), do: Map.get(data, key, Map.get(data, to_string(key)))

  # --- Events ---

  @doc """
  Keyset page of events, newest first. `filters`: `tenant_id`,
  `subscription_id`, `status`, `type`. Options as `Converger.Pagination.keyset/2`.
  """
  def paginate_events(filters, opts \\ []) do
    filters
    |> Enum.reduce(Event, fn
      {_key, value}, query when value in [nil, ""] -> query
      {:tenant_id, value}, query -> where(query, [e], e.tenant_id == ^value)
      {:subscription_id, value}, query -> where(query, [e], e.subscription_id == ^value)
      {:status, value}, query -> where(query, [e], e.status == ^value)
      {:type, value}, query -> where(query, [e], e.type == ^value)
      _, query -> query
    end)
    |> Converger.Pagination.keyset(opts)
  end

  @doc "The most recent events (UI), newest first."
  def list_recent_events(filters, limit \\ 50) do
    case paginate_events(filters, limit: limit) do
      {:ok, page} -> page.entries
      {:error, _} -> []
    end
  end

  @doc "An event of the tenant; raises `Ecto.NoResultsError` otherwise."
  def get_event!(id, tenant_id), do: Repo.get_by!(Event, id: id, tenant_id: tenant_id)

  @doc "An event by id (admin)."
  def get_event!(id), do: Repo.get!(Event, id)

  @doc """
  Sends a dead-lettered (`failed`) event again: it goes back to `pending`
  with its attempts reset and a new delivery job. Returns
  `{:error, :not_failed}` for an event that is not dead-lettered.
  """
  def redeliver(%Event{id: id} = event, actor \\ nil) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      query = from(e in Event, where: e.id == ^id and e.status == "failed", select: e)

      case Repo.update_all(query,
             set: [status: "pending", attempts: 0, redelivered_at: now, updated_at: now]
           ) do
        {1, [updated]} ->
          audit_redeliver(event, actor)
          Oban.insert!(WebhookEventWorker.new(%{"webhook_event_id" => id}))
          updated

        {0, _} ->
          Repo.rollback(:not_failed)
      end
    end)
    |> case do
      {:ok, _} -> {:ok, Repo.get!(Event, id)}
      {:error, _} = error -> error
    end
  end

  defp audit_redeliver(_event, nil), do: :ok

  defp audit_redeliver(event, actor) do
    {:ok, _} =
      AuditLogs.create_audit_log(%{
        tenant_id: event.tenant_id,
        actor_type: actor.type,
        actor_id: to_string(actor.id),
        action: "redeliver",
        resource_type: "webhook_event",
        resource_id: event.id,
        changes: %{
          "before" => %{"status" => event.status, "attempts" => event.attempts},
          "after" => %{"status" => "pending", "attempts" => 0}
        }
      })

    :ok
  end

  # --- Delivery (used by WebhookEventWorker) ---

  @doc "Marks an event delivered."
  def mark_delivered(%Event{} = event, response_status) do
    update_event(event, %{
      status: "delivered",
      attempts: event.attempts + 1,
      response_status: response_status,
      last_error: nil,
      delivered_at: DateTime.utc_now()
    })
  end

  @doc "Records a failed attempt; `dead?` dead-letters the event (`failed`)."
  def mark_attempt_failed(%Event{} = event, error_message, response_status, dead?) do
    update_event(event, %{
      status: if(dead?, do: "failed", else: "pending"),
      attempts: event.attempts + 1,
      response_status: response_status,
      last_error: error_message
    })
  end

  @doc "Dead-letters an event without an attempt (e.g. its subscription is disabled)."
  def mark_dead(%Event{} = event, error_message) do
    update_event(event, %{status: "failed", last_error: error_message})
  end

  defp update_event(event, attrs) do
    {1, _} =
      from(e in Event, where: e.id == ^event.id)
      |> Repo.update_all(set: Keyword.new(Map.put(attrs, :updated_at, DateTime.utc_now())))

    {:ok, struct(event, attrs)}
  end
end
