defmodule Converger.Channels.Adapter do
  @moduledoc """
  Behaviour for channel adapters, and the registry and dispatcher of the
  channel types.

  Each channel type is implemented by one adapter module. An adapter declares
  its type string, what it can do (`c:capabilities/0`) and its config fields
  (`c:config_schema/0`); everything else in Converger (the channel changeset,
  the admin forms, health checks, the pipeline, the inbound controller) is
  derived from those declarations, so adding a channel type never means
  editing a type list.

  ## Writing an adapter

      defmodule MyApp.Adapters.AcmeSms do
        use Converger.Channels.Adapter, type: "acme_sms"

        @impl true
        def capabilities, do: [:inbound, :outbound, :external_delivery, :receipts]

        @impl true
        def config_schema do
          [
            %{name: "base_url", type: :url, required: true, summary: true},
            %{name: "api_key", type: :string, required: true, secret: true}
          ]
        end

        @impl true
        def deliver_activity(channel, activity), do: ...

        @impl true
        def parse_inbound(channel, params), do: ...
      end

  `use` sets `@behaviour`, defines `c:type/0` and gives every optional
  callback with a sensible value a default (all overridable). Register a
  module outside `Converger.Channels.Adapters` with one config line:

      config :converger, :adapters, [MyApp.Adapters.AcmeSms]

  See `docs/channels/writing-an-adapter.md`.

  ## Registry

  The registry is the built-in adapters followed by `config :converger,
  :adapters`. A configured adapter whose `type/0` equals a built-in type
  replaces the built-in. `validate_registry!/0` checks every module at boot.
  """

  alias Converger.Channels.{DeliveryError, InboundSignature}

  @type channel :: Converger.Channels.Channel.t()
  @type activity :: Converger.Activities.Activity.t()
  @type config :: map()

  @typedoc """
  What an adapter can do, and how the rest of Converger treats its channels:

    * `:inbound` - accepts inbound messages (webhooks or sockets)
    * `:outbound` - the pipeline delivers activities to its channels
    * `:external_delivery` - delivers to a provider outside Converger; its
      channels get delivery-rate health checks
    * `:receipts` - reports delivery / read receipts
    * `:typing` - forwards typing indicators (`c:send_typing/2`)
    * `:lifecycle_events` - receives conversation lifecycle events
      (close / reopen), which carry no message content
    * `:provider_ack` - the provider retries every non-2xx inbound response,
      so a handled request is always answered `200`, even when messages were
      rejected permanently
    * `:media`, `:templates`, `:reactions`, `:edits` - outbound content the
      adapter renders natively
    * `activity_types: [String.t()]` - the activity types
      (`Converger.Activities.Activity.types/0`) `deliver_activity/2` renders
      natively. Other types are downgraded to text or skipped per channel,
      see `Converger.Activities.Downgrade`. Without this entry every client
      type is delivered as is.
  """
  @type capability ::
          :inbound
          | :outbound
          | :external_delivery
          | :receipts
          | :typing
          | :lifecycle_events
          | :provider_ack
          | :media
          | :templates
          | :reactions
          | :edits
          | {:activity_types, [String.t()]}

  @typedoc """
  One config field (`c:config_schema/0`):

    * `:name` - the config key (string)
    * `:type` - `:string`, `:url` (http/https), `:integer`, `:boolean` or
      `:map`; checked when the value is present
    * `:required` - `true`, `false` (default), or `:with_signature`: required
      only on channels with `require_signature: true` (a webhook signing key)
    * `:secret` - masked in the admin UI and rendered as a password input
    * `:label`, `:placeholder`, `:help` - admin form texts
    * `:summary` - shown next to the channel in the admin channel list
    * `:form` - `false` hides the field from the admin form (API only)
  """
  @type field :: %{
          required(:name) => String.t(),
          required(:type) => :string | :url | :integer | :boolean | :map,
          optional(:required) => boolean() | :with_signature,
          optional(:secret) => boolean(),
          optional(:label) => String.t(),
          optional(:placeholder) => String.t(),
          optional(:help) => String.t(),
          optional(:summary) => boolean(),
          optional(:form) => boolean()
        }

  @typedoc """
  A classified delivery failure (`c:normalize_error/1`). A
  `Converger.Channels.DeliveryError` is one; a plain map with these keys is
  accepted too.
  """
  @type normalized_error :: %{
          required(:reason) => term(),
          required(:retryable?) => boolean(),
          required(:retry_after_ms) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @doc "The channel type string of the adapter (e.g. `\"whatsapp_meta\"`). Defined by `use`."
  @callback type() :: String.t()

  @doc """
  Channel modes the adapter accepts. `use` derives them from
  `c:capabilities/0`: `duplex` needs both `:inbound` and `:outbound`.
  """
  @callback supported_modes() :: [String.t()]

  @doc """
  Deliver an activity to the channel.

    * `:ok` / `{:ok, meta}` - delivered; the delivery is marked `sent`, with
      `meta` merged into its metadata. A `provider_message_id` key in `meta`
      becomes the delivery's provider message id, which receipts look up.
    * `{:pending, meta}` - handed off, but receipt is not confirmed yet (a
      WebSocket channel with no connected client, or one that requires client
      acks). The delivery stays `pending` and is **not** retried; it is marked
      `sent` later by `Converger.Deliveries.acknowledge/3`.
    * `{:error, reason}` - failed; classified by `c:normalize_error/1` and
      retried according to the retry policy.
  """
  @callback deliver_activity(channel, activity) ::
              :ok | {:ok, map()} | {:pending, map()} | {:error, term()}

  @doc """
  Adapter-specific config checks, run after the `c:config_schema/0` checks
  (required fields and value types). `use` defaults it to `:ok`.
  """
  @callback validate_config(config) ::
              :ok | {:error, String.t()}

  @doc """
  The adapter's config fields, used to validate `channel.config` and to
  render the admin form. Keys not in the schema are allowed. `use` defaults
  it to `[]`.
  """
  @callback config_schema() :: [field()]

  @doc """
  Parse an inbound webhook payload into the messages it carries.

  Providers batch several messages into one webhook call, so this returns a
  **list**. The list may be empty, e.g. for a well-formed payload that only
  carries status updates or events Converger does not handle. Each parsed
  message is a map with:

    - "type", "text", "attachments", "metadata" - activity client fields
    - "sender" (required) - the sender identifier stored on the activity
    - "idempotency_key" (optional) - a stable provider message id (e.g. a
      WhatsApp `wamid`); a re-delivered webhook carrying the same id never
      creates a second activity

  `parse_inbound/2` below also accepts an adapter returning a single map.
  """
  @callback parse_inbound(channel, params :: map()) ::
              {:ok, [map()]} | {:ok, map()} | {:error, term()}

  @doc """
  Parse a provider status update (delivery receipt / read receipt).
  Returns {:ok, list_of_status_updates} or :ignore or {:error, reason}.

  Each status update map contains:
    - "provider_message_id" (required) - the provider's message ID
    - "status" (required) - one of "sent", "delivered", "read", "failed"
    - "timestamp" (optional) - ISO8601 or Unix timestamp from provider
    - "recipient_id" (optional) - provider recipient identifier
    - "error" (optional) - error details for failed status
  """
  @callback parse_status_update(channel, params :: map()) ::
              {:ok, [map()]} | :ignore | {:error, term()}

  @doc """
  Verify the signature of an inbound webhook request using the provider's
  native scheme (e.g. WhatsApp Meta's `X-Hub-Signature-256`).

  Receives the channel, the request headers (lowercase names) and the raw
  request body. Must return one of the results documented in
  `Converger.Channels.InboundSignature`: `:ok`, `:legacy`, `:missing` or
  `{:error, reason}`. Adapters that do not implement it fall back to the
  generic `x-converger-signature` scheme.
  """
  @callback verify_inbound_signature(
              channel,
              headers :: [{String.t(), String.t()}],
              raw_body :: binary() | nil
            ) :: :ok | :legacy | :missing | {:error, term()}

  @doc """
  Answer the provider's webhook verification handshake
  (`GET /api/v1/channels/:id/inbound`, e.g. Meta's `hub.challenge`):
  `{:ok, body}` is sent with `200`, `:error` gets `403`. Adapters that do not
  implement it answer `200 ok`.
  """
  @callback verify_subscription(channel, params :: map()) :: {:ok, String.t()} | :error

  @doc """
  Adapter-specific retry policy defaults (e.g. `%{timeout_ms: 10_000}`), merged
  over the global defaults and under the channel's own `retry_policy`. See
  `Converger.Pipeline.RetryPolicy`.
  """
  @callback retry_policy() :: map()

  @doc """
  Classify a `{:error, reason}` returned by `c:deliver_activity/2` for the
  retry policy and the circuit breaker. `use` defaults it to
  `Converger.Channels.DeliveryError.normalize/1`: a `DeliveryError` is kept,
  anything else is retryable.
  """
  @callback normalize_error(reason :: term()) :: normalized_error()

  @doc """
  What the adapter can do, see `t:capability/0`. Adapters that do not define
  it get `[:inbound, :outbound]`.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Default outbound rate limit of the provider (e.g. `"80/s"`), used when the
  channel sets no `rate_limit`. See `Converger.Channels.Circuit`.
  """
  @callback rate_limit() :: String.t() | nil

  @doc """
  Check that the channel's provider account works (e.g. call the provider's
  "me" endpoint with the configured credentials). Health checks call it for
  channels without deliveries in the window, see `Converger.Channels.Health`.
  Must not retry and should time out within a few seconds.
  """
  @callback health_probe(channel) :: :ok | {:error, term()}

  @typedoc """
  A transient conversation signal forwarded to an external channel (see
  `Converger.Channels.Signals`):

    - `:conversation_id` - the conversation
    - `:recipient` - the participant's `external_id` on this channel (e.g. a
      phone number)
    - `:provider_message_id` - the provider id of the participant's latest
      inbound message (up to `:up_to_seq` for read receipts), or nil
    - `:is_typing` - typing signals only
    - `:up_to_seq` - read receipts only: every activity up to this seq is read
  """
  @type signal :: %{
          required(:conversation_id) => String.t(),
          required(:recipient) => String.t(),
          required(:provider_message_id) => String.t() | nil,
          optional(:is_typing) => boolean(),
          optional(:up_to_seq) => pos_integer()
        }

  @doc """
  Show (or clear) a typing indicator to the channel's participant, e.g. the
  WhatsApp typing indicator. Best effort: never retried, errors are logged.
  """
  @callback send_typing(channel, signal) :: :ok | {:error, term()}

  @doc """
  Tell the provider that the participant's messages up to
  `signal.provider_message_id` have been read (e.g. WhatsApp blue ticks).
  Best effort: never retried, errors are logged.
  """
  @callback send_read_receipt(channel, signal) :: :ok | {:error, term()}

  @optional_callbacks [
    config_schema: 0,
    parse_status_update: 2,
    verify_inbound_signature: 3,
    verify_subscription: 2,
    retry_policy: 0,
    normalize_error: 1,
    capabilities: 0,
    rate_limit: 0,
    health_probe: 1,
    send_typing: 2,
    send_read_receipt: 2
  ]

  @default_capabilities [:inbound, :outbound]

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)

    unless is_binary(type) and type != "" do
      raise ArgumentError, "use Converger.Channels.Adapter needs a non-empty :type string"
    end

    quote do
      @behaviour Converger.Channels.Adapter

      @impl Converger.Channels.Adapter
      def type, do: unquote(type)

      @impl Converger.Channels.Adapter
      def capabilities, do: unquote(@default_capabilities)

      @impl Converger.Channels.Adapter
      def supported_modes, do: Converger.Channels.Adapter.modes_for(capabilities())

      @impl Converger.Channels.Adapter
      def config_schema, do: []

      @impl Converger.Channels.Adapter
      def validate_config(_config), do: :ok

      @impl Converger.Channels.Adapter
      def retry_policy, do: %{}

      @impl Converger.Channels.Adapter
      def rate_limit, do: nil

      @impl Converger.Channels.Adapter
      def normalize_error(reason), do: Converger.Channels.DeliveryError.normalize(reason)

      defoverridable capabilities: 0,
                     supported_modes: 0,
                     config_schema: 0,
                     validate_config: 1,
                     retry_policy: 0,
                     rate_limit: 0,
                     normalize_error: 1
    end
  end

  ## Registry

  @builtin_adapters [
    Converger.Channels.Adapters.Echo,
    Converger.Channels.Adapters.Webhook,
    Converger.Channels.Adapters.WebSocket,
    Converger.Channels.Adapters.WhatsAppMeta,
    Converger.Channels.Adapters.WhatsAppInfobip
  ]

  @required_functions [type: 0, supported_modes: 0, deliver_activity: 2, parse_inbound: 2]

  @doc """
  The registered adapters as `[{type, module}]`, built-ins first, then
  `config :converger, :adapters` in order. A configured adapter with a
  built-in type replaces it in place.
  """
  def adapters do
    configured = Application.get_env(:converger, :adapters, [])
    key = {__MODULE__, :registry, configured}

    case :persistent_term.get(key, nil) do
      nil ->
        registry =
          Enum.reduce(@builtin_adapters ++ configured, [], fn mod, acc ->
            List.keystore(acc, mod.type(), 0, {mod.type(), mod})
          end)

        :persistent_term.put(key, registry)
        registry

      registry ->
        registry
    end
  end

  @doc "Every registered channel type string."
  def types, do: Enum.map(adapters(), &elem(&1, 0))

  @doc "The registered channel types whose adapter has `capability`."
  def types_with(capability) do
    for {type, mod} <- adapters(), capability in module_capabilities(mod), do: type
  end

  @doc """
  Check every module of the registry: loaded, implementing the required
  callbacks, and returning a non-empty type string. Raises `ArgumentError`
  otherwise. Called at application start, so a misconfigured
  `config :converger, :adapters` fails the boot instead of a delivery.
  """
  def validate_registry! do
    for mod <- @builtin_adapters ++ Application.get_env(:converger, :adapters, []) do
      unless is_atom(mod) and Code.ensure_loaded?(mod) do
        raise ArgumentError, "channel adapter #{inspect(mod)} is not an available module"
      end

      missing =
        for {name, arity} <- @required_functions,
            not function_exported?(mod, name, arity),
            do: "#{name}/#{arity}"

      if missing != [] do
        raise ArgumentError,
              "channel adapter #{inspect(mod)} does not implement #{Enum.join(missing, ", ")} " <>
                "(use Converger.Channels.Adapter, type: \"...\")"
      end

      unless is_binary(mod.type()) and mod.type() != "" do
        raise ArgumentError,
              "channel adapter #{inspect(mod)} type/0 must return a non-empty string"
      end
    end

    :ok
  end

  @doc "Resolve the adapter module of a channel type string."
  def adapter_for(type) when is_binary(type) do
    case List.keyfind(adapters(), type, 0) do
      {^type, mod} -> {:ok, mod}
      nil -> {:error, "unknown channel type: #{type}"}
    end
  end

  def adapter_for(type), do: {:error, "unknown channel type: #{inspect(type)}"}

  @doc false
  def modes_for(capabilities) do
    case {:inbound in capabilities, :outbound in capabilities} do
      {true, true} -> ~w(inbound outbound duplex)
      {true, false} -> ~w(inbound)
      {false, true} -> ~w(outbound)
      {false, false} -> []
    end
  end

  ## Config validation

  @doc """
  Validate a channel config: the adapter's `c:config_schema/0` (required
  fields, value types), then its `c:validate_config/1`.

  Options:

    * `:require_signature` - whether the channel requires signed inbound
      requests; fields with `required: :with_signature` are required only
      then (default `false`)
  """
  def validate_config(type, config, opts \\ [])

  def validate_config(nil, _config, _opts), do: :ok

  def validate_config(type, config, opts) do
    config = config || %{}

    with {:ok, mod} <- adapter_for(type),
         :ok <- validate_schema(type, config_schema(type), config, opts) do
      mod.validate_config(config)
    end
  end

  @doc "Check `config` against a config schema, see `validate_config/3`."
  def validate_schema(type, schema, config, opts \\ []) do
    signed? = Keyword.get(opts, :require_signature, false) == true

    missing = for %{required: true} = f <- schema, blank?(config[f.name]), do: f.name

    missing_signed =
      for %{required: :with_signature} = f <- schema,
          signed?,
          blank?(config[f.name]),
          do: f.name

    cond do
      missing != [] ->
        {:error, "#{type} config missing: #{Enum.join(missing, ", ")}"}

      missing_signed != [] ->
        {:error,
         "#{type} config missing: #{Enum.join(missing_signed, ", ")} " <>
           "(required when require_signature is true)"}

      true ->
        Enum.find_value(schema, :ok, fn field ->
          value = config[field.name]

          if not blank?(value) and not valid_value?(field.type, value),
            do: {:error, "#{type} config '#{field.name}' #{type_error(field.type)}"}
        end)
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp valid_value?(:string, value), do: is_binary(value)
  defp valid_value?(:map, value), do: is_map(value)
  defp valid_value?(:boolean, value), do: value in [true, false, "true", "false"]
  defp valid_value?(:integer, value) when is_integer(value), do: true

  defp valid_value?(:integer, value) when is_binary(value),
    do: match?({_, ""}, Integer.parse(String.trim(value)))

  defp valid_value?(:url, value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_value?(_type, _value), do: false

  defp type_error(:string), do: "must be a string"
  defp type_error(:map), do: "must be a map"
  defp type_error(:boolean), do: "must be true or false"
  defp type_error(:integer), do: "must be an integer"
  defp type_error(:url), do: "must be a valid HTTP/HTTPS URL"

  ## Dispatch

  def deliver_activity(%{type: type} = channel, activity) do
    case adapter_for(type) do
      {:ok, mod} -> mod.deliver_activity(channel, activity)
      {:error, _} = err -> err
    end
  end

  @doc """
  Classify a delivery failure with the channel's adapter
  (`c:normalize_error/1`). Always returns a `DeliveryError`.
  """
  def normalize_error(%{type: type}, reason) do
    normalized =
      case optional(type, :normalize_error, 1) do
        {:ok, mod} -> mod.normalize_error(reason)
        :error -> reason
      end

    DeliveryError.normalize(normalized)
  end

  @doc """
  Parse an inbound payload with the channel's adapter. Always returns
  `{:ok, list_of_messages}` or `{:error, reason}`.
  """
  def parse_inbound(%{type: type} = channel, params) do
    case adapter_for(type) do
      {:ok, mod} ->
        case mod.parse_inbound(channel, params) do
          {:ok, messages} when is_list(messages) -> {:ok, messages}
          {:ok, %{} = message} -> {:ok, [message]}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  def parse_status_update(%{type: type} = channel, params) do
    case adapter_for(type) do
      {:ok, _mod} -> call_optional(type, :parse_status_update, [channel, params], :ignore)
      {:error, _} = err -> err
    end
  end

  @doc """
  Verify an inbound webhook signature with the channel's adapter, falling
  back to the generic `x-converger-signature` scheme.
  """
  def verify_inbound_signature(%{type: type} = channel, headers, raw_body) do
    case adapter_for(type) do
      {:ok, _mod} ->
        case optional(type, :verify_inbound_signature, 3) do
          {:ok, mod} -> mod.verify_inbound_signature(channel, headers, raw_body)
          :error -> InboundSignature.verify(channel, headers, raw_body)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Answer a webhook verification handshake with the channel's adapter
  (`c:verify_subscription/2`); `{:ok, "ok"}` when it does not implement one.
  """
  def verify_subscription(%{type: type} = channel, params),
    do: call_optional(type, :verify_subscription, [channel, params], {:ok, "ok"})

  @doc """
  Forward a typing signal with the channel's adapter. `:unsupported` when the
  adapter does not implement `c:send_typing/2`.
  """
  def send_typing(%{type: type} = channel, signal),
    do: call_optional(type, :send_typing, [channel, signal], :unsupported)

  @doc """
  Forward a read receipt with the channel's adapter. `:unsupported` when the
  adapter does not implement `c:send_read_receipt/2`.
  """
  def send_read_receipt(%{type: type} = channel, signal),
    do: call_optional(type, :send_read_receipt, [channel, signal], :unsupported)

  @doc """
  Probe the channel's provider with its adapter (`c:health_probe/1`).
  `:unsupported` when the adapter does not implement one.
  """
  def health_probe(%{type: type} = channel),
    do: call_optional(type, :health_probe, [channel], :unsupported)

  @doc "Whether the adapter for `type` implements the optional callback `name/arity`."
  def supports?(type, name, arity), do: optional(type, name, arity) != :error

  defp optional(type, name, arity) do
    with {:ok, mod} <- adapter_for(type),
         true <- Code.ensure_loaded?(mod) and function_exported?(mod, name, arity) do
      {:ok, mod}
    else
      _ -> :error
    end
  end

  defp call_optional(type, name, args, default) do
    case optional(type, name, length(args)) do
      # apply/3 because the callback is optional and not every adapter defines it
      {:ok, mod} -> apply(mod, name, args)
      :error -> default
    end
  end

  @doc "Retry policy defaults of the adapter for `type` (empty when it defines none)."
  def retry_policy(type), do: call_optional(type, :retry_policy, [], %{})

  @doc "Config schema of the adapter for `type` (empty when it defines none)."
  def config_schema(type), do: call_optional(type, :config_schema, [], [])

  @doc "Capabilities of the adapter for `type` (empty for an unknown type)."
  def capabilities(type) do
    case adapter_for(type) do
      {:ok, mod} -> module_capabilities(mod)
      {:error, _} -> []
    end
  end

  defp module_capabilities(mod) do
    # apply/3 because the callback is optional and not every adapter defines it
    if Code.ensure_loaded?(mod) and function_exported?(mod, :capabilities, 0),
      do: apply(mod, :capabilities, []),
      else: @default_capabilities
  end

  @doc """
  The activity types the adapter for `type` delivers natively: the
  `activity_types:` entry of its capabilities, else every client type.
  """
  def activity_types(type) do
    case List.keyfind(capabilities(type), :activity_types, 0) do
      {:activity_types, types} -> types
      nil -> Converger.Activities.Activity.client_types()
    end
  end

  @doc "Whether the adapter for `type` has `capability`."
  def capability?(type, capability), do: capability in capabilities(type)

  @doc "Default outbound rate limit of the adapter for `type` (`nil` when it defines none)."
  def rate_limit(type), do: call_optional(type, :rate_limit, [], nil)

  def supported_modes(nil), do: ~w(inbound outbound duplex)

  def supported_modes(type) do
    case adapter_for(type) do
      {:ok, mod} -> mod.supported_modes()
      {:error, _} -> []
    end
  end
end
