defmodule ConvergerWeb.InboundParticipantTest do
  use ConvergerWeb.ConnCase

  import Ecto.Query
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.Activities.Activity
  alias Converger.Channels
  alias Converger.Channels.InboundSignature
  alias Converger.Conversations
  alias Converger.Conversations.Conversation
  alias Converger.Participants
  alias Converger.Repo

  @app_secret "meta-app-secret-participants"
  @phone "16505551234"

  setup do
    previous = Application.get_env(:converger, :whatsapp_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :whatsapp_req_options, previous),
        else: Application.delete_env(:converger, :whatsapp_req_options)
    end)

    Application.put_env(:converger, :whatsapp_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:whatsapp_request, conn.request_path, Jason.decode!(body)})
      Req.Test.json(conn, %{"messages" => [%{"id" => "wamid.out-#{System.unique_integer()}"}]})
    end)

    tenant = tenant_fixture()
    %{tenant: tenant, meta: meta_channel(tenant)}
  end

  defp meta_channel(tenant, extra_config \\ %{}) do
    {:ok, channel} =
      Channels.create_channel(%{
        name: unique_channel_name(),
        type: "whatsapp_meta",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config:
          Map.merge(
            %{
              "phone_number_id" => "106540352242922",
              "access_token" => "token",
              "verify_token" => "verify",
              "app_secret" => @app_secret
            },
            extra_config
          )
      })

    channel
  end

  defp meta_message(conn, channel, id, text, from \\ @phone) do
    params = %{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "1",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{"phone_number_id" => "106540352242922"},
                "contacts" => [%{"profile" => %{"name" => "Sheena"}, "wa_id" => from}],
                "messages" => [
                  %{
                    "from" => from,
                    "id" => id,
                    "timestamp" => "1749416383",
                    "type" => "text",
                    "text" => %{"body" => text}
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    body = Jason.encode!(params)
    signature = "sha256=" <> InboundSignature.hmac_hex(@app_secret, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)

    [activity_id] = json_response(conn, 200)["activity_ids"]
    Repo.get!(Activity, activity_id)
  end

  describe "participant-based conversation resolution" do
    test "two WhatsApp messages from the same number land in the same conversation", %{
      conn: conn,
      meta: meta
    } do
      first = meta_message(conn, meta, "wamid.p-1", "hello")
      second = meta_message(build_conn(), meta, "wamid.p-2", "are you there?")

      assert first.conversation_id == second.conversation_id
      assert [first.seq, second.seq] == [1, 2]

      conversation =
        first.conversation_id |> Conversations.get_conversation!() |> Repo.preload(:participant)

      assert conversation.participant.external_id == @phone
      assert conversation.participant.display_name == "Sheena"
      assert conversation.participant.channel_id == meta.id
    end

    test "messages from different numbers get different conversations", %{
      conn: conn,
      meta: meta
    } do
      a = meta_message(conn, meta, "wamid.a", "hi", "111")
      b = meta_message(build_conn(), meta, "wamid.b", "hi", "222")

      refute a.conversation_id == b.conversation_id
    end

    test "the inbound message is not echoed back to the sender", %{conn: conn, meta: meta} do
      meta_message(conn, meta, "wamid.no-echo", "hello")

      refute_received {:whatsapp_request, _, _}
    end

    test "a closed conversation is not reused", %{conn: conn, meta: meta} do
      first = meta_message(conn, meta, "wamid.c-1", "hello")

      {:ok, _} =
        first.conversation_id
        |> Conversations.get_conversation!()
        |> Conversations.close_conversation()

      second = meta_message(build_conn(), meta, "wamid.c-2", "hello again")

      refute second.conversation_id == first.conversation_id
      assert Conversations.get_conversation!(second.conversation_id).status == "active"

      assert Conversations.get_conversation!(second.conversation_id).participant_id ==
               Conversations.get_conversation!(first.conversation_id).participant_id
    end

    test "an idle conversation is not reused after the channel idle timeout", %{
      conn: conn,
      tenant: tenant
    } do
      channel = meta_channel(tenant, %{"conversation_idle_timeout_seconds" => 3600})
      first = meta_message(conn, channel, "wamid.i-1", "hello")

      two_hours_ago = DateTime.add(DateTime.utc_now(), -7200, :second)

      Repo.update_all(from(a in Activity, where: a.conversation_id == ^first.conversation_id),
        set: [inserted_at: two_hours_ago]
      )

      Repo.update_all(from(c in Conversation, where: c.id == ^first.conversation_id),
        set: [inserted_at: two_hours_ago]
      )

      second = meta_message(build_conn(), channel, "wamid.i-2", "hello again")
      refute second.conversation_id == first.conversation_id

      third = meta_message(build_conn(), channel, "wamid.i-3", "still here")
      assert third.conversation_id == second.conversation_id
    end

    test "re-delivery after the conversation was closed creates no duplicate", %{
      conn: conn,
      meta: meta
    } do
      first = meta_message(conn, meta, "wamid.r-1", "hello")

      {:ok, _} =
        first.conversation_id
        |> Conversations.get_conversation!()
        |> Conversations.close_conversation()

      again = meta_message(build_conn(), meta, "wamid.r-1", "hello")
      assert again.id == first.id
    end
  end

  describe "replies" do
    test "a bot reply posted to the conversation is delivered to the participant's number", %{
      conn: conn,
      tenant: tenant,
      meta: meta
    } do
      inbound = meta_message(conn, meta, "wamid.q-1", "what are your hours?")

      conn =
        build_conn()
        |> put_req_header("x-api-key", tenant.api_key)
        |> post(~p"/api/v1/conversations/#{inbound.conversation_id}/activities", %{
          "type" => "message",
          "text" => "9 to 5",
          "sender" => "bot"
        })

      assert json_response(conn, 201)

      assert_received {:whatsapp_request, path, payload}
      assert path =~ "/106540352242922/messages"
      assert payload["to"] == @phone
      assert payload["text"]["body"] == "9 to 5"
    end
  end

  describe "GET /api/v1/conversations?external_id=" do
    test "finds the participant's conversations", %{conn: conn, tenant: tenant, meta: meta} do
      inbound = meta_message(conn, meta, "wamid.l-1", "hello")
      meta_message(build_conn(), meta, "wamid.l-2", "other", "999")

      conn =
        build_conn()
        |> put_req_header("x-api-key", tenant.api_key)
        |> get(~p"/api/v1/conversations?external_id=#{@phone}")

      assert [conversation] = json_response(conn, 200)["data"]
      assert conversation["id"] == inbound.conversation_id
      assert conversation["participant"]["external_id"] == @phone
      assert conversation["participant"]["display_name"] == "Sheena"
    end

    test "is scoped to the tenant", %{conn: conn, meta: meta} do
      meta_message(conn, meta, "wamid.t-1", "hello")
      other = tenant_fixture()

      conn =
        build_conn()
        |> put_req_header("x-api-key", other.api_key)
        |> get(~p"/api/v1/conversations?external_id=#{@phone}")

      assert json_response(conn, 200)["data"] == []
    end

    test "requires the tenant API key, not a channel token", %{tenant: tenant} do
      channel = channel_fixture(tenant)
      {:ok, token, _} = Converger.Auth.Token.generate_channel_token(channel)

      conn =
        build_conn()
        |> put_req_header("x-channel-token", token)
        |> get(~p"/api/v1/conversations?external_id=#{@phone}")

      assert json_response(conn, 403)
    end

    test "rejects a malformed channel_id", %{tenant: tenant} do
      conn =
        build_conn()
        |> put_req_header("x-api-key", tenant.api_key)
        |> get(~p"/api/v1/conversations?channel_id=nope")

      assert json_response(conn, 400)
    end
  end

  describe "generic webhook" do
    test "external_id opts into participant resolution", %{conn: conn, tenant: tenant} do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})
      path = ~p"/api/v1/channels/#{channel.id}/inbound"
      params = %{"text" => "hi", "sender" => "u1", "external_id" => "user-42"}

      a = json_response(signed_post(conn, path, channel, params), 201)["activity_id"]
      b = json_response(signed_post(build_conn(), path, channel, params), 201)["activity_id"]

      assert Repo.get!(Activity, a).conversation_id == Repo.get!(Activity, b).conversation_id
    end

    test "without external_id every message still starts a new conversation", %{
      conn: conn,
      tenant: tenant
    } do
      channel = webhook_channel_fixture(tenant, %{mode: "inbound"})
      path = ~p"/api/v1/channels/#{channel.id}/inbound"
      params = %{"text" => "hi", "sender" => "u1"}

      a = json_response(signed_post(conn, path, channel, params), 201)["activity_id"]
      b = json_response(signed_post(build_conn(), path, channel, params), 201)["activity_id"]

      refute Repo.get!(Activity, a).conversation_id == Repo.get!(Activity, b).conversation_id
    end
  end

  describe "Participants" do
    test "upsert is idempotent per (channel, external_id) and keeps the latest name", %{
      meta: meta
    } do
      {:ok, p1} =
        Participants.upsert_participant(meta, %{"external_id" => "1", "display_name" => "A"})

      {:ok, p2} = Participants.upsert_participant(meta, %{"external_id" => "1"})

      {:ok, p3} =
        Participants.upsert_participant(meta, %{"external_id" => "1", "display_name" => "B"})

      assert p1.id == p2.id and p2.id == p3.id
      assert p2.display_name == "A"
      assert p3.display_name == "B"
    end

    test "resolve_conversation reuses the active conversation", %{meta: meta} do
      {:ok, c1} = Participants.resolve_conversation(meta, %{"external_id" => "1"})
      {:ok, c2} = Participants.resolve_conversation(meta, %{"external_id" => "1"})

      assert c1.id == c2.id
    end
  end
end
