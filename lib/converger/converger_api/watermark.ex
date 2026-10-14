defmodule Converger.ConvergerAPI.Watermark do
  @moduledoc """
  The pre-v1 opaque watermark: URL-safe Base64 of `seq:<n>`.

  Since #63 the watermark is the integer `seq` itself (docs/protocol/v1.md
  section 6.5): the Converger REST API, the tenant API and every Protocol v1
  surface emit the number. Only the legacy Phoenix `activitySet` (and its
  `postActivity` reply and `replay_unavailable` error) still emits the
  opaque string from `encode/1`, for one release; every input accepts all
  forms through `ConvergerWeb.Protocol.parse_watermark/2`.

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
