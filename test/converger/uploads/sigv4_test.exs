defmodule Converger.Uploads.Signers.SigV4Test do
  use ExUnit.Case, async: true

  alias Converger.Uploads.Signers.SigV4

  # Test vectors from the AWS documentation:
  # https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  # https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  # Public example credentials from the AWS docs, split so secret scanners
  # do not mistake them for real keys.
  @aws_doc_secret "wJalrXUtnFEMI/K7MDENG" <> "/bPxRfiCYEXAMPLEKEY"
  @aws_suite_secret "wJalrXUtnFEMI/K7MDENG" <> "+bPxRfiCYEXAMPLEKEY"

  @s3_creds [
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: @aws_doc_secret,
    region: "us-east-1",
    service: "s3",
    now: ~U[2013-05-24 00:00:00Z]
  ]

  defp auth_header(headers) do
    {_, value} = List.keyfind(headers, "authorization", 0)
    value
  end

  describe "S3 header-based auth (AWS published examples)" do
    test "GET object with Range header" do
      headers =
        SigV4.sign_headers(
          "GET",
          "https://examplebucket.s3.amazonaws.com/test.txt",
          [{"Range", "bytes=0-9"}],
          {:hash, SigV4.empty_payload_hash()},
          @s3_creds
        )

      assert auth_header(headers) ==
               "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " <>
                 "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " <>
                 "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    end

    test "canonical request for GET object matches the documented one" do
      {canonical, signed} =
        SigV4.canonical_request(
          "GET",
          "/test.txt",
          nil,
          [
            {"host", "examplebucket.s3.amazonaws.com"},
            {"range", "bytes=0-9"},
            {"x-amz-content-sha256", SigV4.empty_payload_hash()},
            {"x-amz-date", "20130524T000000Z"}
          ],
          SigV4.empty_payload_hash()
        )

      assert signed == "host;range;x-amz-content-sha256;x-amz-date"

      assert canonical ==
               Enum.join(
                 [
                   "GET",
                   "/test.txt",
                   "",
                   "host:examplebucket.s3.amazonaws.com",
                   "range:bytes=0-9",
                   "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                   "x-amz-date:20130524T000000Z",
                   "",
                   "host;range;x-amz-content-sha256;x-amz-date",
                   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                 ],
                 "\n"
               )

      assert SigV4.sha256_hex(canonical) ==
               "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
    end

    test "PUT object with a body, Date and storage class headers" do
      headers =
        SigV4.sign_headers(
          "PUT",
          "https://examplebucket.s3.amazonaws.com/" <> SigV4.encode_key("test$file.text"),
          [
            {"Date", "Fri, 24 May 2013 00:00:00 GMT"},
            {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
          ],
          "Welcome to Amazon S3.",
          @s3_creds
        )

      assert auth_header(headers) =~
               "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, " <>
                 "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
    end
  end

  test "S3 presigned GET URL (AWS published example)" do
    url =
      SigV4.presign_url(
        "GET",
        "https://examplebucket.s3.amazonaws.com/test.txt",
        86_400,
        @s3_creds
      )

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert uri.host == "examplebucket.s3.amazonaws.com"
    assert params["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"

    assert params["X-Amz-Credential"] ==
             "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"

    assert params["X-Amz-Date"] == "20130524T000000Z"
    assert params["X-Amz-Expires"] == "86400"
    assert params["X-Amz-SignedHeaders"] == "host"

    assert params["X-Amz-Signature"] ==
             "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "signing key derivation (AWS published example)" do
    key =
      SigV4.signing_key(
        @aws_suite_secret,
        "20120215",
        "us-east-1",
        "iam"
      )

    assert Base.encode16(key, case: :lower) ==
             "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d"
  end

  test "get-vanilla from the AWS SigV4 test suite" do
    {canonical, _} =
      SigV4.canonical_request(
        "GET",
        "/",
        nil,
        [{"host", "example.amazonaws.com"}, {"x-amz-date", "20150830T123600Z"}],
        SigV4.empty_payload_hash()
      )

    flavor = %{algorithm: "AWS4-HMAC-SHA256"}

    sts =
      SigV4.string_to_sign(
        canonical,
        "20150830T123600Z",
        "20150830/us-east-1/service/aws4_request",
        flavor
      )

    key =
      SigV4.signing_key(
        @aws_suite_secret,
        "20150830",
        "us-east-1",
        "service"
      )

    signature = :crypto.mac(:hmac, :sha256, key, sts) |> Base.encode16(case: :lower)
    assert signature == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
  end

  test "canonical query strings are sorted and RFC 3986 encoded" do
    {canonical, _} =
      SigV4.canonical_request("GET", "/", "b=2&a=x y&c=%2F", [{"host", "h"}], "UNSIGNED-PAYLOAD")

    assert canonical |> String.split("\n") |> Enum.at(2) == "a=x%20y&b=2&c=%2F"
  end

  test "session tokens are signed into header and query auth" do
    opts = Keyword.put(@s3_creds, :session_token, "TOKEN/+=")

    headers = SigV4.sign_headers("GET", "https://b.s3.amazonaws.com/k", [], "", opts)
    assert {"x-amz-security-token", "TOKEN/+="} in headers
    assert auth_header(headers) =~ "x-amz-security-token"

    url = SigV4.presign_url("GET", "https://b.s3.amazonaws.com/k", 60, opts)
    assert URI.decode_query(URI.parse(url).query)["X-Amz-Security-Token"] == "TOKEN/+="
  end

  test "GOOG4 flavor uses Google prefixes" do
    opts = [
      access_key_id: "GOOGEXAMPLEACCESSID",
      secret_access_key: "secret",
      region: "auto",
      service: "storage",
      flavor: :goog,
      now: ~U[2026-10-08 12:00:00Z]
    ]

    headers =
      SigV4.sign_headers("PUT", "https://storage.googleapis.com/bucket/obj", [], "data", opts)

    assert {"x-goog-date", "20261008T120000Z"} in headers
    assert List.keymember?(headers, "x-goog-content-sha256", 0)

    assert auth_header(headers) =~
             "GOOG4-HMAC-SHA256 Credential=GOOGEXAMPLEACCESSID/20261008/auto/storage/goog4_request"

    url = SigV4.presign_url("GET", "https://storage.googleapis.com/bucket/obj", 300, opts)
    params = URI.decode_query(URI.parse(url).query)
    assert params["X-Goog-Algorithm"] == "GOOG4-HMAC-SHA256"
    assert params["X-Goog-Signature"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "non-default ports are part of the host header" do
    headers =
      SigV4.sign_headers("GET", "http://localhost:9000/bucket/key", [], "", @s3_creds)

    assert {"host", "localhost:9000"} in headers
  end
end
