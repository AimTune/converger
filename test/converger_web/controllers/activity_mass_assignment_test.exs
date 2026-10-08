defmodule ConvergerWeb.ActivityMassAssignmentTest do
  use ConvergerWeb.ConnCase, async: false

  alias Converger.Activities
  alias Converger.Activities.Activity

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup %{conn: conn} do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    conn = put_req_header(conn, "x-api-key", tenant.api_key)

    %{conn: conn, tenant: tenant, conversation: conversation}
  end

  defp create(conn, conversation, params) do
    post(conn, ~p"/api/v1/conversations/#{conversation.id}/activities", params)
  end

  describe "server-controlled fields" do
    test "inserted_at in the body is ignored, the server timestamp wins", %{
      conn: conn,
      conversation: conversation
    } do
      before = DateTime.utc_now()

      conn =
        create(conn, conversation, %{"text" => "hi", "inserted_at" => "2001-01-01T00:00:00Z"})

      %{"id" => id} = json_response(conn, 201)["data"]
      activity = Activities.get_activity!(id)

      assert DateTime.compare(activity.inserted_at, before) in [:gt, :eq]
    end

    test "idempotency_key in the body is ignored, only the header counts", %{
      conn: conn,
      conversation: conversation
    } do
      conn = create(conn, conversation, %{"text" => "hi", "idempotency_key" => "from-body"})

      %{"id" => id} = json_response(conn, 201)["data"]
      assert Activities.get_activity!(id).idempotency_key == nil
    end

    test "tenant_id and conversation_id in the body are ignored", %{
      conn: conn,
      tenant: tenant,
      conversation: conversation
    } do
      other_tenant = tenant_fixture()

      conn =
        create(conn, conversation, %{
          "text" => "hi",
          "tenant_id" => other_tenant.id,
          "conversation_id" => Ecto.UUID.generate()
        })

      %{"id" => id} = json_response(conn, 201)["data"]
      activity = Activities.get_activity!(id)
      assert activity.tenant_id == tenant.id
      assert activity.conversation_id == conversation.id
    end
  end

  describe "limits return 422 with field-level errors" do
    test "unknown type", %{conn: conn, conversation: conversation} do
      conn = create(conn, conversation, %{"text" => "hi", "type" => "rm -rf"})
      assert %{"type" => [_]} = json_response(conn, 422)["errors"]
    end

    test "text too long", %{conn: conn, conversation: conversation} do
      text = String.duplicate("a", Activity.limits()[:max_text_bytes] + 1)
      conn = create(conn, conversation, %{"text" => text})
      assert %{"text" => [_]} = json_response(conn, 422)["errors"]
    end

    test "too many attachments", %{conn: conn, conversation: conversation} do
      attachments =
        for i <- 0..Activity.limits()[:max_attachments],
            do: %{"contentType" => "image/png", "contentUrl" => "https://x/#{i}.png"}

      conn = create(conn, conversation, %{"text" => "hi", "attachments" => attachments})
      assert %{"attachments" => [_ | _]} = json_response(conn, 422)["errors"]
    end

    test "attachment too large", %{conn: conn, conversation: conversation} do
      big = String.duplicate("x", Activity.limits()[:max_attachment_bytes])

      conn =
        create(conn, conversation, %{
          "text" => "hi",
          "attachments" => [%{"contentType" => "text/plain", "content" => big}]
        })

      assert %{"attachments" => [message]} = json_response(conn, 422)["errors"]
      assert message =~ "attachment 0"
    end

    test "metadata too large", %{conn: conn, conversation: conversation} do
      metadata = %{"blob" => String.duplicate("x", Activity.limits()[:max_metadata_bytes])}
      conn = create(conn, conversation, %{"text" => "hi", "metadata" => metadata})
      assert %{"metadata" => [_]} = json_response(conn, 422)["errors"]
    end

    test "limits are configurable", %{conn: conn, conversation: conversation} do
      previous = Application.get_env(:converger, :activity_limits)
      Application.put_env(:converger, :activity_limits, max_text_bytes: 5)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, :activity_limits, previous),
          else: Application.delete_env(:converger, :activity_limits)
      end)

      conn = create(conn, conversation, %{"text" => "123456"})
      assert %{"text" => [_]} = json_response(conn, 422)["errors"]
    end
  end
end
