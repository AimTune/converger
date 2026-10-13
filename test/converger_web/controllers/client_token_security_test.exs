defmodule ConvergerWeb.ClientTokenSecurityTest do
  @moduledoc """
  Client token hardening over the REST API (issue #52, ADR-0057): token
  permissions, refresh rotation and reuse detection, revocation.
  """

  # Changes application env (rotation grace period).
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.Sockets

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{tenant: tenant, channel: channel, conversation: conversation}
  end

  defp bearer(credential),
    do: build_conn() |> put_req_header("authorization", "Bearer #{credential}")

  defp generate(channel, body \\ %{}) do
    bearer(channel.secret)
    |> post(~p"/api/v1/converger/tokens/generate", body)
    |> json_response(200)
  end

  defp put_grace(seconds) do
    previous = Application.get_env(:converger, :token_rotation_grace_seconds)
    Application.put_env(:converger, :token_rotation_grace_seconds, seconds)
    on_exit(fn -> Application.put_env(:converger, :token_rotation_grace_seconds, previous) end)
  end

  defp post_text(token, conversation_id) do
    bearer(token)
    |> post(~p"/api/v1/converger/conversations/#{conversation_id}/activities", %{
      "type" => "message",
      "text" => "hi"
    })
  end

  describe "permissions" do
    test "generate restricts a token and reports its permissions", %{channel: channel} do
      body = generate(channel, %{"permissions" => ["typing", "read"]})
      assert body["permissions"] == ["read", "typing"]
      assert {:ok, %{"perms" => ["read", "typing"]}} = ConvergerToken.verify_token(body["token"])

      assert generate(channel)["permissions"] == nil
    end

    test "generate rejects unknown or empty permissions", %{channel: channel} do
      for permissions <- [["admin"], [], "read"] do
        conn =
          bearer(channel.secret)
          |> post(~p"/api/v1/converger/tokens/generate", %{"permissions" => permissions})

        assert_api_error(conn, 400, "bad_request")
      end
    end

    test "a read-only token reads but cannot write", %{
      channel: channel,
      conversation: conversation
    } do
      %{"token" => token} = generate(channel, %{"permissions" => ["read"]})

      # Starting a conversation is a write.
      assert_api_error(
        bearer(token) |> post(~p"/api/v1/converger/conversations"),
        403,
        "insufficient_permission"
      )

      {:ok, viewer, _} =
        ConvergerToken.generate_conversation_token(channel, conversation.id,
          permissions: ["read"]
        )

      # The token returned on resume keeps the restriction.
      body =
        bearer(viewer)
        |> get(~p"/api/v1/converger/conversations/#{conversation.id}")
        |> json_response(200)

      assert {:ok, %{"perms" => ["read"]}} = ConvergerToken.verify_token(body["token"])

      assert bearer(viewer)
             |> get(~p"/api/v1/converger/conversations/#{conversation.id}/activities")
             |> json_response(200)

      conn = post_text(viewer, conversation.id)

      assert assert_api_error(conn, 403, "insufficient_permission")["details"] == %{
               "required" => "write"
             }

      assert_api_error(
        bearer(viewer) |> post(~p"/api/v1/converger/conversations/#{conversation.id}/close"),
        403,
        "insufficient_permission"
      )
    end

    test "a write-only token cannot read", %{channel: channel, conversation: conversation} do
      {:ok, token, _} =
        ConvergerToken.generate_conversation_token(channel, conversation.id,
          permissions: ["write"]
        )

      assert json_response(post_text(token, conversation.id), 200)

      assert_api_error(
        bearer(token) |> get(~p"/api/v1/converger/conversations/#{conversation.id}/activities"),
        403,
        "insufficient_permission"
      )
    end
  end

  describe "derived tokens" do
    test "a conversation token never outlives the token it came from", %{channel: channel} do
      {:ok, parent, parent_claims} = ConvergerToken.generate_token(channel, expires_in: 60)

      body =
        bearer(parent) |> post(~p"/api/v1/converger/conversations") |> json_response(201)

      {:ok, claims} = ConvergerToken.verify_token(body["token"])
      assert claims["exp"] <= parent_claims["exp"]
      assert claims["fam"] == parent_claims["fam"]
      assert body["expires_in"] <= 60

      # Resuming does not extend it either: only a refresh (which rotates) does.
      again =
        bearer(body["token"])
        |> get(~p"/api/v1/converger/conversations/#{body["conversationId"]}")
        |> json_response(200)

      {:ok, again_claims} = ConvergerToken.verify_token(again["token"])
      assert again_claims["exp"] <= parent_claims["exp"]
    end
  end

  describe "refresh rotation" do
    test "the refreshed token is rejected after the grace period", %{channel: channel} do
      %{"token" => token} = generate(channel)

      %{"token" => refreshed} =
        bearer(token) |> post(~p"/api/v1/converger/tokens/refresh") |> json_response(200)

      # In flight with the old token: still accepted within the grace period.
      assert bearer(token) |> post(~p"/api/v1/converger/conversations") |> json_response(201)

      put_grace(0)
      Process.sleep(5)

      assert_api_error(
        bearer(token) |> post(~p"/api/v1/converger/conversations"),
        401,
        "token_revoked"
      )

      assert bearer(refreshed) |> post(~p"/api/v1/converger/conversations") |> json_response(201)
    end

    test "refreshing a token twice after the grace period revokes the family", %{
      channel: channel
    } do
      put_grace(0)
      %{"token" => stolen} = generate(channel, %{"user" => %{"id" => "alice"}})

      %{"token" => legit} =
        bearer(stolen) |> post(~p"/api/v1/converger/tokens/refresh") |> json_response(200)

      Process.sleep(5)

      conn = bearer(stolen) |> post(~p"/api/v1/converger/tokens/refresh")
      assert assert_api_error(conn, 401, "token_revoked")["message"] =~ "family"

      assert_api_error(
        bearer(legit) |> post(~p"/api/v1/converger/tokens/refresh"),
        401,
        "token_revoked"
      )
    end
  end

  describe "revoke" do
    test "a token revokes itself and its family, and its sockets are disconnected", %{
      tenant: tenant,
      channel: channel
    } do
      %{"token" => token} = generate(channel, %{"user" => %{"id" => "alice"}})

      %{"token" => conversation_token, "conversationId" => conversation_id} =
        bearer(token) |> post(~p"/api/v1/converger/conversations") |> json_response(201)

      ConvergerWeb.Endpoint.subscribe("converger_socket:#{tenant.id}:user:alice")

      assert %{"revoked" => "token"} =
               bearer(token) |> post(~p"/api/v1/converger/tokens/revoke") |> json_response(200)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_api_error(
        bearer(token) |> post(~p"/api/v1/converger/conversations"),
        401,
        "token_revoked"
      )

      assert_api_error(
        bearer(conversation_token)
        |> get(~p"/api/v1/converger/conversations/#{conversation_id}/activities"),
        401,
        "token_revoked"
      )

      assert_api_error(
        bearer(token) |> post(~p"/api/v1/converger/tokens/refresh"),
        401,
        "token_revoked"
      )
    end

    test "the channel secret revokes a token of its channel", %{channel: channel} do
      %{"token" => token} = generate(channel)

      assert %{"revoked" => "token"} =
               bearer(channel.secret)
               |> post(~p"/api/v1/converger/tokens/revoke", %{"token" => token})
               |> json_response(200)

      assert_api_error(
        bearer(token) |> post(~p"/api/v1/converger/conversations"),
        401,
        "token_revoked"
      )
    end

    test "the channel secret cannot revoke another channel's token", %{
      tenant: tenant,
      channel: channel
    } do
      other = channel_fixture(tenant)
      %{"token" => token} = generate(other)

      assert_api_error(
        bearer(channel.secret) |> post(~p"/api/v1/converger/tokens/revoke", %{"token" => token}),
        403,
        "forbidden"
      )

      assert bearer(token) |> post(~p"/api/v1/converger/conversations") |> json_response(201)
    end

    test "revoking an invalid token is a no-op", %{channel: channel} do
      assert %{"revoked" => "token"} =
               bearer(channel.secret)
               |> post(~p"/api/v1/converger/tokens/revoke", %{"token" => "not-a-jwt"})
               |> json_response(200)
    end

    test "the channel secret revokes every token of an end user", %{channel: channel} do
      %{"token" => alice} = generate(channel, %{"user" => %{"id" => "alice"}})
      %{"token" => bob} = generate(channel, %{"user" => %{"id" => "bob"}})

      {:ok, alice_claims} = ConvergerToken.verify_token(alice)
      ConvergerWeb.Endpoint.subscribe(Sockets.converger_socket_id(alice_claims))

      assert %{"revoked" => "user"} =
               bearer(channel.secret)
               |> post(~p"/api/v1/converger/tokens/revoke", %{"user" => %{"id" => "alice"}})
               |> json_response(200)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert_api_error(
        bearer(alice) |> post(~p"/api/v1/converger/conversations"),
        401,
        "token_revoked"
      )

      assert bearer(bob) |> post(~p"/api/v1/converger/conversations") |> json_response(201)
    end

    test "the secret needs a token or a user to revoke", %{channel: channel} do
      assert_api_error(
        bearer(channel.secret) |> post(~p"/api/v1/converger/tokens/revoke", %{}),
        400,
        "bad_request"
      )
    end
  end
end
