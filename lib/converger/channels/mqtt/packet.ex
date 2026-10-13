defmodule Converger.Channels.Mqtt.Packet do
  @moduledoc """
  Encoder and decoder of the MQTT 3.1.1 control packets the `mqtt` channel
  uses (OASIS MQTT 3.1.1, sections 2 and 3): `CONNECT` / `CONNACK`,
  `PUBLISH` (QoS 0 and 1) / `PUBACK`, `SUBSCRIBE` / `SUBACK`, `PINGREQ` /
  `PINGRESP` and `DISCONNECT`.

  Converger subscribes with at most QoS 1, so the QoS 2 packets (`PUBREC`,
  `PUBREL`, `PUBCOMP`) never arrive from a conforming broker and are not
  supported. See `Converger.Channels.Mqtt.Connection` and ADR-0055 for why
  Converger carries its own client instead of a Hex package.
  """

  import Bitwise

  @connect 1
  @connack 2
  @publish 3
  @puback 4
  @subscribe 8
  @suback 9
  @pingreq 12
  @pingresp 13
  @disconnect 14

  # Remaining length is at most four 7-bit groups (MQTT 3.1.1, 2.2.3).
  @max_remaining_length 268_435_455
  @max_string_bytes 65_535

  @type qos :: 0 | 1

  @type packet ::
          %{type: :connack, session_present: boolean(), return_code: 0..255}
          | %{
              type: :publish,
              topic: String.t(),
              payload: binary(),
              qos: qos(),
              packet_id: pos_integer() | nil,
              dup: boolean(),
              retain: boolean()
            }
          | %{type: :puback, packet_id: pos_integer()}
          | %{type: :suback, packet_id: pos_integer(), return_codes: [0..255]}
          | %{type: :pingresp}

  ## Encoding

  @doc """
  A `CONNECT` packet. Options: `:client_id` (required), `:clean_session`
  (default true), `:keepalive` (seconds, default 60), `:username`,
  `:password`.
  """
  @spec connect(keyword()) :: iodata()
  def connect(opts) do
    username = Keyword.get(opts, :username)
    password = Keyword.get(opts, :password)
    clean? = Keyword.get(opts, :clean_session, true)

    flags =
      if(present?(username), do: 0x80, else: 0) |||
        if(present?(username) and is_binary(password), do: 0x40, else: 0) |||
        if clean?, do: 0x02, else: 0

    variable = [string("MQTT"), 4, flags, <<Keyword.get(opts, :keepalive, 60)::16>>]

    payload =
      [string(Keyword.fetch!(opts, :client_id))] ++
        if(present?(username), do: [string(username)], else: []) ++
        if present?(username) and is_binary(password), do: [string(password)], else: []

    fixed(@connect, 0, [variable | payload])
  end

  @doc "A `PUBLISH` packet. `packet_id` is required for QoS 1."
  @spec publish(String.t(), binary(), qos(), pos_integer() | nil, keyword()) :: iodata()
  def publish(topic, payload, qos, packet_id, opts \\ []) do
    dup = if Keyword.get(opts, :dup, false), do: 0x08, else: 0
    retain = if Keyword.get(opts, :retain, false), do: 0x01, else: 0
    id = if qos > 0, do: <<packet_id::16>>, else: <<>>
    fixed(@publish, dup ||| qos <<< 1 ||| retain, [string(topic), id, payload])
  end

  @doc "A `PUBACK` packet."
  @spec puback(pos_integer()) :: iodata()
  def puback(packet_id), do: fixed(@puback, 0, <<packet_id::16>>)

  @doc "A `SUBSCRIBE` packet for `[{filter, qos}]`."
  @spec subscribe(pos_integer(), [{String.t(), qos()}]) :: iodata()
  def subscribe(packet_id, filters) do
    fixed(@subscribe, 0b0010, [
      <<packet_id::16>>
      | Enum.map(filters, fn {filter, qos} -> [string(filter), qos] end)
    ])
  end

  @doc "A `PINGREQ` packet."
  def pingreq, do: <<@pingreq <<< 4, 0>>

  @doc "A `DISCONNECT` packet."
  def disconnect, do: <<@disconnect <<< 4, 0>>

  defp fixed(type, flags, body) do
    length = IO.iodata_length(body)

    if length > @max_remaining_length,
      do: raise(ArgumentError, "MQTT packet too large: #{length} bytes")

    [<<type <<< 4 ||| flags>>, remaining_length(length), body]
  end

  defp remaining_length(n) when n < 128, do: <<n>>
  defp remaining_length(n), do: [<<1::1, rem(n, 128)::7>>, remaining_length(div(n, 128))]

  defp string(value) do
    if byte_size(value) > @max_string_bytes,
      do: raise(ArgumentError, "MQTT string longer than #{@max_string_bytes} bytes")

    [<<byte_size(value)::16>>, value]
  end

  defp present?(value), do: is_binary(value) and value != ""

  ## Decoding

  @doc """
  Decode the first packet of `buffer`: `{:ok, packet, rest}`, `:more` when
  the buffer holds no complete packet yet, or `{:error, reason}` for a
  malformed or unsupported packet (the connection must be closed).
  """
  @spec decode(binary()) :: {:ok, packet(), binary()} | :more | {:error, term()}
  def decode(<<header, rest::binary>>) do
    case decode_length(rest, 0, 1) do
      {:ok, length, rest} when byte_size(rest) >= length ->
        <<body::binary-size(length), rest::binary>> = rest

        case decode_packet(header >>> 4, header &&& 0x0F, body) do
          {:ok, packet} -> {:ok, packet, rest}
          {:error, _} = error -> error
        end

      {:ok, _length, _rest} ->
        :more

      :more ->
        :more

      {:error, _} = error ->
        error
    end
  end

  def decode(<<>>), do: :more

  defp decode_length(<<1::1, value::7, rest::binary>>, acc, multiplier)
       when multiplier < 2_097_152,
       do: decode_length(rest, acc + value * multiplier, multiplier * 128)

  defp decode_length(<<1::1, _::7, _::binary>>, _acc, _multiplier),
    do: {:error, :malformed_remaining_length}

  defp decode_length(<<0::1, value::7, rest::binary>>, acc, multiplier),
    do: {:ok, acc + value * multiplier, rest}

  defp decode_length(<<>>, _acc, _multiplier), do: :more

  defp decode_packet(@connack, 0, <<_::7, session_present::1, code>>),
    do: {:ok, %{type: :connack, session_present: session_present == 1, return_code: code}}

  defp decode_packet(@publish, flags, body) do
    qos = flags >>> 1 &&& 0b11

    with true <- qos in [0, 1] || {:error, {:unsupported_qos, qos}},
         <<length::16, topic::binary-size(length), rest::binary>> <- body,
         {:ok, packet_id, payload} <- publish_id(qos, rest) do
      {:ok,
       %{
         type: :publish,
         topic: topic,
         payload: payload,
         qos: qos,
         packet_id: packet_id,
         dup: (flags &&& 0x08) != 0,
         retain: (flags &&& 0x01) != 0
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :malformed_publish}
    end
  end

  defp decode_packet(@puback, 0, <<packet_id::16>>),
    do: {:ok, %{type: :puback, packet_id: packet_id}}

  defp decode_packet(@suback, 0, <<packet_id::16, codes::binary>>) when codes != <<>>,
    do: {:ok, %{type: :suback, packet_id: packet_id, return_codes: :binary.bin_to_list(codes)}}

  defp decode_packet(@pingresp, 0, <<>>), do: {:ok, %{type: :pingresp}}

  defp decode_packet(type, _flags, _body), do: {:error, {:unexpected_packet, type}}

  defp publish_id(0, payload), do: {:ok, nil, payload}
  defp publish_id(1, <<id::16, payload::binary>>) when id > 0, do: {:ok, id, payload}
  defp publish_id(_qos, _rest), do: {:error, :malformed_publish}

  ## Topics

  @doc """
  Whether `filter` is a valid topic filter (MQTT 3.1.1, 4.7): non-empty,
  UTF-8 without NUL, at most 65535 bytes, `+` only as a whole level and `#`
  only as the whole last level.
  """
  @spec valid_filter?(term()) :: boolean()
  def valid_filter?(filter) do
    if valid_string?(filter) do
      levels = String.split(filter, "/")
      last = length(levels) - 1

      levels
      |> Enum.with_index()
      |> Enum.all?(fn {level, index} ->
        cond do
          level == "#" -> index == last
          level == "+" -> true
          true -> not String.contains?(level, ["+", "#"])
        end
      end)
    else
      false
    end
  end

  @doc "Whether `topic` is a valid topic name to publish to: like a filter, without wildcards."
  @spec valid_topic?(term()) :: boolean()
  def valid_topic?(topic), do: valid_string?(topic) and not String.contains?(topic, ["+", "#"])

  defp valid_string?(value) do
    is_binary(value) and value != "" and byte_size(value) <= @max_string_bytes and
      String.valid?(value) and not String.contains?(value, <<0>>)
  end

  @doc """
  Whether the topic name `topic` matches the topic filter `filter`. Topics
  starting with `$` are not matched by a leading wildcard (MQTT 3.1.1,
  4.7.2).
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(filter, topic) do
    if String.starts_with?(topic, "$") and String.starts_with?(filter, ["+", "#"]),
      do: false,
      else: match_levels(String.split(filter, "/"), String.split(topic, "/"))
  end

  defp match_levels(["#"], _topic), do: true
  defp match_levels(["+" | filter], [_ | topic]), do: match_levels(filter, topic)
  defp match_levels([level | filter], [level | topic]), do: match_levels(filter, topic)
  defp match_levels([], []), do: true
  defp match_levels(_filter, _topic), do: false
end
