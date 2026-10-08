defmodule Converger.Channels.Adapters.Webhook do
  @moduledoc """
  Generic HTTP webhook channel.

  ## Config

    * `url` (required) - `http` or `https` target. Private, loopback and
      link-local targets are rejected, see `Converger.Channels.UrlGuard`.
    * `method` - `POST` (default), `PUT` or `PATCH`.
    * `headers` - map of extra request headers (string values). Hop-by-hop
      headers, `host`, `content-length`, `content-type` and `x-converger-*`
      are reserved.
    * `connect_timeout` - TCP/TLS connect timeout in ms (default 5000, max 30000).
    * `receive_timeout` - response timeout in ms (default 10000, max 60000).
    * `max_response_bytes` - response bytes read (default 1 MB, max 10 MB);
      the rest of a larger response is discarded.

  Defaults can be changed with `config :converger, :webhook,
  connect_timeout: ..., receive_timeout: ..., max_response_bytes: ...`.

  ## Outbound requests

  The body is the canonical activity JSON (plus `timestamp`). Every request
  carries:

    * `x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(channel secret, "<t>.<body>")>`
    * `x-converger-event: activity.created`
    * `x-converger-delivery-id: <delivery id>` (stable across retries)

  Redirects are not followed; a `3xx` response is a failed delivery.
  See `docs/webhooks.md` for verification snippets.
  """

  @behaviour Converger.Channels.Adapter

  require Logger

  alias Converger.Channels.{InboundSignature, UrlGuard}

  @methods %{"POST" => :post, "PUT" => :put, "PATCH" => :patch}

  @event "activity.created"

  @reserved_headers ~w(
    host content-length content-type connection keep-alive proxy-authenticate
    proxy-authorization proxy-connection te trailer trailers transfer-encoding upgrade
  )

  @limits %{
    "connect_timeout" => {:connect_timeout, 5_000, 30_000},
    "receive_timeout" => {:receive_timeout, 10_000, 60_000},
    "max_response_bytes" => {:max_response_bytes, 1_048_576, 10_485_760}
  }

  @impl true
  def supported_modes, do: ~w(inbound outbound duplex)

  @impl true
  def validate_config(config) do
    with :ok <- validate_url(config["url"]),
         :ok <- validate_method(config["method"]),
         :ok <- validate_headers(config["headers"]) do
      validate_limits(config)
    end
  end

  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}

    with {:ok, method} <- fetch_method(config["method"]),
         {:ok, target} <- resolve_target(config["url"]) do
      body =
        activity
        |> Converger.Activities.Serializer.canonical()
        |> Map.put(:timestamp, activity.inserted_at)
        |> Jason.encode!()

      headers =
        user_headers(config["headers"]) ++
          [{"content-type", "application/json"}] ++
          converger_headers(channel, activity, body)

      max_bytes = limit(config, "max_response_bytes")

      req_options =
        [
          method: method,
          url: target_url(target),
          body: body,
          headers: headers,
          redirect: false,
          retry: false,
          decode_body: false,
          compressed: false,
          receive_timeout: limit(config, "receive_timeout"),
          connect_options: connect_options(target, limit(config, "connect_timeout")),
          into: limited_body(max_bytes)
        ]
        |> maybe_inet6(target)
        |> Keyword.merge(Application.get_env(:converger, :webhook_req_options, []))

      case Req.request(req_options) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "webhook returned status #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "webhook request failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def parse_inbound(_channel, params) do
    parsed = %{
      "sender" => params["sender"] || params["from"] || "external",
      "text" => params["text"] || params["message"] || params["body"],
      "type" => params["type"] || "message",
      "metadata" => params["metadata"] || %{},
      "attachments" => params["attachments"] || []
    }

    if empty_message?(parsed),
      do: {:error, :empty_inbound_message},
      else: {:ok, parsed}
  end

  @impl true
  def parse_status_update(_channel, params) do
    cond do
      is_binary(params["delivery_id"]) and is_binary(params["status"]) ->
        {:ok,
         [
           %{
             "delivery_id" => params["delivery_id"],
             "status" => params["status"],
             "timestamp" => params["timestamp"],
             "error" => params["error"]
           }
         ]}

      is_binary(params["provider_message_id"]) and is_binary(params["status"]) ->
        {:ok,
         [
           %{
             "provider_message_id" => params["provider_message_id"],
             "status" => params["status"],
             "timestamp" => params["timestamp"],
             "error" => params["error"]
           }
         ]}

      true ->
        :ignore
    end
  end

  ## Config validation

  defp validate_url(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] or is_nil(uri.host) or uri.host == "" ->
        {:error, "webhook config 'url' must be a valid HTTP/HTTPS URL"}

      true ->
        case UrlGuard.check(url) do
          :ok -> :ok
          {:error, message} -> {:error, "webhook config 'url' is not allowed: #{message}"}
        end
    end
  end

  defp validate_url(_), do: {:error, "webhook config requires a 'url' field"}

  defp validate_method(method) do
    case fetch_method(method) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp validate_headers(headers) when headers in [nil, ""], do: :ok

  defp validate_headers(headers) when is_map(headers) do
    cond do
      not Enum.all?(headers, fn {k, v} -> is_binary(k) and k != "" and is_binary(v) end) ->
        {:error, "webhook config 'headers' must map header names to string values"}

      (reserved = Enum.filter(Map.keys(headers), &reserved_header?/1)) != [] ->
        {:error,
         "webhook config 'headers' cannot set reserved headers: #{Enum.join(reserved, ", ")}"}

      true ->
        :ok
    end
  end

  defp validate_headers(_), do: {:error, "webhook config 'headers' must be a map"}

  defp validate_limits(config) do
    Enum.reduce_while(@limits, :ok, fn {key, {_name, _default, max}}, :ok ->
      case Map.fetch(config, key) do
        :error ->
          {:cont, :ok}

        {:ok, blank} when blank in [nil, ""] ->
          {:cont, :ok}

        {:ok, value} ->
          case to_positive_integer(value) do
            {:ok, int} when int <= max ->
              {:cont, :ok}

            _ ->
              {:halt,
               {:error, "webhook config '#{key}' must be a positive integer of at most #{max}"}}
          end
      end
    end)
  end

  ## Delivery helpers

  defp fetch_method(method) when method in [nil, ""], do: {:ok, :post}

  defp fetch_method(method) when is_binary(method) do
    case Map.fetch(@methods, method |> String.trim() |> String.upcase()) do
      {:ok, atom} -> {:ok, atom}
      :error -> method_error()
    end
  end

  defp fetch_method(_), do: method_error()

  defp method_error,
    do: {:error, "webhook config 'method' must be one of: #{Enum.join(Map.keys(@methods), ", ")}"}

  defp resolve_target(url) do
    case UrlGuard.resolve(url || "") do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, "webhook target rejected: #{UrlGuard.format_error(reason)}"}
    end
  end

  # Pin the request to the address that passed the SSRF check. The original
  # host name is kept for the Host header, TLS SNI and certificate checks.
  defp target_url(%{uri: uri, ip: nil}), do: URI.to_string(uri)

  defp target_url(%{uri: uri, ip: ip}),
    do: URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()})

  defp connect_options(%{ip: nil}, timeout), do: [timeout: timeout]
  defp connect_options(%{host: host}, timeout), do: [timeout: timeout, hostname: host]

  defp maybe_inet6(options, %{ip: ip}) when tuple_size(ip) == 8,
    do: Keyword.put(options, :inet6, true)

  defp maybe_inet6(options, _target), do: options

  defp user_headers(headers) when is_map(headers) do
    for {k, v} <- headers,
        is_binary(k) and is_binary(v),
        name = String.downcase(String.trim(k)),
        name != "" and not reserved_header?(name),
        do: {name, v}
  end

  defp user_headers(_), do: []

  defp reserved_header?(name) do
    name = String.downcase(String.trim(name))
    name in @reserved_headers or String.starts_with?(name, "x-converger-")
  end

  defp converger_headers(channel, activity, body) do
    signature =
      case channel_secret(channel) do
        nil -> []
        secret -> [{"x-converger-signature", InboundSignature.sign(secret, body)}]
      end

    delivery =
      case delivery_id(channel, activity) do
        nil -> []
        id -> [{"x-converger-delivery-id", id}]
      end

    [{"x-converger-event", @event}] ++ signature ++ delivery
  end

  defp channel_secret(%{secret: secret}) when is_binary(secret) and secret != "", do: secret
  defp channel_secret(_), do: nil

  defp delivery_id(%{id: channel_id}, %{id: activity_id})
       when is_binary(channel_id) and is_binary(activity_id) do
    case Converger.Deliveries.get_delivery_for_activity_and_channel(activity_id, channel_id) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp delivery_id(_channel, _activity), do: nil

  # Collects at most `max_bytes` of the response body; the rest is dropped
  # and the connection is closed.
  defp limited_body(max_bytes) do
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

  defp limit(config, key) do
    {name, default, max} = Map.fetch!(@limits, key)
    app_default = Keyword.get(Application.get_env(:converger, :webhook, []), name, default)

    case to_positive_integer(Map.get(config, key)) do
      {:ok, int} -> min(int, max)
      :error -> app_default
    end
  end

  defp to_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp to_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp to_positive_integer(_), do: :error

  defp empty_message?(%{"type" => "message", "text" => text, "attachments" => attachments}) do
    blank_text? = not is_binary(text) or String.trim(text) == ""
    blank_text? and attachments in [nil, []]
  end

  defp empty_message?(_), do: false
end
