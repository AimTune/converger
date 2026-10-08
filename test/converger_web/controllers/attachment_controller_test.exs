defmodule ConvergerWeb.ConvergerAPI.AttachmentControllerTest do
  # Not async: some tests swap the global upload configuration.
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.ConvergerToken
  alias Converger.Uploads
  alias Converger.Uploads.Attachment

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, 64)

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {:ok, token, _} = ConvergerToken.generate_token(channel)
    {:ok, tenant: tenant, channel: channel, conversation: conversation, token: token}
  end

  defp upload_file(name, bytes) do
    path = Path.join(System.tmp_dir!(), "upload_#{System.unique_integer([:positive])}_#{name}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    # The client-declared content type is deliberately wrong.
    %Plug.Upload{path: path, filename: name, content_type: "application/x-anything"}
  end

  defp upload(conn, token, conversation_id, file, extra \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> post(
      ~p"/api/v1/converger/conversations/#{conversation_id}/upload",
      Map.merge(%{"file" => file}, extra)
    )
  end

  defp fetch(conn, token, url) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{token}")
    |> get(URI.parse(url).path)
  end

  defp with_upload_config(overrides) do
    original = Application.get_env(:converger, Uploads)
    Application.put_env(:converger, Uploads, Keyword.merge(original, overrides))
    on_exit(fn -> Application.put_env(:converger, Uploads, original) end)
  end

  describe "upload then download (local storage)" do
    test "contentUrl resolves with 200 and the original bytes", %{
      conn: conn,
      token: token,
      conversation: conversation,
      tenant: tenant
    } do
      conn =
        upload(conn, token, conversation.id, upload_file("pic.png", @png), %{
          "activity" => ~s({"text":"look"})
        })

      assert %{
               "id" => activity_id,
               "attachments" => [%{"id" => attachment_id, "contentUrl" => url}]
             } =
               json_response(conn, 200)

      assert url == "http://localhost:4002/api/v1/converger/attachments/#{attachment_id}"

      activity = Converger.Repo.get!(Converger.Activities.Activity, activity_id)

      assert [%{"contentUrl" => ^url, "contentType" => "image/png", "name" => "pic.png"}] =
               activity.attachments

      attachment = Converger.Repo.get!(Attachment, attachment_id)
      assert attachment.tenant_id == tenant.id
      assert attachment.conversation_id == conversation.id
      assert attachment.activity_id == activity_id
      assert attachment.content_type == "image/png"
      assert attachment.size == byte_size(@png)
      assert attachment.sha256 == :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)

      # Not stored under priv/static
      refute String.contains?(attachment.storage_key, "static")

      resp = fetch(conn, token, url)
      assert resp.status == 200
      assert resp.resp_body == @png
      assert get_resp_header(resp, "content-type") == ["image/png"]
      assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
      assert [disposition] = get_resp_header(resp, "content-disposition")
      assert disposition =~ ~s(inline; filename="pic.png")
    end

    test "downloads require a token", %{conn: conn, token: token, conversation: conversation} do
      url = upload(conn, token, conversation.id, upload_file("a.png", @png)) |> content_url()
      assert conn |> recycle() |> get(URI.parse(url).path) |> Map.get(:status) == 401
    end

    test "another tenant gets 404", %{conn: conn, token: token, conversation: conversation} do
      url = upload(conn, token, conversation.id, upload_file("a.png", @png)) |> content_url()

      other_tenant = tenant_fixture()
      other_channel = channel_fixture(other_tenant)
      {:ok, other_token, _} = ConvergerToken.generate_token(other_channel)

      resp = fetch(conn, other_token, url)
      assert resp.status == 404
    end

    test "a token bound to another conversation gets 404", %{
      conn: conn,
      token: token,
      conversation: conversation,
      tenant: tenant,
      channel: channel
    } do
      url = upload(conn, token, conversation.id, upload_file("a.png", @png)) |> content_url()

      other_conversation = conversation_fixture(tenant, channel)

      {:ok, scoped, _} =
        ConvergerToken.generate_conversation_token(channel, other_conversation.id)

      assert fetch(conn, scoped, url).status == 404

      {:ok, own, _} = ConvergerToken.generate_conversation_token(channel, conversation.id)
      assert fetch(conn, own, url).status == 200
    end

    test "unknown and malformed ids are 404", %{conn: conn, token: token} do
      assert fetch(conn, token, "/api/v1/converger/attachments/#{Ecto.UUID.generate()}").status ==
               404

      assert fetch(conn, token, "/api/v1/converger/attachments/not-a-uuid").status == 404
    end

    test "text files are served as text/plain", %{
      conn: conn,
      token: token,
      conversation: conversation
    } do
      url =
        upload(conn, token, conversation.id, upload_file("notes.html", "<b>hi</b>"))
        |> content_url()

      resp = fetch(conn, token, url)
      assert resp.status == 200
      assert get_resp_header(resp, "content-type") == ["text/plain; charset=utf-8"]
      assert [disposition] = get_resp_header(resp, "content-disposition")
      assert disposition =~ "attachment;"
    end
  end

  describe "upload validation" do
    test "type is sniffed and checked against the allowlist", %{
      conn: conn,
      token: token,
      conversation: conversation
    } do
      exe = "MZ" <> <<0x90, 0, 3, 0, 0, 0>> <> :binary.copy(<<0>>, 32)
      conn = upload(conn, token, conversation.id, upload_file("totally.png", exe))
      assert json_response(conn, 415)["error"] =~ "application/octet-stream"
      assert Converger.Repo.aggregate(Attachment, :count) == 0
    end

    test "per-tenant allowlist overrides the default", %{
      conn: conn,
      token: token,
      conversation: conversation,
      tenant: tenant
    } do
      {:ok, _} =
        Converger.Tenants.update_tenant(tenant, %{allowed_upload_types: ["application/pdf"]})

      conn1 = upload(conn, token, conversation.id, upload_file("a.png", @png))
      assert json_response(conn1, 415)

      conn2 = upload(recycle(conn1), token, conversation.id, upload_file("a.pdf", "%PDF-1.4\n"))
      assert json_response(conn2, 200)
    end

    test "max size is configurable", %{conn: conn, token: token, conversation: conversation} do
      with_upload_config(max_file_size: 32)
      conn = upload(conn, token, conversation.id, upload_file("a.png", @png))
      assert json_response(conn, 413)["error"] =~ "File too large"
    end

    test "missing file", %{conn: conn, token: token, conversation: conversation} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/v1/converger/conversations/#{conversation.id}/upload", %{})

      assert json_response(conn, 400)["error"] == "Missing file in upload"
    end
  end

  describe "cloud backends" do
    setup do
      Req.Test.stub(__MODULE__.S3, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      with_upload_config(
        storage: Converger.Uploads.S3Storage,
        storage_opts: [
          bucket: "converger",
          access_key_id: "AKID",
          secret_access_key: "secret",
          region: "us-east-1",
          req_options: [plug: {Req.Test, __MODULE__.S3}, retry: false]
        ]
      )

      :ok
    end

    test "download redirects to a short-lived signed URL", %{
      conn: conn,
      token: token,
      conversation: conversation
    } do
      url = upload(conn, token, conversation.id, upload_file("a.png", @png)) |> content_url()
      resp = fetch(conn, token, url)

      assert resp.status == 302
      [location] = get_resp_header(resp, "location")

      assert location =~
               ~r{^https://converger\.s3\.us-east-1\.amazonaws\.com/[0-9a-f-]+/[0-9a-f-]+\?}

      assert URI.decode_query(URI.parse(location).query)["X-Amz-Expires"] == "300"
    end

    test "a configured CDN takes precedence", %{
      conn: conn,
      token: token,
      conversation: conversation
    } do
      with_upload_config(cdn: [type: :plain, base_url: "https://files.example.com"])

      url = upload(conn, token, conversation.id, upload_file("a.png", @png)) |> content_url()
      resp = fetch(conn, token, url)

      assert resp.status == 302
      [location] = get_resp_header(resp, "location")
      assert String.starts_with?(location, "https://files.example.com/")
    end
  end

  defp content_url(conn) do
    %{"attachments" => [%{"contentUrl" => url}]} = json_response(conn, 200)
    url
  end
end
