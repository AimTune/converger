defmodule Converger.Uploads.StorageBackendsTest do
  use ExUnit.Case, async: true

  alias Converger.Uploads.{AzureBlobStorage, GCSStorage, LocalStorage, S3Storage}

  # Captures each request the backend makes and replies with `status`.
  defp stub(name, status \\ 200, body \\ "") do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, req_body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:request, conn.method, conn.host, conn.request_path, conn.query_string,
         Map.new(conn.req_headers), req_body}
      )

      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  describe "S3Storage" do
    @s3 [
      bucket: "converger",
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "secret",
      region: "eu-west-1",
      req_options: [plug: {Req.Test, __MODULE__.S3}, retry: false]
    ]

    test "put signs a virtual-hosted request with the payload hash" do
      stub(__MODULE__.S3)
      assert :ok = S3Storage.put(@s3, "t1/a1", "hello", content_type: "text/plain")

      assert_received {:request, "PUT", "converger.s3.eu-west-1.amazonaws.com", "/t1/a1", "",
                       headers, "hello"}

      assert headers["content-type"] == "text/plain"

      assert headers["x-amz-content-sha256"] ==
               :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)

      assert headers["authorization"] =~
               ~r|^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/\d{8}/eu-west-1/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]{64}$|
    end

    test "path-style endpoint (MinIO / R2) and get / delete" do
      config = Keyword.merge(@s3, endpoint: "http://minio.local:9000", path_style: true)

      stub(__MODULE__.S3, 200, "bytes")
      assert {:ok, "bytes"} = S3Storage.get(config, "t1/a1")
      assert_received {:request, "GET", "minio.local", "/converger/t1/a1", _, headers, _}
      assert headers["host"] == "minio.local:9000"

      stub(__MODULE__.S3, 204)
      assert :ok = S3Storage.delete(config, "t1/a1")
      assert_received {:request, "DELETE", _, "/converger/t1/a1", _, _, _}
    end

    test "missing objects" do
      stub(__MODULE__.S3, 404)
      assert {:error, :not_found} = S3Storage.get(@s3, "nope")
      assert :ok = S3Storage.delete(@s3, "nope")
    end

    test "errors are returned" do
      stub(__MODULE__.S3, 403, "<Error/>")
      assert {:error, {:http_error, 403, "<Error/>"}} = S3Storage.put(@s3, "k", "x", [])
    end

    test "signed GET and presigned PUT URLs" do
      {:ok, url} =
        S3Storage.signed_get_url(@s3, "t1/a1", expires_in: 120, content_type: "image/png")

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)
      assert uri.host == "converger.s3.eu-west-1.amazonaws.com"
      assert params["X-Amz-Expires"] == "120"
      assert params["response-content-type"] == "image/png"
      assert params["X-Amz-Signature"] =~ ~r/^[0-9a-f]{64}$/

      {:ok, %{method: "PUT", url: put_url, headers: headers}} =
        S3Storage.presigned_put_url(@s3, "t1/a2", content_type: "video/mp4")

      assert URI.decode_query(URI.parse(put_url).query)["X-Amz-Expires"] == "900"
      assert headers == %{"content-type" => "video/mp4"}
    end
  end

  describe "GCSStorage" do
    @gcs [
      bucket: "converger",
      access_key_id: "GOOGHMAC",
      secret_access_key: "secret",
      req_options: [plug: {Req.Test, __MODULE__.GCS}, retry: false]
    ]

    test "put uses the XML API with GOOG4-HMAC-SHA256" do
      stub(__MODULE__.GCS)
      assert :ok = GCSStorage.put(@gcs, "t1/a1", "data", content_type: "image/png")

      assert_received {:request, "PUT", "storage.googleapis.com", "/converger/t1/a1", _, headers,
                       "data"}

      assert headers["x-goog-date"]

      assert headers["authorization"] =~
               ~r|^GOOG4-HMAC-SHA256 Credential=GOOGHMAC/\d{8}/auto/storage/goog4_request, |
    end

    test "signed URL uses X-Goog parameters" do
      {:ok, url} = GCSStorage.signed_get_url(@gcs, "t1/a1", expires_in: 60)
      assert url =~ "https://storage.googleapis.com/converger/t1/a1?"
      params = URI.decode_query(URI.parse(url).query)
      assert params["X-Goog-Algorithm"] == "GOOG4-HMAC-SHA256"
      assert params["X-Goog-Credential"] =~ ~r|^GOOGHMAC/\d{8}/auto/storage/goog4_request$|
    end
  end

  describe "AzureBlobStorage" do
    @azure [
      account: "myaccount",
      account_key: Base.encode64("0123456789abcdef0123456789abcdef"),
      container: "uploads",
      req_options: [plug: {Req.Test, __MODULE__.Azure}, retry: false]
    ]

    test "put sends a Shared Key signed BlockBlob upload" do
      stub(__MODULE__.Azure, 201)
      assert :ok = AzureBlobStorage.put(@azure, "t1/a1", "hello", content_type: "text/plain")

      assert_received {:request, "PUT", "myaccount.blob.core.windows.net", "/uploads/t1/a1", _,
                       headers, "hello"}

      assert headers["x-ms-blob-type"] == "BlockBlob"
      assert headers["x-ms-version"]
      assert headers["content-length"] == "5"
      assert headers["authorization"] =~ ~r{^SharedKey myaccount:[A-Za-z0-9+/=]+$}
    end

    test "get / delete / missing" do
      stub(__MODULE__.Azure, 200, "bytes")
      assert {:ok, "bytes"} = AzureBlobStorage.get(@azure, "t1/a1")

      stub(__MODULE__.Azure, 202)
      assert :ok = AzureBlobStorage.delete(@azure, "t1/a1")
      assert_received {:request, "DELETE", _, "/uploads/t1/a1", _, _, _}

      stub(__MODULE__.Azure, 404)
      assert {:error, :not_found} = AzureBlobStorage.get(@azure, "t1/a1")
      assert :ok = AzureBlobStorage.delete(@azure, "t1/a1")
    end

    test "signed URLs are SAS tokens" do
      {:ok, url} = AzureBlobStorage.signed_get_url(@azure, "t1/a1", expires_in: 60)
      params = URI.decode_query(URI.parse(url).query)
      assert String.starts_with?(url, "https://myaccount.blob.core.windows.net/uploads/t1/a1?")
      assert params["sp"] == "r"
      assert params["sr"] == "b"
      assert params["sig"]

      {:ok, %{url: put_url, headers: headers}} =
        AzureBlobStorage.presigned_put_url(@azure, "t1/a2")

      assert URI.decode_query(URI.parse(put_url).query)["sp"] == "cw"
      assert headers["x-ms-blob-type"] == "BlockBlob"
    end
  end

  describe "LocalStorage" do
    setup do
      dir = Path.join(System.tmp_dir!(), "converger_local_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, config: [dir: dir]}
    end

    test "round trip", %{config: config} do
      assert :ok = LocalStorage.put(config, "t1/a1", "bytes", [])
      assert {:ok, "bytes"} = LocalStorage.get(config, "t1/a1")
      assert {:ok, path} = LocalStorage.local_path(config, "t1/a1")
      assert File.read!(path) == "bytes"
      assert :ok = LocalStorage.delete(config, "t1/a1")
      assert {:error, :not_found} = LocalStorage.get(config, "t1/a1")
      assert :ok = LocalStorage.delete(config, "t1/a1")
      assert {:error, :unsupported} = LocalStorage.signed_get_url(config, "t1/a1", [])
    end

    test "refuses keys escaping the base dir", %{config: config} do
      assert {:error, :invalid_key} = LocalStorage.put(config, "../evil", "x", [])
      assert {:error, :invalid_key} = LocalStorage.get(config, "/etc/passwd")
    end
  end
end
