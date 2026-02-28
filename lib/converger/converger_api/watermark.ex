defmodule Converger.ConvergerAPI.Watermark do
  @moduledoc """
  Encodes and decodes opaque watermark strings for Converger activity pagination.

  Watermarks represent the position of the last activity a client has received.
  They are Base64-encoded activity IDs, opaque to clients.
  """

  def encode(nil), do: nil

  def encode(activity_id) when is_binary(activity_id) do
    Base.url_encode64(activity_id, padding: false)
  end

  def decode(nil), do: {:ok, nil}
  def decode(""), do: {:ok, nil}

  def decode(watermark) when is_binary(watermark) do
    case Base.url_decode64(watermark, padding: false) do
      {:ok, activity_id} -> {:ok, activity_id}
      :error -> {:error, :invalid_watermark}
    end
  end
end
