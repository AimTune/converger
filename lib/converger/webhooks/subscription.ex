defmodule Converger.Webhooks.Subscription do
  @moduledoc """
  A tenant's platform event webhook subscription (`webhook_subscriptions`,
  ADR-0053): Converger POSTs every event of a type in `events` (or of every
  type, with `"*"`) to `url`, signed with `secret`.

  `secret` and `headers` are encrypted at rest (`Converger.Vault`). A
  subscription with `managed_by` set is maintained by the platform:
  `"alert_webhook_url"` mirrors `tenants.alert_webhook_url` and keeps the
  legacy health alert body.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Converger.Channels.{OutboundRequest, UrlGuard}
  alias Converger.Webhooks.Catalog

  @secret_prefix "whsec_"
  @min_secret_length 16
  @max_events 50

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_subscriptions" do
    field :url, :string
    field :description, :string
    field :secret, Converger.Encrypted.Binary, redact: true
    field :events, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :headers, Converger.Encrypted.Map, redact: true
    field :managed_by, :string

    belongs_to :tenant, Converger.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Generates a new random signing secret (`whsec_...`)."
  def generate_secret,
    do: @secret_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc """
  Changeset for create and update. `tenant_id` and `managed_by` are never
  cast: the caller sets them on the struct.
  """
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:url, :description, :secret, :events, :enabled, :headers])
    |> update_change(:events, &normalize_events/1)
    |> ensure_secret()
    |> validate_required([:url, :secret, :events, :tenant_id])
    |> validate_length(:description, max: 255)
    |> validate_length(:secret, min: @min_secret_length, max: 255)
    |> validate_length(:events, max: @max_events)
    |> validate_events()
    |> validate_url()
    |> validate_headers()
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :managed_by],
      name: :webhook_subscriptions_tenant_managed_by_index
    )
  end

  @doc "Whether the subscription receives events of `type`."
  def subscribed?(%__MODULE__{events: events}, type), do: "*" in events or type in events

  defp normalize_events(events) when is_list(events),
    do: events |> Enum.map(&String.trim/1) |> Enum.uniq()

  defp normalize_events(events), do: events

  defp ensure_secret(changeset) do
    case get_field(changeset, :secret) do
      secret when is_binary(secret) and secret != "" -> changeset
      _ -> put_change(changeset, :secret, generate_secret())
    end
  end

  defp validate_events(changeset) do
    changeset =
      if get_field(changeset, :events) in [nil, []],
        do: add_error(changeset, :events, "must list at least one event type"),
        else: changeset

    validate_change(changeset, :events, fn :events, events ->
      case Enum.reject(events, &(&1 == "*" or Catalog.known?(&1))) do
        [] -> []
        unknown -> [events: "unknown event types: #{Enum.join(unknown, ", ")}"]
      end
    end)
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          case UrlGuard.check(url) do
            :ok -> []
            {:error, message} -> [url: "is not allowed: #{message}"]
          end

        _ ->
          [url: "must be a valid HTTP or HTTPS URL"]
      end
    end)
  end

  defp validate_headers(changeset) do
    validate_change(changeset, :headers, fn :headers, headers ->
      case OutboundRequest.validate_headers(headers) do
        :ok -> []
        {:error, message} -> [headers: message]
      end
    end)
  end
end
