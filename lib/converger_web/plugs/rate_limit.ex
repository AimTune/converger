defmodule ConvergerWeb.Plugs.RateLimit do
  @moduledoc """
  Rate-limit plug on top of `Converger.RateLimit`.

      plug ConvergerWeb.Plugs.RateLimit, bucket: :activity_create, scope: :tenant

  Options:

    * `:bucket` - limit bucket (see `Converger.RateLimit`); also the key
      prefix. Limits are resolved from the tenant override, the app config
      and the built-in defaults.
    * `:scope` - what is counted:
      * `:ip` - `conn.remote_ip`
      * `:tenant` - `conn.assigns.tenant` or the tenant of the Converger token
      * `:channel` - `conn.assigns.channel`, the channel of the Converger token,
        or the `channel_id` path parameter
    * `:limit` / `:scale_ms` - default limit when the bucket has none configured
    * `:key_prefix` - key prefix for ad-hoc limits without a `:bucket`

  Rejected requests get `429 Too Many Requests` with a `Retry-After` header
  (seconds).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Converger.RateLimit

  def init(opts), do: opts

  def call(conn, opts) do
    scope = opts[:scope] || :ip
    {id, tenant_ref} = identify(conn, scope)

    case RateLimit.check(bucket(opts), "#{scope}:#{id}", check_opts(opts, tenant_ref)) do
      {:allow, _count} -> conn
      {:deny, retry_after_ms, _spec} -> deny(conn, retry_after_ms)
    end
  end

  defp bucket(opts), do: opts[:bucket] || opts[:key_prefix] || "rl"

  # An explicit :limit / :scale_ms (or an ad-hoc key without a bucket) is the
  # fallback when no bucket limit is configured.
  defp check_opts(opts, tenant_ref) do
    if opts[:limit] || opts[:scale_ms] || !opts[:bucket],
      do: [tenant: tenant_ref, default: {opts[:limit] || 10, opts[:scale_ms] || 60_000}],
      else: [tenant: tenant_ref]
  end

  defp deny(conn, retry_after_ms) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds(retry_after_ms)))
    |> put_status(:too_many_requests)
    |> json(%{error: "Too many requests. Please try again later."})
    |> halt()
  end

  @doc false
  def retry_after_seconds(ms), do: max(div(ms + 999, 1000), 1)

  defp identify(conn, :ip) do
    {conn.remote_ip |> :inet.ntoa() |> to_string(), nil}
  end

  defp identify(conn, :tenant) do
    case conn.assigns do
      %{tenant: %{id: id} = tenant} -> {id, tenant}
      %{converger_claims: %{"tenant_id" => id}} when is_binary(id) -> {id, id}
      _ -> {"anonymous", nil}
    end
  end

  defp identify(conn, :channel) do
    case conn.assigns do
      %{channel: %{id: id, tenant_id: tenant_id}} ->
        {id, tenant_id}

      %{converger_claims: %{"channel_id" => id} = claims} when is_binary(id) ->
        {id, claims["tenant_id"]}

      _ ->
        case conn.path_params do
          %{"channel_id" => id} when is_binary(id) -> {id, {:channel, id}}
          _ -> {"anonymous", nil}
        end
    end
  end
end
