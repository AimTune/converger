defmodule ConvergerWeb.Plugs.TrustedProxies do
  @moduledoc """
  Rewrites `conn.remote_ip` from `X-Forwarded-For`, but only across trusted hops.

  The list of trusted proxies is read from `:converger, :trusted_proxies` on
  every call (configured at runtime from the `TRUSTED_PROXIES` env var as a
  comma-separated list of IPs / CIDR ranges), so releases pick it up without
  recompiling.

  Algorithm:

    * If the TCP peer (`conn.remote_ip`) is not a trusted proxy, the request is
      left untouched and any forwarding headers are ignored. A client talking to
      the app directly therefore cannot spoof its address.
    * Otherwise the `X-Forwarded-For` chain is walked from right to left (the
      right-most entry was appended by the nearest proxy). Trusted entries are
      skipped; the first untrusted entry is the client address.
    * If an entry cannot be parsed the walk stops and the last trusted hop is
      used, so garbage injected by the client is never trusted.
    * If every entry is trusted, the left-most one is used.

  With no trusted proxies configured (the default) this plug is a no-op.
  The original peer address is kept in `conn.private[:peer_remote_ip]`.
  """

  @behaviour Plug

  alias ConvergerWeb.IpMatcher

  @header "x-forwarded-for"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    proxies =
      opts
      |> Keyword.get_lazy(:proxies, fn ->
        Application.get_env(:converger, :trusted_proxies, [])
      end)
      |> IpMatcher.parse_list_cached()

    peer = conn.remote_ip

    if proxies != [] and IpMatcher.member?(peer, proxies) do
      client_ip = resolve(forwarded_ips(conn), peer, proxies)

      conn
      |> Plug.Conn.put_private(:peer_remote_ip, peer)
      |> Map.put(:remote_ip, client_ip)
    else
      conn
    end
  end

  defp forwarded_ips(conn) do
    conn
    |> Plug.Conn.get_req_header(@header)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp resolve(entries, peer, proxies) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while(peer, fn entry, last_trusted ->
      case parse_entry(entry) do
        {:ok, ip} ->
          if IpMatcher.member?(ip, proxies) do
            {:cont, ip}
          else
            {:halt, ip}
          end

        :error ->
          {:halt, last_trusted}
      end
    end)
  end

  # Accepts "1.2.3.4", "1.2.3.4:5678", "::1", "[::1]" and "[::1]:5678".
  defp parse_entry("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [addr, port] when port == "" or binary_part(port, 0, 1) == ":" ->
        IpMatcher.parse_address(addr)

      _ ->
        :error
    end
  end

  defp parse_entry(entry) do
    case IpMatcher.parse_address(entry) do
      {:ok, ip} ->
        {:ok, ip}

      :error ->
        case String.split(entry, ":") do
          [addr, port] when port != "" -> IpMatcher.parse_address(addr)
          _ -> :error
        end
    end
  end
end
