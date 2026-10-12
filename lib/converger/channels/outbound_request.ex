defmodule Converger.Channels.OutboundRequest do
  @moduledoc """
  Building blocks for outbound HTTP requests to tenant-chosen URLs, shared by
  the `webhook` channel adapter (ADR-0014) and platform event webhooks
  (`Converger.Webhooks`, ADR-0053):

    * pinning the connection to the address that passed
      `Converger.Channels.UrlGuard.resolve/1` (`pin/3`);
    * reading at most `max_bytes` of the response (`limited_body/1`);
    * user header rules: hop-by-hop headers, `host`, `content-length`,
      `content-type` and anything starting with `x-converger-` are reserved
      (`validate_headers/2`, `user_headers/1`).
  """

  @reserved_headers ~w(
    host content-length content-type connection keep-alive proxy-authenticate
    proxy-authorization proxy-connection te trailer trailers transfer-encoding upgrade
  )

  @doc """
  Req options that send the request to the checked IP of `target` (a
  `UrlGuard.resolve/1` result) while keeping the original host name for the
  `Host` header, TLS SNI and certificate checks.
  """
  def pin(options, target, connect_timeout) do
    options
    |> Keyword.put(:url, target_url(target))
    |> Keyword.put(:connect_options, connect_options(target, connect_timeout))
    |> maybe_inet6(target)
  end

  defp target_url(%{uri: uri, ip: nil}), do: URI.to_string(uri)

  defp target_url(%{uri: uri, ip: ip}),
    do: URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()})

  defp connect_options(%{ip: nil}, timeout), do: [timeout: timeout]
  defp connect_options(%{host: host}, timeout), do: [timeout: timeout, hostname: host]

  defp maybe_inet6(options, %{ip: ip}) when tuple_size(ip) == 8,
    do: Keyword.put(options, :inet6, true)

  defp maybe_inet6(options, _target), do: options

  @doc """
  A Req `:into` function that collects at most `max_bytes` of the response
  body; the rest is dropped and the connection is closed.
  """
  def limited_body(max_bytes) do
    fn {:data, data}, {req, resp} ->
      body = if is_binary(resp.body), do: resp.body, else: ""
      room = max_bytes - byte_size(body)

      if byte_size(data) > room do
        truncated = body <> binary_part(data, 0, max(room, 0))
        {:halt, {req, %{resp | body: truncated} |> Req.Response.put_private(:truncated, true)}}
      else
        {:cont, {req, %{resp | body: body <> data}}}
      end
    end
  end

  @doc """
  Validates a user header map: string names and values, no reserved header.
  `label` prefixes error messages (e.g. `"webhook config 'headers'"`).
  """
  def validate_headers(headers, label \\ "headers")

  def validate_headers(headers, _label) when headers in [nil, ""], do: :ok

  def validate_headers(headers, label) when is_map(headers) do
    cond do
      not Enum.all?(headers, fn {k, v} -> is_binary(k) and k != "" and is_binary(v) end) ->
        {:error, "#{label} must map header names to string values"}

      (reserved = Enum.filter(Map.keys(headers), &reserved_header?/1)) != [] ->
        {:error, "#{label} cannot set reserved headers: #{Enum.join(reserved, ", ")}"}

      true ->
        :ok
    end
  end

  def validate_headers(_headers, label), do: {:error, "#{label} must be a map"}

  @doc """
  The user headers that may be sent, as a list of `{lowercase name, value}`.
  Reserved or malformed entries (saved before validation existed) are dropped.
  """
  def user_headers(headers) when is_map(headers) do
    for {k, v} <- headers,
        is_binary(k) and is_binary(v),
        name = String.downcase(String.trim(k)),
        name != "" and not reserved_header?(name),
        do: {name, v}
  end

  def user_headers(_), do: []

  @doc "Whether a header name is reserved (set by Converger or the HTTP client)."
  def reserved_header?(name) do
    name = String.downcase(String.trim(name))
    name in @reserved_headers or String.starts_with?(name, "x-converger-")
  end
end
