defmodule Converger.Uploads.MimeSnifferTest do
  use ExUnit.Case, async: true

  alias Converger.Uploads.MimeSniffer

  @cases [
    {<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13>>, "image/png"},
    {<<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>, "image/jpeg"},
    {"GIF89a" <> <<1, 0, 1, 0>>, "image/gif"},
    {"GIF87a" <> <<1, 0, 1, 0>>, "image/gif"},
    {"RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ", "image/webp"},
    {"RIFF" <> <<0, 0, 0, 0>> <> "WAVEfmt ", "audio/wav"},
    {"%PDF-1.7\n%...", "application/pdf"},
    {<<0, 0, 0, 0x20, "ftypisom", 0, 0, 2, 0>>, "video/mp4"},
    {<<0, 0, 0, 0x20, "ftypmp42", 0, 0, 0, 0>>, "video/mp4"},
    {<<0, 0, 0, 0x14, "ftypqt  ", 0, 0, 0, 0>>, "video/quicktime"},
    {<<0, 0, 0, 0x20, "ftypM4A ", 0, 0, 0, 0>>, "audio/mp4"},
    {<<0x1A, 0x45, 0xDF, 0xA3, 0x9F>>, "video/webm"},
    {"OggS" <> <<0, 2>>, "audio/ogg"},
    {"ID3" <> <<4, 0, 0>>, "audio/mpeg"},
    {<<0xFF, 0xFB, 0x90, 0x64>>, "audio/mpeg"},
    {<<0xFF, 0xF1, 0x50, 0x80>>, "audio/aac"},
    {"PK" <> <<3, 4>> <> "....[Content_Types].xml....word/document.xml",
     "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    {"PK" <> <<3, 4>> <> "....xl/workbook.xml",
     "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    {"PK" <> <<3, 4>> <> "....ppt/presentation.xml",
     "application/vnd.openxmlformats-officedocument.presentationml.presentation"},
    {"PK" <> <<3, 4>> <> "....readme.txt", "application/zip"},
    {"hello world\nçok güzel", "text/plain"},
    {~s{<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>}, "text/plain"},
    {<<0, 1, 2, 3, 255>>, "application/octet-stream"},
    {"", "application/octet-stream"}
  ]

  for {{bytes, expected}, i} <- Enum.with_index(@cases) do
    test "sniffs ##{i} as #{expected}" do
      assert MimeSniffer.sniff(unquote(bytes)) == unquote(expected)
    end
  end

  test "text cut mid-character at the sample boundary is still text" do
    text = String.duplicate("a", 8191) <> "ü" <> "more"
    assert MimeSniffer.sniff(text) == "text/plain"
  end

  test "invalid UTF-8 is binary" do
    assert MimeSniffer.sniff("abc" <> <<0xC3, 0x28>> <> "def") == "application/octet-stream"
  end
end
