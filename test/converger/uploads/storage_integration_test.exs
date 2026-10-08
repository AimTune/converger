defmodule Converger.Uploads.StorageIntegrationTest do
  @moduledoc """
  Live tests against storage emulators. Excluded by default; run with

      mix test --only minio      # MINIO_ENDPOINT, default http://localhost:9000
      mix test --only azurite    # AZURITE_ENDPOINT, default http://127.0.0.1:10000/devstoreaccount1

  CI starts both as service containers (.github/workflows/ci.yml).
  """
  use Converger.DataCase, async: false

  alias Converger.Uploads.{AzureBlobStorage, S3Storage}
  alias Converger.Uploads.Signers.{Azure, SigV4}

  @payload "hello from converger " <> :binary.copy("x", 2048)

  defp key, do: "it-#{System.unique_integer([:positive])}/#{Ecto.UUID.generate()}"

  describe "S3Storage against MinIO" do
    @describetag :minio

    setup do
      config = [
        endpoint: System.get_env("MINIO_ENDPOINT", "http://localhost:9000"),
        path_style: true,
        region: "us-east-1",
        bucket: "converger-test",
        access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
        secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin")
      ]

      ensure_bucket(config)
      {:ok, config: config}
    end

    test "put, get, delete", %{config: config} do
      key = key()
      assert :ok = S3Storage.put(config, key, @payload, content_type: "text/plain")
      assert {:ok, @payload} = S3Storage.get(config, key)
      assert :ok = S3Storage.delete(config, key)
      assert {:error, :not_found} = S3Storage.get(config, key)
      assert :ok = S3Storage.delete(config, key)
    end

    test "signed GET URL is fetchable without credentials and honours overrides", %{
      config: config
    } do
      key = key()
      :ok = S3Storage.put(config, key, @payload, content_type: "application/octet-stream")

      {:ok, url} =
        S3Storage.signed_get_url(config, key,
          expires_in: 60,
          content_type: "text/plain",
          content_disposition: ~s(attachment; filename="a.txt")
        )

      resp = Req.get!(url, retry: false, decode_body: false)
      assert resp.status == 200
      assert resp.body == @payload
      assert Req.Response.get_header(resp, "content-type") == ["text/plain"]

      # Tampering with the signature is rejected
      bad =
        String.replace(
          url,
          ~r/X-Amz-Signature=[0-9a-f]+/,
          "X-Amz-Signature=" <> String.duplicate("0", 64)
        )

      assert Req.get!(bad, retry: false).status == 403
    end

    test "attachment created through the context is downloadable via its redirect", %{
      config: config
    } do
      original = Application.get_env(:converger, Converger.Uploads)

      Application.put_env(
        :converger,
        Converger.Uploads,
        Keyword.merge(original, storage: S3Storage, storage_opts: config)
      )

      on_exit(fn -> Application.put_env(:converger, Converger.Uploads, original) end)

      tenant = Converger.TenantsFixtures.tenant_fixture()
      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<1>>, 128)

      {:ok, attachment} = Converger.Uploads.create_attachment(tenant.id, {"pic.png", png})
      assert {:redirect, url} = Converger.Uploads.download(attachment)

      resp = Req.get!(url, retry: false, decode_body: false)
      assert resp.status == 200
      assert resp.body == png
      assert Req.Response.get_header(resp, "content-type") == ["image/png"]

      assert {:ok, _} = Converger.Uploads.delete_attachment(attachment)
      assert {:error, :not_found} = S3Storage.get(config, attachment.storage_key)
    end

    test "presigned PUT uploads directly", %{config: config} do
      key = key()

      {:ok, %{method: "PUT", url: url, headers: headers}} =
        S3Storage.presigned_put_url(config, key, content_type: "text/plain")

      assert Req.put!(url, body: @payload, headers: headers, retry: false).status == 200
      assert {:ok, @payload} = S3Storage.get(config, key)
    end
  end

  describe "AzureBlobStorage against Azurite" do
    @describetag :azurite

    setup do
      config = [
        endpoint: System.get_env("AZURITE_ENDPOINT", "http://127.0.0.1:10000/devstoreaccount1"),
        account: "devstoreaccount1",
        # Azurite's well-known development key
        account_key:
          "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==",
        container: "converger-test"
      ]

      ensure_container(config)
      {:ok, config: config}
    end

    test "put, get, delete with Shared Key", %{config: config} do
      key = key()
      assert :ok = AzureBlobStorage.put(config, key, @payload, content_type: "text/plain")
      assert {:ok, @payload} = AzureBlobStorage.get(config, key)
      assert :ok = AzureBlobStorage.delete(config, key)
      assert {:error, :not_found} = AzureBlobStorage.get(config, key)
    end

    test "SAS GET and PUT URLs work", %{config: config} do
      key = key()

      {:ok, %{url: put_url, headers: headers}} =
        AzureBlobStorage.presigned_put_url(config, key, content_type: "text/plain")

      assert Req.put!(put_url, body: @payload, headers: headers, retry: false).status == 201

      {:ok, url} =
        AzureBlobStorage.signed_get_url(config, key, expires_in: 60, content_type: "text/plain")

      resp = Req.get!(url, retry: false, decode_body: false)
      assert resp.status == 200
      assert resp.body == @payload

      bad = String.replace(url, ~r/sig=[^&]+/, "sig=AAAA")
      assert Req.get!(bad, retry: false).status == 403
    end
  end

  defp ensure_bucket(config) do
    url = "#{config[:endpoint]}/#{config[:bucket]}"

    headers =
      SigV4.sign_headers("PUT", url, [], "",
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key],
        region: config[:region]
      )

    %{status: status} = Req.put!(url, headers: headers, body: "", retry: false)
    # 409 = BucketAlreadyOwnedByYou
    assert status in [200, 409]
  end

  defp ensure_container(config) do
    url = "#{config[:endpoint]}/#{config[:container]}?restype=container"

    headers =
      Azure.shared_key_headers(
        "PUT",
        url,
        [{"content-length", "0"}],
        config[:account],
        config[:account_key]
      )

    %{status: status} = Req.put!(url, headers: headers, body: "", retry: false)
    # 409 = ContainerAlreadyExists
    assert status in [201, 409]
  end
end
