defmodule ConvergerWeb.LegacyRestDeprecationTest do
  use ConvergerWeb.ConnCase

  import ExUnit.CaptureLog
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.Token

  @moduletag :capture_log

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)
    conversation = conversation_fixture(tenant, channel)
    {:ok, channel_token, _} = Token.generate_channel_token(channel)
    %{tenant: tenant, conversation: conversation, channel_token: channel_token}
  end

  defp assert_deprecated(conn, log, surface) do
    assert [<<"@", unix::binary>>] = get_resp_header(conn, "deprecation")
    assert String.to_integer(unix) > 0

    assert get_resp_header(conn, "link") ==
             [~s(<#{ConvergerWeb.Deprecation.migration_guide()}>; rel="deprecation")]

    assert log =~ "Deprecated #{surface} used"
  end

  test "POST /api/v1/tokens is deprecated", %{conversation: conversation, channel_token: token} do
    {conn, log} =
      with_log(fn ->
        build_conn()
        |> put_req_header("x-channel-token", token)
        |> post(~p"/api/v1/tokens", %{conversation_id: conversation.id, user_id: "u"})
      end)

    assert json_response(conn, 201)
    assert_deprecated(conn, log, "token_endpoint")
  end

  test "POST /api/v1/conversations is deprecated", %{channel_token: token} do
    {conn, log} =
      with_log(fn ->
        build_conn()
        |> put_req_header("x-channel-token", token)
        |> post(~p"/api/v1/conversations", %{})
      end)

    assert json_response(conn, 201)
    assert_deprecated(conn, log, "channel_token")
  end

  test "x-channel-token on the tenant API is deprecated", %{channel_token: token} do
    {conn, log} =
      with_log(fn ->
        build_conn()
        |> put_req_header("x-channel-token", token)
        |> get(~p"/api/v1/routing_rules")
      end)

    assert json_response(conn, 200)
    assert_deprecated(conn, log, "channel_token")
  end

  test "the tenant API key is not deprecated", %{tenant: tenant} do
    {conn, log} =
      with_log(fn ->
        build_conn()
        |> put_req_header("x-api-key", tenant.api_key)
        |> get(~p"/api/v1/routing_rules")
      end)

    assert json_response(conn, 200)
    assert get_resp_header(conn, "deprecation") == []
    refute log =~ "Deprecated"
  end
end
