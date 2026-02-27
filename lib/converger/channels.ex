defmodule Converger.Channels do
  @moduledoc """
  The Channels context.
  """

  import Ecto.Query, warn: false
  alias Converger.Repo
  alias Converger.Channels.Channel

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

  def create_channel(attrs \\ %{}) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  def delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
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
      where: c.tenant_id == ^tenant_id and c.mode in ["inbound", "duplex"] and c.status == "active"
    )
    |> Repo.all()
  end

  def list_outbound_capable_channels(tenant_id) do
    from(c in Channel,
      where: c.tenant_id == ^tenant_id and c.mode in ["outbound", "duplex"] and c.status == "active"
    )
    |> Repo.all()
  end
end
