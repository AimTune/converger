defmodule Converger.Uploads.Signers.AzureTest do
  use ExUnit.Case, async: true

  alias Converger.Uploads.Signers.Azure

  # Azurite's well-known development account key (public, documented).
  @account "devstoreaccount1"
  @key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

  defp hmac(sts),
    do: :crypto.mac(:hmac, :sha256, Base.decode64!(@key), sts) |> Base.encode64()

  describe "Shared Key" do
    test "string-to-sign follows the documented Blob service layout" do
      sts =
        Azure.shared_key_string_to_sign(
          "PUT",
          "https://myaccount.blob.core.windows.net/mycontainer/tenant/blob.txt",
          [
            {"Content-Length", "11"},
            {"Content-Type", "text/plain"},
            {"x-ms-blob-type", "BlockBlob"},
            {"x-ms-date", "Fri, 26 Jun 2015 23:39:12 GMT"},
            {"x-ms-version", "2021-12-02"}
          ],
          "myaccount"
        )

      assert sts ==
               Enum.join(
                 [
                   "PUT",
                   # Content-Encoding, Content-Language
                   "",
                   "",
                   "11",
                   # Content-MD5
                   "",
                   "text/plain",
                   # Date, If-Modified-Since, If-Match, If-None-Match,
                   # If-Unmodified-Since, Range
                   "",
                   "",
                   "",
                   "",
                   "",
                   "",
                   "x-ms-blob-type:BlockBlob",
                   "x-ms-date:Fri, 26 Jun 2015 23:39:12 GMT",
                   "x-ms-version:2021-12-02",
                   "/myaccount/mycontainer/tenant/blob.txt"
                 ],
                 "\n"
               )
    end

    test "zero content-length is signed as empty and query params are canonicalized" do
      sts =
        Azure.shared_key_string_to_sign(
          "GET",
          "https://myaccount.blob.core.windows.net/mycontainer?restype=container&comp=list&include=snapshots&include=metadata",
          [{"content-length", "0"}, {"x-ms-date", "d"}, {"x-ms-version", "v"}],
          "myaccount"
        )

      lines = String.split(sts, "\n")
      assert Enum.at(lines, 3) == ""

      assert Enum.take(lines, -4) == [
               "/myaccount/mycontainer",
               "comp:list",
               "include:metadata,snapshots",
               "restype:container"
             ]
    end

    test "emulator style URLs include the account name twice" do
      sts =
        Azure.shared_key_string_to_sign(
          "GET",
          "http://127.0.0.1:10000/devstoreaccount1/c/k",
          [],
          @account
        )

      assert String.ends_with?(sts, "\n/devstoreaccount1/devstoreaccount1/c/k")
    end

    test "authorization header is HMAC-SHA256 of the string-to-sign with the decoded key" do
      now = ~U[2015-06-26 23:39:12Z]
      url = "https://myaccount.blob.core.windows.net/c/k"

      headers =
        Azure.shared_key_headers("DELETE", url, [], "myaccount", @key, now: now)

      assert {"x-ms-date", "Fri, 26 Jun 2015 23:39:12 GMT"} in headers
      assert {"x-ms-version", "2021-12-02"} in headers

      expected = hmac(Azure.shared_key_string_to_sign("DELETE", url, headers, "myaccount"))
      assert {"authorization", "SharedKey myaccount:" <> expected} in headers
    end
  end

  describe "Service SAS" do
    test "string-to-sign follows the documented 2020-12-06 layout" do
      fields = %{
        sp: "r",
        st: "",
        se: "2026-10-08T12:05:00Z",
        spr: "https",
        sv: "2020-12-06",
        sr: "b",
        rscd: "inline",
        rsct: "image/png"
      }

      assert Azure.sas_string_to_sign(fields, "myaccount", "c", "t/k") ==
               "r\n\n2026-10-08T12:05:00Z\n/blob/myaccount/c/t/k\n\n\nhttps\n2020-12-06\nb\n\n\n\ninline\n\n\nimage/png"
    end

    test "query string carries the signature of the string-to-sign" do
      query =
        Azure.service_sas(
          account: "myaccount",
          account_key: @key,
          container: "c",
          blob: "t/k",
          expires_in: 300,
          content_type: "image/png",
          now: ~U[2026-10-08 12:00:00Z]
        )

      params = URI.decode_query(query)
      assert params["sv"] == "2020-12-06"
      assert params["sr"] == "b"
      assert params["sp"] == "r"
      assert params["se"] == "2026-10-08T12:05:00Z"
      assert params["spr"] == "https"
      assert params["rsct"] == "image/png"
      refute Map.has_key?(params, "st")

      fields = %{
        sp: "r",
        st: "",
        se: "2026-10-08T12:05:00Z",
        spr: "https",
        sv: "2020-12-06",
        sr: "b",
        rscd: "",
        rsct: "image/png"
      }

      assert params["sig"] == hmac(Azure.sas_string_to_sign(fields, "myaccount", "c", "t/k"))
    end
  end
end
