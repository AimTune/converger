defmodule Converger.Channels.Channel do
  use Ecto.Schema
  import Ecto.Changeset

  @channel_types ~w(echo webhook websocket whatsapp_meta whatsapp_infobip)
  @channel_modes ~w(inbound outbound duplex)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "channels" do
    field :name, :string
    field :type, :string, default: "webhook"
    field :mode, :string, default: "duplex"
    field :secret, :string
    field :status, :string, default: "active"
    field :config, :map, default: %{}
    field :transformations, {:array, :map}, default: []
    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def channel_types, do: @channel_types
  def channel_modes, do: @channel_modes

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :status, :tenant_id, :type, :mode, :secret, :config, :transformations])
    |> validate_required([:name, :status, :tenant_id])
    |> validate_inclusion(:type, @channel_types)
    |> validate_inclusion(:mode, @channel_modes)
    |> validate_channel_config()
    |> validate_mode_compatibility()
    |> validate_transformations()
    |> unique_constraint([:tenant_id, :name])
    |> ensure_secret()
  end

  defp validate_channel_config(changeset) do
    type = get_field(changeset, :type)
    config = get_field(changeset, :config) || %{}

    case Converger.Channels.Adapter.validate_config(type, config) do
      :ok -> changeset
      {:error, message} -> add_error(changeset, :config, message)
    end
  end

  defp validate_mode_compatibility(changeset) do
    type = get_field(changeset, :type)
    mode = get_field(changeset, :mode) || "duplex"

    supported = Converger.Channels.Adapter.supported_modes(type)

    if mode in supported do
      changeset
    else
      add_error(
        changeset,
        :mode,
        "#{type} channels only support modes: #{Enum.join(supported, ", ")}"
      )
    end
  end

  defp validate_transformations(changeset) do
    transformations = get_field(changeset, :transformations) || []

    if transformations == [] do
      changeset
    else
      case Converger.Pipeline.Middleware.validate_chain(transformations) do
        :ok -> changeset
        {:error, message} -> add_error(changeset, :transformations, message)
      end
    end
  end

  defp ensure_secret(changeset) do
    if get_field(changeset, :secret) do
      changeset
    else
      put_change(changeset, :secret, generate_secret())
    end
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
