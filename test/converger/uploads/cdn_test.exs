defmodule Converger.Uploads.CDNTest do
  use ExUnit.Case, async: true

  alias Converger.Uploads.CDN
  alias Converger.Uploads.Signers.CDN, as: Signer

  setup_all do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = private_key
    {:ok, pem: pem, public_key: {:RSAPublicKey, n, e}}
  end

  defp cf_decode(sig) do
    sig
    |> String.replace(["-", "_", "~"], fn
      "-" -> "+"
      "_" -> "="
      "~" -> "/"
    end)
    |> Base.decode64!()
  end

  describe "CloudFront" do
    test "canned policy has the exact documented shape" do
      assert Signer.cloudfront_canned_policy(
               "https://d111111abcdef8.cloudfront.net/a.png",
               1_357_034_400
             ) ==
               ~s({"Statement":[{"Resource":"https://d111111abcdef8.cloudfront.net/a.png","Condition":{"DateLessThan":{"AWS:EpochTime":1357034400}}}]})
    end

    test "signed URL carries Expires, Signature (RSA-SHA1 of the policy) and Key-Pair-Id",
         %{pem: pem, public_key: public_key} do
      url = "https://d111111abcdef8.cloudfront.net/tenant/file"
      signed = Signer.cloudfront_sign(url, 1_357_034_400, "K2JCJMDEHXQW5F", pem)

      assert String.starts_with?(signed, url <> "?Expires=1357034400&Signature=")
      params = URI.parse(signed).query |> URI.query_decoder() |> Map.new()
      assert params["Key-Pair-Id"] == "K2JCJMDEHXQW5F"
      refute params["Signature"] =~ ~r/[+=\/]/

      assert :public_key.verify(
               Signer.cloudfront_canned_policy(url, 1_357_034_400),
               :sha,
               cf_decode(params["Signature"]),
               public_key
             )
    end

    test "PKCS#8 keys are accepted", %{pem: pem, public_key: public_key} do
      [entry] = :public_key.pem_decode(pem)
      key = :public_key.pem_entry_decode(entry)
      pkcs8 = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])

      signed = Signer.cloudfront_sign("https://cdn/x", 1, "KID", pkcs8)

      sig =
        signed
        |> URI.parse()
        |> Map.get(:query)
        |> URI.query_decoder()
        |> Map.new()
        |> Map.get("Signature")

      assert :public_key.verify(
               Signer.cloudfront_canned_policy("https://cdn/x", 1),
               :sha,
               cf_decode(sig),
               public_key
             )
    end
  end

  describe "Google Cloud CDN" do
    test "signature is HMAC-SHA1 over url?Expires=..&KeyName=.., base64url encoded" do
      key = "nZtRohdNF9m3cKM24IcK4w=="
      url = "https://media.example.com/videos/id/main.m3u8?userID=abc123"
      signed = Signer.google_cdn_sign(url, 1_558_131_350, "my-key", key)

      to_sign = url <> "&Expires=1558131350&KeyName=my-key"
      expected = :crypto.mac(:hmac, :sha, Base.url_decode64!(key), to_sign) |> Base.url_encode64()

      assert signed == to_sign <> "&Signature=" <> expected
    end
  end

  describe "url/4" do
    test "no CDN configured" do
      assert CDN.url(nil, "k", 60) == :none
    end

    test "plain base URL with path prefix and encoded key" do
      cdn = [type: :plain, base_url: "https://files.example.com/", path_prefix: "/uploads/"]
      assert CDN.url(cdn, "t/a b", 60) == {:ok, "https://files.example.com/uploads/t/a%20b"}
    end

    test "plain with sign_origin appends the backend's signed query" do
      cdn = [type: :plain, base_url: "https://cdn.azureedge.net", sign_origin: true]

      assert CDN.url(cdn, "t/k", 60, fn -> "sv=x&sig=y" end) ==
               {:ok, "https://cdn.azureedge.net/t/k?sv=x&sig=y"}
    end

    test "cloudfront and google_cdn produce signed URLs", %{pem: pem} do
      {:ok, cf} =
        CDN.url(
          [
            type: :cloudfront,
            base_url: "https://d1.cloudfront.net",
            key_pair_id: "KID",
            private_key: pem
          ],
          "t/k",
          60
        )

      assert cf =~ ~r{^https://d1\.cloudfront\.net/t/k\?Expires=\d+&Signature=.+&Key-Pair-Id=KID$}

      {:ok, g} =
        CDN.url(
          [
            type: :google_cdn,
            base_url: "https://cdn.example.com",
            key_name: "k1",
            key: "nZtRohdNF9m3cKM24IcK4w=="
          ],
          "t/k",
          60
        )

      assert g =~ ~r{^https://cdn\.example\.com/t/k\?Expires=\d+&KeyName=k1&Signature=.+$}
    end
  end
end
