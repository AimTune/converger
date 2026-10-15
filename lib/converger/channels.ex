defmodule Converger.Channels do
  @moduledoc """
  The Channels context.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Converger.Repo
  alias Converger.Channels.{Adapter, Channel, Circuit, PublishableOrigins}
  alias Converger.AuditLogs
  alias Converger.AuditLogs.Changes

  # Channels are operator-managed configuration: listed whole (for tables and
  # dropdowns) under a hard safety cap, see Converger.Pagination.bounded_all/2.
  def list_channels do
    from(c in Channel, order_by: [asc: c.name, asc: c.id])
    |> Converger.Pagination.bounded_all()
    |> Repo.preload(:tenant)
  end

  def list_channels_for_tenant(tenant_id) do
    from(c in Channel, where: c.tenant_id == ^tenant_id, order_by: [asc: c.name, asc: c.id])
    |> Converger.Pagination.bounded_all()
  end

  @doc """
  Keyset-paginated channels on `(inserted_at, id)`, newest first by default
  (the admin and portal channel lists).

  Filters (string or atom keys, `""` and `nil` ignored): `tenant_id`, `mode`,
  `status`, `type`, and `q` (a case-insensitive "contains" search on the
  name or the type, see `Converger.Pagination.contains/1`). An invalid
  `tenant_id` matches nothing. Options: `:limit`, `:cursor`, `:direction`
  (`:desc` | `:asc`), `:preload` (see `Converger.Pagination.keyset/2`).

  Returns `{:ok, %Converger.Pagination.Page{}}` or `{:error, :invalid_cursor}`.
  """
  def paginate_channels(filters \\ %{}, opts \\ []) do
    Channel
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(opts)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {key, value}, q ->
      apply_filter(q, to_string(key), value)
    end)
  end

  defp apply_filter(q, _key, value) when value in [nil, ""], do: q

  defp apply_filter(q, "q", value) when is_binary(value) do
    case Converger.Pagination.contains(value) do
      nil -> q
      pattern -> where(q, [c], ilike(c.name, ^pattern) or ilike(c.type, ^pattern))
    end
  end

  defp apply_filter(q, "tenant_id", value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> where(q, tenant_id: ^id)
      :error -> where(q, [c], false)
    end
  end

  defp apply_filter(q, "mode", value) when is_binary(value), do: where(q, mode: ^value)
  defp apply_filter(q, "status", value) when is_binary(value), do: where(q, status: ^value)
  defp apply_filter(q, "type", value) when is_binary(value), do: where(q, type: ^value)

  defp apply_filter(q, _key, _value), do: q

  def get_channel!(id), do: Repo.get!(Channel, id)

  @doc "The channel with `id` in tenant `tenant_id`, or nil (also for a malformed id)."
  def get_channel(id, tenant_id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Channel, id: uuid, tenant_id: tenant_id)
      :error -> nil
    end
  end

  def get_channel!(id, tenant_id) do
    Repo.get_by!(Channel, id: id, tenant_id: tenant_id)
  end

  def create_channel(attrs \\ %{}, actor \\ nil) do
    attrs
    |> do_create_channel(actor)
    |> notify_consumers()
  end

  defp do_create_channel(attrs, actor) do
    changeset = Channel.changeset(%Channel{}, attrs)

    if actor do
      Multi.new()
      |> Multi.insert(:channel, changeset)
      |> Multi.insert(:audit_log, fn %{channel: channel} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: channel.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "create",
          resource_type: "channel",
          resource_id: channel.id,
          changes: Changes.for_create(channel)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{channel: channel}} -> {:ok, channel}
        {:error, :channel, changeset, _} -> {:error, changeset}
      end
    else
      Repo.insert(changeset)
    end
  end

  @doc """
  Update a channel. When the channel stops being active, its connected client
  sockets are disconnected (and cannot reconnect while it stays inactive).
  """
  def update_channel(%Channel{} = channel, attrs, actor \\ nil) do
    result = do_update_channel(channel, attrs, actor)
    Converger.Channels.Templates.invalidate(channel.id)

    with {:ok, %Channel{status: status} = updated} when status != "active" <- result do
      ConvergerWeb.Sockets.disconnect_channel(updated.id)
    end

    notify_consumers(result)
  end

  defp do_update_channel(channel, attrs, actor) do
    changeset = Channel.changeset(channel, attrs)

    if actor do
      Multi.new()
      |> Multi.update(:channel, changeset)
      |> Multi.insert(:audit_log, fn %{channel: updated} ->
        AuditLogs.build_audit_log_entry(%{
          tenant_id: channel.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "update",
          resource_type: "channel",
          resource_id: channel.id,
          changes: Changes.for_update(channel, updated)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{channel: updated}} -> {:ok, updated}
        {:error, :channel, changeset, _} -> {:error, changeset}
      end
    else
      Repo.update(changeset)
    end
  end

  @doc "Delete a channel and disconnect its client sockets."
  def delete_channel(%Channel{} = channel, actor \\ nil) do
    result = do_delete_channel(channel, actor)

    with {:ok, deleted} <- result do
      ConvergerWeb.Sockets.disconnect_channel(deleted.id)
    end

    notify_consumers(result)
  end

  # The channel's conversations cascade with the row. Their activities, and
  # deliveries to this channel, are in partitioned tables without foreign keys
  # (ADR-0034) and are purged in batches by PurgeWorker jobs enqueued in the
  # same transaction (the conversation ids are captured before the cascade).
  defp do_delete_channel(channel, actor) do
    alias Converger.Workers.PurgeWorker

    Multi.new()
    |> maybe_audit_delete(channel, actor)
    |> Multi.run(:conversation_ids, fn repo, _ ->
      {:ok,
       repo.all(
         from(c in Converger.Conversations.Conversation,
           where: c.channel_id == ^channel.id,
           select: c.id
         )
       )}
    end)
    |> Oban.insert_all(:purge_conversations, fn %{conversation_ids: ids} ->
      PurgeWorker.conversation_jobs(ids)
    end)
    |> Oban.insert(:purge_deliveries, PurgeWorker.new(%{channel_id: channel.id}))
    |> Multi.delete(:channel, channel)
    |> Repo.transaction()
    |> case do
      {:ok, %{channel: channel}} -> {:ok, channel}
      {:error, :channel, changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp maybe_audit_delete(multi, _channel, nil), do: multi

  defp maybe_audit_delete(multi, channel, actor) do
    Multi.insert(multi, :audit_log, fn _ ->
      AuditLogs.build_audit_log_entry(%{
        tenant_id: channel.tenant_id,
        actor_type: actor.type,
        actor_id: actor.id,
        action: "delete",
        resource_type: "channel",
        resource_id: channel.id,
        changes: Changes.for_delete(channel)
      })
    end)
  end

  @doc """
  Pause deliveries to a channel: new and pending deliveries are parked
  (`status: "paused"`) until `resume_deliveries/2`. See `Converger.Channels.Circuit`.
  """
  def pause_deliveries(%Channel{} = channel, actor \\ nil) do
    {:ok, updated} = Circuit.pause(channel)
    audit_circuit(channel, updated, "pause_deliveries", actor)
    {:ok, updated}
  end

  @doc """
  Resume deliveries to a paused channel (or force-close an open circuit
  breaker) and release its parked deliveries.
  """
  def resume_deliveries(%Channel{} = channel, actor \\ nil) do
    {:ok, updated} = Circuit.resume(channel)
    audit_circuit(channel, updated, "resume_deliveries", actor)
    {:ok, updated}
  end

  @doc """
  Replace the channel's secret with a freshly generated one (like the one
  generated on insert). The old secret stops working at once: inbound
  signatures and secret-authenticated requests must use the new one.

  The rotation is audit-logged (action `rotate_secret`, secret values
  redacted, with `"rotated" => ["secret"]`) when an actor is given. Returns
  `{:ok, channel}` with the new plaintext `secret` (show it once) or
  `{:error, changeset}`.
  """
  def rotate_secret(%Channel{} = channel, actor \\ nil) do
    changeset = Channel.rotate_secret_changeset(channel)

    result =
      if actor do
        Multi.new()
        |> Multi.update(:channel, changeset)
        |> Multi.insert(:audit_log, fn %{channel: updated} ->
          AuditLogs.build_audit_log_entry(%{
            tenant_id: channel.tenant_id,
            actor_type: actor.type,
            actor_id: actor.id,
            action: "rotate_secret",
            resource_type: "channel",
            resource_id: channel.id,
            changes:
              channel
              |> Changes.for_update(updated)
              |> Map.put("rotated", ["secret"])
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{channel: updated}} -> {:ok, updated}
          {:error, :channel, changeset, _} -> {:error, changeset}
        end
      else
        Repo.update(changeset)
      end

    notify_consumers(result)
  end

  @doc """
  Updates the channel's publishable key settings (issue #195, ADR-0074):
  `attrs` may carry `"allowed_origins"`; `key` is `:keep`, `:new` (enable or
  rotate: the old key stops working at once) or `:none` (disable). See
  `Channel.client_access_changeset/3`.

  Audited when an actor is given (action `enable_publishable_key`,
  `rotate_publishable_key`, `disable_publishable_key` or
  `update_allowed_origins`; keys are masked). The origins CORS allows for
  the client API are refreshed on this node at once and on the others
  within `Converger.Channels.PublishableOrigins`' TTL.
  """
  def update_client_access(%Channel{} = channel, attrs, key \\ :keep, actor \\ nil) do
    changeset = Channel.client_access_changeset(channel, attrs, key)

    result =
      if actor do
        Multi.new()
        |> Multi.update(:channel, changeset)
        |> Multi.insert(:audit_log, fn %{channel: updated} ->
          AuditLogs.build_audit_log_entry(%{
            tenant_id: channel.tenant_id,
            actor_type: actor.type,
            actor_id: actor.id,
            action: client_access_action(channel, key),
            resource_type: "channel",
            resource_id: channel.id,
            changes: %{
              "before" => client_access_summary(channel),
              "after" => client_access_summary(updated)
            }
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{channel: updated}} -> {:ok, updated}
          {:error, :channel, changeset, _} -> {:error, changeset}
        end
      else
        Repo.update(changeset)
      end

    with {:ok, _} <- result, do: PublishableOrigins.invalidate()
    result
  end

  defp client_access_action(%Channel{publishable_key: nil}, :new), do: "enable_publishable_key"
  defp client_access_action(_channel, :new), do: "rotate_publishable_key"
  defp client_access_action(_channel, :none), do: "disable_publishable_key"
  defp client_access_action(_channel, :keep), do: "update_allowed_origins"

  defp client_access_summary(channel) do
    %{
      "publishable_key" =>
        channel.publishable_key && Converger.Secrets.mask(channel.publishable_key),
      "allowed_origins" => channel.allowed_origins
    }
  end

  @doc """
  The active channel with publishable key `key`, or nil. The key is public
  (it ships in page source), so a plain indexed lookup is enough.
  """
  def get_channel_by_publishable_key(key) when is_binary(key) and key != "" do
    if String.starts_with?(key, Channel.publishable_key_prefix()) do
      Repo.one(from c in Channel, where: c.publishable_key == ^key and c.status == "active")
    end
  end

  def get_channel_by_publishable_key(_key), do: nil

  @doc """
  Mints a client token for trying `channel` from a chat client (the channel
  page's Test token action, issue #194): an unscoped Converger token for end
  user `user_id`, exactly like `POST /api/v1/converger/tokens/generate` with
  the channel secret, so the operator never handles the secret.

  Only for active channels. Audited when an actor is given (action
  `test_token`, the user id and the token's `jti`; never the token).
  Returns `{:ok, token, claims}` or `{:error, :inactive}`.
  """
  def issue_test_token(%Channel{} = channel, user_id, actor \\ nil) do
    if channel.status == "active" do
      user_id = if is_binary(user_id), do: String.trim(user_id), else: nil
      user_id = if user_id in [nil, ""], do: nil, else: String.slice(user_id, 0, 128)

      {:ok, token, claims} =
        Converger.Auth.ConvergerToken.generate_token(channel, user_id: user_id)

      if actor do
        AuditLogs.create_audit_log(%{
          tenant_id: channel.tenant_id,
          actor_type: actor.type,
          actor_id: actor.id,
          action: "test_token",
          resource_type: "channel",
          resource_id: channel.id,
          changes: %{"after" => %{"user_id" => user_id, "jti" => claims["jti"]}}
        })
      end

      {:ok, token, claims}
    else
      {:error, :inactive}
    end
  end

  @doc """
  Send a test message to `channel` through the normal pipeline, see
  `Converger.Channels.TestMessage.send_test_message/3`.
  """
  defdelegate send_test_message(channel, text, actor \\ nil),
    to: Converger.Channels.TestMessage

  @doc """
  Point the provider's webhook at `inbound_url` with the channel's adapter
  (`c:Converger.Channels.Adapter.register_webhook/2`, e.g. Telegram's
  `setWebhook`). Audited when an actor is given. Returns `:ok`,
  `{:error, reason}` or `:unsupported`.
  """
  def register_webhook(%Channel{} = channel, inbound_url, actor \\ nil) do
    result = Adapter.register_webhook(channel, inbound_url)

    if result == :ok and actor do
      AuditLogs.create_audit_log(%{
        tenant_id: channel.tenant_id,
        actor_type: actor.type,
        actor_id: actor.id,
        action: "register_webhook",
        resource_type: "channel",
        resource_id: channel.id,
        changes: %{"after" => %{"webhook_url" => inbound_url}}
      })
    end

    result
  end

  defp audit_circuit(_before, _updated, _action, nil), do: :ok

  defp audit_circuit(before, updated, action, actor) do
    AuditLogs.create_audit_log(%{
      tenant_id: before.tenant_id,
      actor_type: actor.type,
      actor_id: actor.id,
      action: action,
      resource_type: "channel",
      resource_id: before.id,
      changes: %{
        "before" => %{"circuit_state" => before.circuit_state},
        "after" => %{"circuit_state" => updated.circuit_state}
      }
    })
  end

  def change_channel(%Channel{} = channel, attrs \\ %{}) do
    Channel.changeset(channel, attrs)
  end

  def get_active_channel(id) do
    case Repo.get(Channel, id) do
      %Channel{status: "active"} = channel -> {:ok, channel}
      %Channel{} -> {:error, :channel_inactive}
      nil -> {:error, :not_found}
    end
  end

  def get_active_channel(id, tenant_id) do
    case Repo.get_by(Channel, id: id, tenant_id: tenant_id) do
      %Channel{status: "active"} = channel -> {:ok, channel}
      %Channel{} -> {:error, :channel_inactive}
      nil -> {:error, :not_found}
    end
  end

  def validate_channel_secret(id, secret) when is_binary(secret) do
    case Repo.get(Channel, id) do
      %Channel{secret: stored} = channel when is_binary(stored) ->
        if Plug.Crypto.secure_compare(stored, secret),
          do: {:ok, channel},
          else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  def validate_channel_secret(_id, _secret), do: {:error, :unauthorized}

  @doc """
  Finds a channel by its secret. The lookup uses the secret's SHA-256 digest
  and the decrypted secret is then compared in constant time.
  """
  def get_channel_by_secret(secret) when is_binary(secret) and secret != "" do
    with %Channel{secret: stored} = channel when is_binary(stored) <-
           Repo.get_by(Channel, secret_hash: Converger.Secrets.hash(secret)),
         true <- Plug.Crypto.secure_compare(stored, secret) do
      channel
    else
      _ -> nil
    end
  end

  def get_channel_by_secret(_secret), do: nil

  @doc """
  Re-encrypts every channel's encrypted fields with the vault's current
  default key. Run after rotating `CLOAK_KEY`.
  """
  def reencrypt_all do
    Channel
    |> Repo.all()
    |> Enum.reduce(0, fn channel, count ->
      channel
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:secret, channel.secret)
      |> Ecto.Changeset.force_change(:config, channel.config)
      |> Repo.update!()

      count + 1
    end)
  end

  def list_channels_by_mode(mode) when mode in ~w(inbound outbound duplex) do
    from(c in Channel, where: c.mode == ^mode)
    |> Repo.all()
    |> Repo.preload(:tenant)
  end

  def list_inbound_capable_channels(tenant_id) do
    from(c in Channel,
      where:
        c.tenant_id == ^tenant_id and c.mode in ["inbound", "duplex"] and c.status == "active"
    )
    |> Repo.all()
  end

  def list_outbound_capable_channels(tenant_id) do
    from(c in Channel,
      where:
        c.tenant_id == ^tenant_id and c.mode in ["outbound", "duplex"] and c.status == "active"
    )
    |> Repo.all()
  end

  @doc """
  Every channel that needs a consumer, across tenants: active, `inbound`
  or `duplex`, of a type with the `:consumer` capability, and accepted by
  `Converger.Channels.Broker.consumes?/1` (a Discord channel only in
  Gateway mode). See `Converger.Channels.Consumers`.
  """
  def list_consumer_channels do
    case Adapter.types_with(:consumer) do
      [] ->
        []

      types ->
        from(c in Channel,
          where: c.type in ^types and c.mode in ["inbound", "duplex"] and c.status == "active",
          order_by: [asc: c.id]
        )
        # Complete on purpose (no bounded_all cap): a channel missing from
        # the list would have its consumer stopped.
        |> Repo.all()
        |> Enum.filter(&Converger.Channels.Broker.consumes?/1)
    end
  end

  @doc "The channel with `id`, or nil."
  def get_channel(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Channel, uuid)
      :error -> nil
    end
  end

  # Broker channels consume through Converger.Channels.Consumers: every node's
  # consumer manager reconciles the channel after a change.
  defp notify_consumers({:ok, %Channel{id: id}} = result) do
    Converger.Channels.Consumers.notify_changed(id)
    # A channel disabled or deleted no longer contributes CORS origins.
    PublishableOrigins.invalidate()
    result
  end

  defp notify_consumers(result), do: result
end
