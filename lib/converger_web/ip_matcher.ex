defmodule ConvergerWeb.IpMatcher do
  @moduledoc """
  Parses IP addresses and CIDR ranges (IPv4 and IPv6) and checks membership.

  Entries may be single addresses (`"127.0.0.1"`, `"::1"`) or CIDR ranges
  (`"10.0.0.0/8"`, `"fd00::/8"`). A single address is treated as a `/32`
  (IPv4) or `/128` (IPv6) range. IPv4-mapped IPv6 addresses
  (`::ffff:a.b.c.d`) are matched as their IPv4 equivalent.
  """

  require Logger

  @type block :: {:v4 | :v6, non_neg_integer(), non_neg_integer()}

  @doc """
  Parses a list of address / CIDR strings into blocks.

  Invalid entries are skipped and logged.
  """
  @spec parse_list([String.t()] | String.t() | nil) :: [block()]
  def parse_list(nil), do: []
  def parse_list(entries) when is_binary(entries), do: entries |> split() |> parse_list()

  def parse_list(entries) when is_list(entries) do
    Enum.flat_map(entries, fn entry ->
      case parse(entry) do
        {:ok, block} ->
          [block]

        :error ->
          Logger.warning("Ignoring invalid IP/CIDR entry: #{inspect(entry)}")
          []
      end
    end)
  end

  @doc """
  Like `parse_list/1`, but memoizes the result in `:persistent_term` keyed by
  the raw entries, so config read on every request is parsed (and invalid
  entries logged) only once per distinct value.
  """
  @spec parse_list_cached([String.t()] | String.t() | nil) :: [block()]
  def parse_list_cached(entries) do
    key = {__MODULE__, entries}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        blocks = parse_list(entries)
        :persistent_term.put(key, blocks)
        blocks

      blocks ->
        blocks
    end
  end

  @doc """
  Splits a comma-separated string into trimmed, non-empty entries.
  """
  @spec split(String.t() | nil) :: [String.t()]
  def split(nil), do: []

  def split(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Parses a single address or CIDR string.
  """
  @spec parse(String.t()) :: {:ok, block()} | :error
  def parse(entry) when is_binary(entry) do
    case String.split(String.trim(entry), "/", parts: 2) do
      [addr] ->
        with {:ok, ip} <- parse_address(addr) do
          {proto, int, bits} = to_int(ip)
          {:ok, {proto, int, mask(bits, bits)}}
        end

      [addr, prefix] ->
        with {:ok, ip} <- parse_address(addr),
             {proto, int, bits} = to_int(ip),
             {len, ""} when len >= 0 and len <= bits <- Integer.parse(prefix) do
          mask = mask(bits, len)
          {:ok, {proto, Bitwise.band(int, mask), mask}}
        else
          _ -> :error
        end
    end
  end

  def parse(_), do: :error

  @doc """
  Parses an IP address string into an `:inet.ip_address()` tuple.
  """
  @spec parse_address(String.t()) :: {:ok, :inet.ip_address()} | :error
  def parse_address(addr) when is_binary(addr) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(addr))) do
      {:ok, ip} -> {:ok, normalize(ip)}
      {:error, _} -> :error
    end
  end

  @doc """
  Returns true when `ip` (tuple) falls in any of the given blocks.
  """
  @spec member?(:inet.ip_address() | nil, [block()]) :: boolean()
  def member?(nil, _blocks), do: false

  def member?(ip, blocks) when is_tuple(ip) and is_list(blocks) do
    {proto, int, _bits} = ip |> normalize() |> to_int()

    Enum.any?(blocks, fn {block_proto, net, mask} ->
      block_proto == proto and Bitwise.band(int, mask) == net
    end)
  end

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) is treated as IPv4.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end

  defp normalize(ip), do: ip

  defp to_int({a, b, c, d}) do
    <<int::32>> = <<a, b, c, d>>
    {:v4, int, 32}
  end

  defp to_int({a, b, c, d, e, f, g, h}) do
    <<int::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    {:v6, int, 128}
  end

  defp mask(bits, len) do
    all = Bitwise.bsl(1, bits) - 1
    Bitwise.band(Bitwise.bsl(all, bits - len), all)
  end
end
