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

  def list_channels do
    Channel
    |> Repo.all()
    |> Repo.preload(:tenant)
  end

  def list_channels_for_tenant(tenant_id) do
    from(c in Channel, where: c.tenant_id == ^tenant_id)
    |> Repo.all()
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

  def update_channel(%Channel{} = channel, attrs, actor \\ nil) do
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

  def delete_channel(%Channel{} = channel, actor \\ nil) do
    if actor do
      Multi.new()
      |> Multi.insert(:audit_log, fn _ ->
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
      |> Multi.delete(:channel, channel)
      |> Repo.transaction()
      |> case do
        {:ok, %{channel: channel}} -> {:ok, channel}
        {:error, :channel, changeset, _} -> {:error, changeset}
      end
    else
      Repo.delete(channel)
    end
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

  def validate_channel_secret(id, secret) do
    case Repo.get(Channel, id) do
      %Channel{secret: ^secret} = channel -> {:ok, channel}
      _ -> {:error, :unauthorized}
    end
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
