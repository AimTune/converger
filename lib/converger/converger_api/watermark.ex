defmodule Converger.ConvergerAPI.Watermark do
  @moduledoc """
  Encodes and decodes opaque watermark strings for Converger activity pagination.

  A watermark is the position of the last activity a client has received:
  the activity's per-conversation `seq`, encoded opaquely. Resuming from a
  watermark needs no database lookup.

  Legacy watermarks (Base64-encoded activity ids, issued before `seq`
  existed) are still accepted for one release and decode to
  `{:activity_id, id}`.
  """

  @prefix "seq:"

  def encode(nil), do: nil

  def encode(seq) when is_integer(seq) and seq >= 0 do
    Base.url_encode64(@prefix <> Integer.to_string(seq), padding: false)
  end

  @doc """
  Decode a watermark.

  Returns `{:ok, nil}` for no watermark, `{:ok, {:seq, n}}`,
  `{:ok, {:activity_id, id}}` for legacy watermarks, or `{:error, :invalid_watermark}`.
  """
  def decode(nil), do: {:ok, nil}
  def decode(""), do: {:ok, nil}

  def decode(watermark) when is_binary(watermark) do
    case Base.url_decode64(watermark, padding: false) do
      {:ok, decoded} -> decode_position(decoded)
      :error -> {:error, :invalid_watermark}
    end
  end

  def decode(_), do: {:error, :invalid_watermark}

  defp decode_position(@prefix <> digits) do
    case Integer.parse(digits) do
      {seq, ""} when seq >= 0 -> {:ok, {:seq, seq}}
      _ -> {:error, :invalid_watermark}
    end
  end

  defp decode_position(legacy_activity_id) do
    case Ecto.UUID.cast(legacy_activity_id) do
      {:ok, id} -> {:ok, {:activity_id, id}}
      :error -> {:error, :invalid_watermark}
    end
  end
end
