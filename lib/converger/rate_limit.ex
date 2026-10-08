defmodule Converger.RateLimit do
  @moduledoc """
  Rate limiting built on Hammer 7.

  Counters live in a node-local ETS table (`Converger.RateLimit.Local`, fixed
  windows aligned to wall-clock time). Two backends are available through
  `config :converger, Converger.RateLimit, backend: ...`:

    * `:local` (default) - counters are per node. Correct for a single node;
      with N nodes behind a load balancer the effective limit is up to N times
      the configured one.
    * `:cluster` - counters are additionally replicated to every connected
      node over `Phoenix.PubSub` (`Converger.RateLimit.ClusterSync`), so limits
      apply across the cluster with no extra infrastructure. Replication is
      batched every `:sync_interval_ms` (default 100ms), so limits are
      eventually consistent: a burst may overshoot by what other nodes accept
      within one interval.

  ## Buckets and limits

  Each check names a bucket. Its `{limit, scale_ms}` is resolved, in order of
  precedence, from:

    1. the tenant override in `tenants.limits`
       (`%{"activity_create" => %{"limit" => 200, "scale_ms" => 1000}}`),
    2. `config :converger, Converger.RateLimit, limits: %{activity_create: {200, 1_000}}`,
    3. the `:default` passed by the caller,
    4. the built-in defaults below.

  Exceeded limits emit `[:converger, :rate_limit, :exceeded]` telemetry with
  measurements `%{count: 1}` and metadata `%{bucket, key, limit, scale_ms,
  retry_after_ms}`.
  """

  alias Converger.RateLimit.{ClusterSync, Local, Overrides}

  @default_limits %{
    # per tenant, shared by the tenant API and the Converger client API
    activity_create: {100, 1_000},
    # per tenant
    upload: {10, 1_000},
    # per channel (inbound + status webhooks)
    inbound: {500, 1_000},
    # per channel secret / channel token
    token_generate: {10, 60_000},
    # legacy /api/v1/tokens, per client IP (unauthenticated)
    token_create: {10, 60_000},
    # failed logins, per client IP and per account
    login_ip: {5, 60_000},
    login_account: {5, 60_000}
  }

  @tenant_buckets ~w(activity_create upload inbound token_generate)

  @type bucket :: atom() | String.t()
  @type limit_spec :: {pos_integer(), pos_integer()}

  @doc "Buckets that tenants can override through `tenants.limits`."
  @spec tenant_buckets() :: [String.t()]
  def tenant_buckets, do: @tenant_buckets

  @doc "Built-in default limits, `%{bucket => {limit, scale_ms}}`."
  @spec default_limits() :: %{bucket() => limit_spec()}
  def default_limits, do: @default_limits

  @doc """
  Counts one request for `id` in `bucket` and checks it against the resolved
  limit.

  Options: `:tenant` (tenant struct, tenant id or `{:channel, channel_id}`
  used to look up overrides) and `:default` (`{limit, scale_ms}`).
  """
  @spec check(bucket(), term(), keyword()) ::
          {:allow, pos_integer()} | {:deny, non_neg_integer(), limit_spec()}
  def check(bucket, id, opts \\ []) do
    {limit, scale_ms} = spec = limit_for(bucket, opts)
    key = key(bucket, id)

    case hit(key, scale_ms, limit) do
      {:allow, count} ->
        {:allow, count}

      {:deny, retry_after_ms} ->
        exceeded(bucket, key, spec, retry_after_ms)
        {:deny, retry_after_ms, spec}
    end
  end

  @doc """
  Returns `:ok` when fewer than `limit` events have been recorded with
  `record/3` for `id` in the current window, or `{:deny, retry_after_ms, spec}`.
  Unlike `check/3` it does not count anything (used for failed-login lockout).
  """
  @spec peek(bucket(), term(), keyword()) :: :ok | {:deny, non_neg_integer(), limit_spec()}
  def peek(bucket, id, opts \\ []) do
    {limit, scale_ms} = spec = limit_for(bucket, opts)
    key = key(bucket, id)

    if Local.get(key, scale_ms) >= limit do
      retry_after_ms = retry_after_ms(key, scale_ms)
      exceeded(bucket, key, spec, retry_after_ms)
      {:deny, retry_after_ms, spec}
    else
      :ok
    end
  end

  @doc "Records one event for `id` in `bucket` without checking the limit."
  @spec record(bucket(), term(), keyword()) :: pos_integer()
  def record(bucket, id, opts \\ []) do
    {_limit, scale_ms} = limit_for(bucket, opts)
    inc(key(bucket, id), scale_ms, 1)
  end

  @doc "Resolves the `{limit, scale_ms}` for a bucket (see the module docs)."
  @spec limit_for(bucket(), keyword()) :: limit_spec()
  def limit_for(bucket, opts \\ []) do
    tenant_override(bucket, Keyword.get(opts, :tenant)) ||
      configured(bucket) ||
      Keyword.get(opts, :default) ||
      Map.get(@default_limits, bucket) ||
      raise ArgumentError, "no rate limit configured for bucket #{inspect(bucket)}"
  end

  @doc "Returns the configured backend (`:local` or `:cluster`)."
  @spec backend() :: :local | :cluster
  def backend, do: :persistent_term.get({__MODULE__, :backend}, :local)

  @doc "Hammer-compatible hit that is replicated when the cluster backend is on."
  @spec hit(term(), pos_integer(), pos_integer()) ::
          {:allow, pos_integer()} | {:deny, non_neg_integer()}
  def hit(key, scale_ms, limit) do
    result = Local.hit(key, scale_ms, limit)
    replicate(key, scale_ms, 1)
    result
  end

  @doc "Hammer-compatible increment that is replicated when the cluster backend is on."
  @spec inc(term(), pos_integer(), pos_integer()) :: pos_integer()
  def inc(key, scale_ms, increment) do
    count = Local.inc(key, scale_ms, increment)
    replicate(key, scale_ms, increment)
    count
  end

  defp replicate(key, scale_ms, increment) do
    if backend() == :cluster, do: ClusterSync.record(ClusterSync, key, scale_ms, increment)
    :ok
  end

  defp retry_after_ms(key, scale_ms) do
    case Local.expires_at(key, scale_ms) do
      0 -> scale_ms
      expires_at -> max(expires_at - System.system_time(:millisecond), 0)
    end
  end

  defp key(bucket, id), do: "#{bucket}:#{id}"

  defp exceeded(bucket, key, {limit, scale_ms}, retry_after_ms) do
    :telemetry.execute([:converger, :rate_limit, :exceeded], %{count: 1}, %{
      bucket: bucket,
      key: key,
      limit: limit,
      scale_ms: scale_ms,
      retry_after_ms: retry_after_ms
    })
  end

  defp configured(bucket) do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:limits, %{})
    |> Map.get(bucket)
  end

  defp tenant_override(_bucket, nil), do: nil

  defp tenant_override(bucket, tenant_ref) do
    name = to_string(bucket)

    if name in @tenant_buckets do
      case Overrides.limits_for(tenant_ref) do
        %{^name => %{"limit" => limit, "scale_ms" => scale_ms}}
        when is_integer(limit) and limit > 0 and is_integer(scale_ms) and scale_ms > 0 ->
          {limit, scale_ms}

        _ ->
          nil
      end
    end
  end
end
