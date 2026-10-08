defmodule Converger.Uploads.MimeSniffer do
  @moduledoc """
  Detects a file's MIME type from its leading bytes (magic numbers). The
  client supplied content type is never trusted.

  Recognised: PNG, JPEG, GIF, WebP, BMP, PDF, MP4/MOV/M4A (ISO BMFF),
  WebM/Matroska, MP3, OGG, WAV, ZIP and Office Open XML (docx/xlsx/pptx).
  Anything else that is valid UTF-8 without NUL bytes is `text/plain`,
  otherwise `application/octet-stream`.
  """

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @pptx "application/vnd.openxmlformats-officedocument.presentationml.presentation"

  @text_sample 8192

  @spec sniff(binary()) :: String.t()
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<"GIF87a", _::binary>>), do: "image/gif"
  def sniff(<<"GIF89a", _::binary>>), do: "image/gif"
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>), do: "audio/wav"

  def sniff(<<"BM", _::binary-size(12), dib, 0, 0, 0, _::binary>>) when dib in [12, 40, 108, 124],
    do: "image/bmp"

  def sniff(<<"%PDF-", _::binary>>), do: "application/pdf"
  def sniff(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>), do: ftyp(brand)
  def sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  def sniff(<<"OggS", _::binary>>), do: "audio/ogg"
  def sniff(<<"ID3", _::binary>>), do: "audio/mpeg"

  # MPEG audio frame sync (MPEG-1/2/2.5 Layer III, no ID3 tag)
  def sniff(<<0xFF, b, _::binary>>) when b in [0xFB, 0xFA, 0xF3, 0xF2, 0xE3, 0xE2],
    do: "audio/mpeg"

  # AAC ADTS
  def sniff(<<0xFF, b, _::binary>>) when b in [0xF1, 0xF9], do: "audio/aac"

  def sniff(<<"PK", 3, 4, _::binary>> = bin), do: zip(bin)
  def sniff(bin) when is_binary(bin), do: text_or_binary(bin)

  defp ftyp("qt  "), do: "video/quicktime"
  defp ftyp("M4A "), do: "audio/mp4"
  defp ftyp("M4B "), do: "audio/mp4"
  defp ftyp(<<"3g", _::binary>>), do: "video/3gpp"
  defp ftyp(_), do: "video/mp4"

  # Office Open XML files are zip archives whose entries live under
  # word/, xl/ or ppt/. Entry names appear in the local file headers.
  defp zip(bin) do
    cond do
      :binary.match(bin, "word/") != :nomatch -> @docx
      :binary.match(bin, "xl/") != :nomatch -> @xlsx
      :binary.match(bin, "ppt/") != :nomatch -> @pptx
      true -> "application/zip"
    end
  end

  defp text_or_binary(""), do: "application/octet-stream"

  defp text_or_binary(bin) do
    sample = binary_part(bin, 0, min(byte_size(bin), @text_sample))

    if not String.contains?(sample, <<0>>) and valid_utf8_prefix?(sample, byte_size(bin)) do
      "text/plain"
    else
      "application/octet-stream"
    end
  end

  # A sample cut in the middle of a multi-byte character is still text.
  defp valid_utf8_prefix?(sample, total) do
    String.valid?(sample) or
      (byte_size(sample) < total and
         Enum.any?(1..3, fn n ->
           byte_size(sample) > n and
             String.valid?(binary_part(sample, 0, byte_size(sample) - n))
         end))
  end
end
