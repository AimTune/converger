defmodule Converger.Channels.UrlGuard do
  @moduledoc """
  SSRF guard for outbound channel URLs (webhook targets).

  A target is rejected when its host is, or resolves to, an address that is
  not publicly routable: loopback, private (RFC 1918 / unique local),
  link-local (which includes cloud metadata endpoints such as
  `169.254.169.254` and `fd00:ec2::254`), carrier-grade NAT, multicast,
  reserved and documentation ranges, for IPv4 and IPv6. IPv4-mapped IPv6
  addresses (`::ffff:a.b.c.d`) are checked as IPv4, and IPv6 transition
  prefixes that embed IPv4 addresses (NAT64, 6to4) are blocked.

  The check runs twice:

    * when the channel config is validated (`check/1`). Hosts that cannot be
      resolved at that moment are accepted, because they are checked again
      before every request;
    * before every request (`resolve/1`). The host is resolved, *every*
      returned address must be allowed, and the request is then pinned to
      one of the checked addresses, so a DNS answer that changes between the
      check and the connection (DNS rebinding) cannot reach an internal
      address.

  ## Configuration

      config :converger, :webhook,
        # Disable the guard completely (development only).
        allow_private_targets: false,
        # Hosts or IP/CIDR ranges that are allowed even though they are
        # private. Host entries match exactly (case-insensitive); a leading
        # "*." matches any subdomain.
        allowed_targets: ["localhost", "10.20.0.0/16", "*.svc.cluster.local"],
        # DNS resolver, `{module, function}` or a 1-arity function that
        # takes a host string and returns `{:ok, [ip_tuple]}` or `{:error, reason}`.
        resolver: {Converger.Channels.UrlGuard, :resolve_host}

  In releases, `WEBHOOK_ALLOW_PRIVATE_TARGETS` and `WEBHOOK_ALLOWED_TARGETS`
  set the first two (see `config/runtime.exs`).
  """

  alias ConvergerWeb.IpMatcher

  @blocked_ranges ~w(
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.88.99.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    240.0.0.0/4
    ::/96
    64:ff9b::/96
    64:ff9b:1::/48
    100::/64
    2001:db8::/32
    2002::/16
    fc00::/7
    fe80::/10
    fec0::/10
    ff00::/8
  )

  @dns_timeout 5_000

  @type target :: %{uri: URI.t(), host: String.t(), ip: :inet.ip_address() | nil}

  @doc """
  Config-time check. Returns `:ok` or `{:error, message}`.

  Unresolvable hosts are accepted; `resolve/1` rejects them at request time.
  """
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(url) do
    case resolve(url) do
      {:ok, _target} -> :ok
      {:error, {:unresolvable, _host}} -> :ok
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc """
  Request-time check. Resolves the host and returns the address the request
  must be pinned to.

  `ip` is `nil` when no pinning is needed: the host is an IP literal (already
  checked) or an explicitly allowed host name.
  """
  @spec resolve(String.t()) :: {:ok, target()} | {:error, term()}
  def resolve(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         {:ok, host} <- fetch_host(uri) do
      settings = settings()

      cond do
        settings.allow_private? or host_allowed?(host, settings.allowed_hosts) ->
          {:ok, %{uri: uri, host: host, ip: nil}}

        match?({:ok, _}, IpMatcher.parse_address(host)) ->
          {:ok, ip} = IpMatcher.parse_address(host)

          with :ok <- check_ip(host, ip, settings), do: {:ok, %{uri: uri, host: host, ip: nil}}

        true ->
          resolve_and_check(uri, host, settings)
      end
    end
  end

  def resolve(_), do: {:error, :invalid_url}

  @doc "Whether `ip` is in a blocked (non-public) range."
  @spec blocked_ip?(:inet.ip_address()) :: boolean()
  def blocked_ip?(ip), do: IpMatcher.member?(ip, blocked_blocks())

  @doc "Human-readable message for a `resolve/1` error."
  @spec format_error(term()) :: String.t()
  def format_error(:invalid_url), do: "must be a valid HTTP/HTTPS URL"
  def format_error(:invalid_scheme), do: "must use http or https"
  def format_error(:missing_host), do: "must include a host"
  def format_error({:unresolvable, host}), do: "host #{host} could not be resolved"

  def format_error({:blocked_address, host, ip}) do
    addr = ip |> :inet.ntoa() |> to_string()

    if addr == host,
      do: "target #{host} is a private, loopback or link-local address",
      else: "host #{host} resolves to a private, loopback or link-local address (#{addr})"
  end

  @doc """
  Default resolver: all IPv4 and IPv6 addresses of `host`.
  """
  @spec resolve_host(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve_host(host) do
    charlist = String.to_charlist(host)

    ips =
      for family <- [:inet, :inet6],
          {:ok, addrs} <- [:inet.getaddrs(charlist, family, @dns_timeout)],
          addr <- addrs,
          do: addr

    case Enum.uniq(ips) do
      [] -> {:error, :nxdomain}
      ips -> {:ok, ips}
    end
  end

  defp resolve_and_check(uri, host, settings) do
    case run_resolver(settings.resolver, host) do
      {:ok, [_ | _] = ips} ->
        with :ok <- Enum.reduce_while(ips, :ok, &check_each(host, &1, settings, &2)) do
          # Prefer IPv4: it works without `inet6` socket options everywhere.
          ip = Enum.find(ips, &(tuple_size(&1) == 4)) || hd(ips)
          {:ok, %{uri: uri, host: host, ip: ip}}
        end

      _ ->
        {:error, {:unresolvable, host}}
    end
  end

  defp check_each(host, ip, settings, :ok) do
    case check_ip(host, ip, settings) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_ip(host, ip, settings) do
    if blocked_ip?(ip) and not IpMatcher.member?(ip, settings.allowed_blocks),
      do: {:error, {:blocked_address, host, ip}},
      else: :ok
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_), do: {:error, :invalid_scheme}

  defp fetch_host(%URI{host: host}) when is_binary(host) and host != "" do
    {:ok, host |> String.downcase() |> String.trim_trailing(".")}
  end

  defp fetch_host(_), do: {:error, :missing_host}

  defp host_allowed?(host, allowed_hosts) do
    Enum.any?(allowed_hosts, fn
      "*." <> suffix -> String.ends_with?(host, "." <> suffix)
      allowed -> host == allowed
    end)
  end

  defp run_resolver({mod, fun}, host), do: apply(mod, fun, [host])
  defp run_resolver(fun, host) when is_function(fun, 1), do: fun.(host)

  defp settings do
    config = Application.get_env(:converger, :webhook, [])

    {ip_entries, host_entries} =
      config
      |> Keyword.get(:allowed_targets, [])
      |> List.wrap()
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.split_with(&match?({:ok, _}, IpMatcher.parse(&1)))

    %{
      allow_private?: Keyword.get(config, :allow_private_targets, false) == true,
      allowed_blocks: IpMatcher.parse_list_cached(ip_entries),
      allowed_hosts: Enum.map(host_entries, &String.trim_trailing(&1, ".")),
      resolver: Keyword.get(config, :resolver, {__MODULE__, :resolve_host})
    }
  end

  defp blocked_blocks, do: IpMatcher.parse_list_cached(@blocked_ranges)
end
