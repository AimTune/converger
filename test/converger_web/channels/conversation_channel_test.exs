defmodule ConvergerWeb.ConversationChannelTest do
  # The legacy socket (/socket, `conversation:<id>`) is deprecated (#23).
  # Behaviour is covered on the unified stack in ConvergerChannelTest; these
  # tests pin the deprecation warning and what still ships until removal.
  use ConvergerWeb.ChannelCase

  import ExUnit.CaptureLog

  alias Converger.Auth.{ConvergerToken, Token}
  alias ConvergerWeb.UserSocket
  alias ConvergerWeb.ConversationChannel

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  @moduletag :capture_log

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)

    {:ok, token, _claims} = Token.generate_token(conversation, tenant, "user-1")

    %{conversation: conversation, tenant: tenant, channel: channel, token: token}
  end

  defp join_legacy(token, conversation, payload \\ %{}) do
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    {:ok, _, socket} =
      subscribe_and_join(socket, ConversationChannel, "conversation:#{conversation.id}", payload)

    socket
  end

  test "every connection logs a deprecation warning and emits telemetry", %{
    token: token,
    tenant: tenant,
    conversation: conversation
  } do
    handler = "deprecation-#{inspect(self())}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:converger, :deprecated, :use],
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:deprecated, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log = capture_log(fn -> assert {:ok, _socket} = connect(UserSocket, %{"token" => token}) end)

    assert log =~ "Deprecated legacy_socket used"
    assert log =~ "/socket/converger"
    assert log =~ ConvergerWeb.Deprecation.migration_guide()

    assert_receive {:deprecated, %{count: 1}, metadata}
    assert metadata.surface == :legacy_socket
    assert metadata.tenant_id == tenant.id
    assert metadata.conversation_id == conversation.id
  end

  test "refuses Converger API and channel tokens", %{channel: channel, conversation: conversation} do
    {:ok, converger_token, _} =
      ConvergerToken.generate_conversation_token(channel, conversation.id)

    {:ok, channel_token, _} = Token.generate_channel_token(channel)

    assert :error = connect(UserSocket, %{"token" => converger_token})
    assert :error = connect(UserSocket, %{"token" => channel_token})
  end

  test "still sends with a reply and broadcasts new_activity", %{
    token: token,
    conversation: conversation
  } do
    socket = join_legacy(token, conversation)

    ref = push(socket, "new_activity", %{"text" => "hello", "sender" => "bot"})
    assert_reply ref, :ok, %{id: id, seq: 1}
    assert_broadcast "new_activity", %{id: ^id, text: "hello", sender: "user-1"}
  end

  test "still de-duplicates re-pushes by idempotency_key", %{
    token: token,
    conversation: conversation
  } do
    socket = join_legacy(token, conversation)

    ref = push(socket, "new_activity", %{"text" => "once", "idempotency_key" => "k-1"})
    assert_reply ref, :ok, %{id: id, seq: 1}

    ref = push(socket, "new_activity", %{"text" => "once", "idempotency_key" => "k-1"})
    assert_reply ref, :ok, %{id: ^id, seq: 1}

    assert [%{id: ^id, idempotency_key: "ws:user-1:k-1"}] =
             Converger.Activities.list_activities_for_conversation(conversation.id)
  end

  test "still replays by last_activity_id, capped with replay_truncated", %{
    token: token,
    tenant: tenant,
    conversation: conversation
  } do
    previous = Application.get_env(:converger, :pagination)
    Application.put_env(:converger, :pagination, Keyword.put(previous || [], :ws_replay_limit, 2))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :pagination, previous),
        else: Application.delete_env(:converger, :pagination)
    end)

    [first, a, b, _c] =
      for text <- ~w(first a b c), do: activity_fixture(tenant, conversation, %{text: text})

    join_legacy(token, conversation, %{"last_activity_id" => first.id})

    a_id = a.id
    b_id = b.id
    assert_push "new_activity", %{id: ^a_id}
    assert_push "new_activity", %{id: ^b_id}
    assert_push "replay_truncated", %{has_more: true, last_activity_id: ^b_id}
    refute_push "new_activity", _
  end
end
