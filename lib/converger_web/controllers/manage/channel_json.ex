defmodule ConvergerWeb.Manage.ChannelJSON do
  alias Converger.Channels.{Adapter, Channel}
  alias Converger.Secrets

  def index(%{channels: channels}) do
    %{data: for(channel <- channels, do: data(channel, false))}
  end

  def show(%{channel: channel} = assigns) do
    %{data: data(channel, Map.get(assigns, :include_secret, false))}
  end

  @doc """
  A channel as JSON. Secret config fields (the adapter's `secret: true`
  fields and keys `Converger.Secrets` treats as sensitive) are
  `[REDACTED]`; the channel secret only when `include_secret`.
  """
  def data(%Channel{} = channel, include_secret) do
    base = %{
      id: channel.id,
      tenant_id: channel.tenant_id,
      name: channel.name,
      type: channel.type,
      mode: channel.mode,
      status: channel.status,
      require_signature: channel.require_signature,
      config: redact_config(channel.type, channel.config || %{}),
      transformations: channel.transformations,
      retry_policy: channel.retry_policy,
      rate_limit: channel.rate_limit,
      circuit_state: channel.circuit_state,
      inserted_at: channel.inserted_at,
      updated_at: channel.updated_at
    }

    if include_secret, do: Map.put(base, :secret, channel.secret), else: base
  end

  @doc "The channel config with its secret values replaced by `[REDACTED]`."
  def redact_config(type, config) do
    secret_fields = for %{name: name, secret: true} <- Adapter.config_schema(type), do: name

    config
    |> Secrets.redact()
    |> Map.new(fn {key, value} ->
      if key in secret_fields and not is_nil(value),
        do: {key, Secrets.redacted()},
        else: {key, value}
    end)
  end
end
