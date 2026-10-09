defmodule Converger.Channels do
  @moduledoc """
  The Channels context.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Converger.Repo
  alias Converger.Channels.Channel
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

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel!(id, tenant_id) do
    Repo.get_by!(Channel, id: id, tenant_id: tenant_id)
  end

  def create_channel(attrs \\ %{}, actor \\ nil) do
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

    with {:ok, %Channel{status: status} = updated} when status != "active" <- result do
      ConvergerWeb.Sockets.disconnect_channel(updated.id)
    end

    result
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

    result
  end

  # The channel's conversations cascade with the row. Their activities, and
  # deliveries to this channel, are in partitioned tables without foreign keys
  # (ADR-0026) and are purged in batches by PurgeWorker jobs enqueued in the
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
end
