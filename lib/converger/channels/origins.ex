defmodule Converger.Channels.Origins do
  @moduledoc """
  Web origins allowed to use a channel's publishable key (issue #195,
  ADR-0074).

  An entry is either an exact origin, `scheme://host[:port]` as a browser
  sends it in the `Origin` header (`https://shop.example.com`,
  `http://localhost:5173`), or a subdomain wildcard `scheme://*.domain[:port]`
  (`https://*.example.com` matches `https://a.example.com` and
  `https://a.b.example.com`, not `https://example.com`). Schemes are `http`
  and `https`; paths, queries, credentials and a bare `*` are refused.

  Entries are normalized like the `Origin` header: lowercase scheme and
  host, no trailing slash, and no port when it is the scheme's default.
  """

  @max_origins 20
  @default_ports %{"http" => 80, "https" => 443}

  @doc "The most origins a channel may allow."
  def max_origins, do: @max_origins

  @doc """
  Normalizes a list of entries (or text with one entry per line or comma
  separated). Blank entries are dropped and duplicates removed. Returns
  `{:ok, origins}` or `{:error, message}` naming the first invalid entry.
  """
  def cast_list(text) when is_binary(text) do
    text |> String.split(["\n", "\r", ","], trim: true) |> cast_list()
  end

  def cast_list(entries) when is_list(entries) do
    entries
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize(entry) do
        {:ok, origin} -> {:cont, {:ok, [origin | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, origins} ->
        origins = origins |> Enum.reverse() |> Enum.uniq()

        if length(origins) > @max_origins,
          do: {:error, "at most #{@max_origins} origins are allowed"},
          else: {:ok, origins}

      error ->
        error
    end
  end

  def cast_list(nil), do: {:ok, []}
  def cast_list(_other), do: {:error, "must be a list of origins"}

  @doc """
  Normalizes one entry. Returns `{:ok, origin}` or `{:error, message}`.
  """
  def normalize(entry) when is_binary(entry) do
    trimmed = entry |> String.trim() |> String.trim_trailing("/")

    with %URI{scheme: scheme, host: host, port: port, path: nil, query: nil, fragment: nil} =
           uri <- URI.parse(trimmed),
         true <- scheme in ["http", "https"] or {:error, "use http:// or https://"},
         true <- is_nil(uri.userinfo) or {:error, "must not contain credentials"},
         true <- (is_binary(host) and host != "") or {:error, "needs a host"},
         host = String.downcase(host),
         :ok <- validate_host(host) do
      {:ok, format(scheme, host, port)}
    else
      {:error, reason} -> {:error, "#{inspect(entry)}: #{reason}"}
      _ -> {:error, "#{inspect(entry)}: must look like https://example.com (no path)"}
    end
  end

  # `*.` is allowed only as the whole first label, before at least two labels
  # (`*.example.com`, not `*.com`, `a*.example.com` or `*`).
  defp validate_host("*." <> rest) do
    cond do
      String.contains?(rest, "*") -> {:error, "only a leading *. wildcard is allowed"}
      length(String.split(rest, ".", trim: true)) < 2 -> {:error, "wildcard is too broad"}
      true -> :ok
    end
  end

  defp validate_host(host) do
    if String.contains?(host, "*"),
      do: {:error, "only a leading *. wildcard is allowed"},
      else: :ok
  end

  defp format(scheme, host, port) do
    # URI.parse drops the brackets of an IPv6 literal.
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    if port in [nil, @default_ports[scheme]],
      do: "#{scheme}://#{host}",
      else: "#{scheme}://#{host}:#{port}"
  end

  @doc """
  Whether the request `origin` (the `Origin` header) matches one of the
  normalized `allowed` entries.
  """
  def allowed?(origin, allowed) when is_binary(origin) and is_list(allowed) do
    case normalize(origin) do
      {:ok, "http" <> _ = normalized} ->
        if String.contains?(normalized, "*"),
          do: false,
          else: Enum.any?(allowed, &matches?(normalized, &1))

      _ ->
        false
    end
  end

  def allowed?(_origin, _allowed), do: false

  defp matches?(origin, origin), do: true

  defp matches?(origin, pattern) do
    with [scheme, "*." <> rest] <- String.split(pattern, "://", parts: 2),
         [o_scheme, o_rest] <- String.split(origin, "://", parts: 2),
         true <- scheme == o_scheme do
      {suffix, port} = split_port(rest)
      {o_host, o_port} = split_port(o_rest)
      port == o_port and String.ends_with?(o_host, "." <> suffix)
    else
      _ -> false
    end
  end

  defp split_port(host_port) do
    case String.split(host_port, ":", parts: 2) do
      [host, port] -> {host, port}
      [host] -> {host, nil}
    end
  end
end
