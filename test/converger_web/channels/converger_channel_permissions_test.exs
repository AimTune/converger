defmodule ConvergerWeb.ConvergerChannelPermissionsTest do
  @moduledoc "Token permissions and revocation on the Phoenix binding (issue #52, ADR-0057)."

  use ConvergerWeb.ChannelCase

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.{ConvergerToken, Revocations}
  alias ConvergerWeb.{ConvergerChannel, ConvergerSocket}

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    %{channel: channel, conversation: conversation}
  end

  defp connect_with(channel, conversation, opts) do
    {:ok, token, claims} =
      ConvergerToken.generate_conversation_token(channel, conversation.id, opts)

    {:ok, socket} = connect(ConvergerSocket, %{"token" => token})
    {token, claims, socket}
  end

  test "a read-only token joins but cannot send or type", ctx do
    {_token, _claims, socket} = connect_with(ctx.channel, ctx.conversation, permissions: ["read"])

    {:ok, _, socket} =
      subscribe_and_join(
        socket,
        ConvergerChannel,
        "converger:conversation:#{ctx.conversation.id}"
      )

    ref = push(socket, "postActivity", %{"text" => "hi"})
    assert_reply ref, :error, %{reason: "insufficient_permission", required: "write"}

    ref =
      push(socket, "frame", %{"type" => "text", "clientId" => "c-1", "data" => %{"text" => "hi"}})

    assert_reply ref, :error, %{reason: "insufficient_permission"}

    assert_push "frame", %{
      "type" => "error",
      "data" => %{"code" => "insufficient_permission", "clientId" => "c-1"}
    }

    ref = push(socket, "typing", %{"isTyping" => true})
    assert_reply ref, :error, %{reason: "insufficient_permission", required: "typing"}

    # Read receipts come with reading.
    ref = push(socket, "read", %{"watermark" => 1})
    refute_reply ref, :error, %{reason: "insufficient_permission"}
  end

  test "a token without read cannot join", ctx do
    {_token, _claims, socket} =
      connect_with(ctx.channel, ctx.conversation, permissions: ["write"])

    assert {:error, %{reason: "insufficient_permission", required: "read"}} =
             subscribe_and_join(
               socket,
               ConvergerChannel,
               "converger:conversation:#{ctx.conversation.id}"
             )
  end

  test "a read and typing token may type", ctx do
    {_token, _claims, socket} =
      connect_with(ctx.channel, ctx.conversation, permissions: ["read", "typing"])

    {:ok, _, socket} =
      subscribe_and_join(
        socket,
        ConvergerChannel,
        "converger:conversation:#{ctx.conversation.id}"
      )

    ref = push(socket, "typing", %{"isTyping" => true})
    assert_reply ref, :ok
  end

  test "a revoked token cannot connect", ctx do
    {token, claims, _socket} = connect_with(ctx.channel, ctx.conversation, [])
    :ok = Revocations.revoke_family(claims)

    assert :error = connect(ConvergerSocket, %{"token" => token})
  end
end
