defmodule ConvergerWeb.Protocol.Codec do
  @moduledoc """
  Wire encodings of Converger Protocol v1 frames and their negotiation through
  the WebSocket subprotocol (`Sec-WebSocket-Protocol`).

  | subprotocol | encoding | WebSocket messages |
  | --- | --- | --- |
  | `converger.v1` | JSON | text |
  | `converger.v1+json` | JSON (explicit alias) | text |
  | `converger.v1+msgpack` | MessagePack | binary |
  | none offered | JSON (mekik/1 clients) | text |

  The server selects the first offered subprotocol it supports, so a client
  lists them in order of preference. A client that offers only unsupported
  subprotocols is refused during the upgrade.

  The frame maps are the same for every encoding (string keys, the shapes in
  docs/protocol/v1.md), so MessagePack is a pure re-encoding of the JSON frame.
  """

  @subprotocols %{
    "converger.v1" => :json,
    "converger.v1+json" => :json,
    "converger.v1+msgpack" => :msgpack
  }

  @type encoding :: :json | :msgpack

  @doc "Supported subprotocol names."
  def subprotocols, do: Map.keys(@subprotocols)

  @doc """
  Pick the subprotocol from the values of the `sec-websocket-protocol` request
  headers.

  Returns `{:ok, nil, :json}` when none was offered, `{:ok, name, encoding}`
  for the first supported one, or `{:error, :unsupported_subprotocol}`.
  """
  @spec negotiate([String.t()]) :: {:ok, String.t() | nil, encoding()} | {:error, atom()}
  def negotiate(header_values) do
    offered =
      header_values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case offered do
      [] ->
        {:ok, nil, :json}

      _ ->
        case Enum.find(offered, &Map.has_key?(@subprotocols, &1)) do
          nil -> {:error, :unsupported_subprotocol}
          name -> {:ok, name, Map.fetch!(@subprotocols, name)}
        end
    end
  end

  @doc "Encode a frame into a WebSock message for the session's encoding."
  @spec encode(map(), encoding()) :: {:text | :binary, iodata()}
  def encode(frame, :json), do: {:text, Jason.encode_to_iodata!(frame)}
  def encode(frame, :msgpack), do: {:binary, Msgpax.pack!(frame)}

  @doc """
  Decode an inbound WebSocket message. Text messages are JSON in every
  session; binary messages are MessagePack and only accepted when it was
  negotiated. A frame must decode to an object (map).
  """
  @spec decode(binary(), :text | :binary, encoding()) :: {:ok, map()} | {:error, String.t()}
  def decode(data, :text, _encoding) do
    case Jason.decode(data) do
      {:ok, frame} when is_map(frame) -> {:ok, frame}
      {:ok, _} -> {:error, "a frame must be a JSON object"}
      {:error, _} -> {:error, "malformed JSON"}
    end
  end

  def decode(data, :binary, :msgpack) do
    case Msgpax.unpack(data) do
      {:ok, frame} when is_map(frame) -> {:ok, stringify_keys(frame)}
      {:ok, _} -> {:error, "a frame must be a MessagePack map"}
      {:error, _} -> {:error, "malformed MessagePack"}
    end
  end

  def decode(_data, :binary, :json) do
    {:error, "binary messages need the converger.v1+msgpack subprotocol"}
  end

  # MessagePack map keys may be any type; frames use string keys only.
  defp stringify_keys(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_key(k), stringify_keys(v)} end)

  # MessagePack extension types (Msgpax.Ext) have no JSON equivalent.
  defp stringify_keys(struct) when is_struct(struct), do: nil
  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key), do: inspect(key)
end
