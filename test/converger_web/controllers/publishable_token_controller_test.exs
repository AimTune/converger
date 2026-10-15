defmodule ConvergerWeb.PublishableTokenControllerTest do
  @moduledoc """
  Publishable keys (issue #195, ADR-0074): `POST /api/v1/converger/tokens/publishable`,
  the conversation-bound anonymous tokens it mints, the `resume` credential,
  and CORS for the allowed origins.
  """

  use ConvergerWeb.ConnCase, async: true

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.{ConvergerToken, PublishableResume}
  alias Converger.{Channels, Conversations, Tenants}

  @origin "https://shop.example.com"

  setup do
    tenant = tenant_fixture()
    channel = channel_fixture(tenant)

    {:ok, channel} =
      Channels.update_client_access(
        channel,
        %{"allowed_origins" => "#{@origin}\nhttps://*.widgets.io"},
        :new
      )

    %{tenant: tenant, channel: channel}
  end

  # A fresh client IP per request keeps the per-IP limit out of other tests.
  defp unique_ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  defp publishable(key, opts \\ []) do
    conn = %{build_conn() | remote_ip: Keyword.get(opts, :ip, unique_ip())}

    conn =
      case Keyword.get(opts, :origin, @origin) do
        nil -> conn
        origin -> put_req_header(conn, "origin", origin)
      end

    conn
    |> put_req_header("authorization", "Bearer #{key}")
    |> post(~p"/api/v1/converger/tokens/publishable", Keyword.get(opts, :body, %{}))
  end

  defp bearer(token), do: put_req_header(build_conn(), "authorization", "Bearer #{token}")

  describe "minting" do
    test "creates a conversation and a token bound to it for an anonymous user",
         %{channel: channel} do
      body = channel.publishable_key |> publishable() |> json_response(200)

      assert %{
               "conversationId" => conversation_id,
               "token" => token,
               "userId" => "anon_" <> _,
               "resume" => resume,
               "resumed" => false,
               "expires_in" => expires_in
             } = body

      assert expires_in > 0 and is_binary(resume)

      assert {:ok, claims} = ConvergerToken.verify_token(token)
      assert claims["conversation_id"] == conversation_id
      assert claims["user_id"] == body["userId"]
      assert claims["src"] == "publishable"
      assert claims["channel_id"] == channel.id

      conversation = Conversations.get_conversation(conversation_id)
      assert conversation.channel_id == channel.id
      assert conversation.metadata["source"] == "publishable_key"

      assert OpenApiSpex.TestAssertions.assert_schema(
               body,
               "PublishableToken",
               ConvergerWeb.ApiSpec.spec()
             )
    end

    test "every call without resume is a new visitor", %{channel: channel} do
      first = channel.publishable_key |> publishable() |> json_response(200)
      second = channel.publishable_key |> publishable() |> json_response(200)

      refute first["conversationId"] == second["conversationId"]
      refute first["userId"] == second["userId"]
    end

    test "the token posts into its own conversation and nowhere else",
         %{tenant: tenant, channel: channel} do
      body = channel.publishable_key |> publishable() |> json_response(200)
      other = conversation_fixture(tenant, channel)

      assert bearer(body["token"])
             |> post(~p"/api/v1/converger/conversations/#{body["conversationId"]}/activities", %{
               "type" => "message",
               "text" => "hi"
             })
             |> json_response(200)

      for path <- [
            ~p"/api/v1/converger/conversations/#{other.id}",
            ~p"/api/v1/converger/conversations/#{other.id}/activities"
          ] do
        assert_api_error(bearer(body["token"]) |> get(path), 403, "forbidden")
      end

      assert_api_error(
        bearer(body["token"]) |> get(~p"/api/v1/converger/conversations"),
        403,
        "forbidden"
      )
    end
  end

  describe "resume" do
    test "continues the conversation as the same user", %{channel: channel} do
      first = channel.publishable_key |> publishable() |> json_response(200)

      second =
        channel.publishable_key
        |> publishable(body: %{"resume" => first["resume"]})
        |> json_response(200)

      assert second["resumed"] == true
      assert second["conversationId"] == first["conversationId"]
      assert second["userId"] == first["userId"]
      refute second["token"] == first["token"]
    end

    test "an invalid, foreign or stale credential starts a new conversation",
         %{tenant: tenant, channel: channel} do
      other_channel = channel_fixture(tenant)
      other_conversation = conversation_fixture(tenant, other_channel)
      closed = conversation_fixture(tenant, channel)
      {:ok, _} = Conversations.close_conversation(closed)

      for resume <- [
            "garbage",
            PublishableResume.sign(other_channel.id, other_conversation.id, "anon_x"),
            # Signed for this channel but naming another channel's conversation.
            PublishableResume.sign(channel.id, other_conversation.id, "anon_x"),
            PublishableResume.sign(channel.id, closed.id, "anon_x"),
            PublishableResume.sign(channel.id, Ecto.UUID.generate(), "anon_x")
          ] do
        body =
          channel.publishable_key
          |> publishable(body: %{"resume" => resume})
          |> json_response(200)

        assert body["resumed"] == false
        refute body["conversationId"] in [other_conversation.id, closed.id]
        refute body["userId"] == "anon_x"
      end
    end
  end

  describe "rejections" do
    test "unknown, disabled or secret-shaped keys are unauthorized",
         %{tenant: tenant, channel: channel} do
      assert_api_error(publishable("cvg_pk_nope"), 401, "unauthorized")
      assert_api_error(publishable(channel.secret), 401, "unauthorized")

      {:ok, inactive} = Channels.update_channel(channel_fixture(tenant), %{status: "inactive"})

      {:ok, inactive} =
        Channels.update_client_access(inactive, %{"allowed_origins" => @origin}, :new)

      assert_api_error(publishable(inactive.publishable_key), 401, "unauthorized")

      {:ok, disabled} = Channels.update_client_access(channel, %{}, :none)
      assert disabled.publishable_key == nil
      assert_api_error(publishable(channel.publishable_key), 401, "unauthorized")
    end

    test "a rotated key stops working at once", %{channel: channel} do
      {:ok, rotated} = Channels.update_client_access(channel, %{}, :new)

      assert_api_error(publishable(channel.publishable_key), 401, "unauthorized")
      assert json_response(publishable(rotated.publishable_key), 200)
    end

    test "the Origin must be allowed", %{channel: channel} do
      key = channel.publishable_key

      assert json_response(publishable(key, origin: "https://a.widgets.io"), 200)

      for origin <- [nil, "https://evil.example.com", "http://shop.example.com", "null"] do
        assert_api_error(publishable(key, origin: origin), 403, "origin_not_allowed")
      end
    end

    test "is limited per client IP before the key is looked up", %{channel: channel} do
      ip = unique_ip()

      for _ <- 1..10, do: assert(json_response(publishable(channel.publishable_key, ip: ip), 200))

      limited = publishable("cvg_pk_unknown", ip: ip)
      assert_api_error(limited, 429, "rate_limited")
      assert [_seconds] = get_resp_header(limited, "retry-after")
    end

    test "is limited per channel, with the tenant override", %{tenant: tenant, channel: channel} do
      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{
          "publishable_token" => %{"limit" => 2, "scale_ms" => 60_000}
        })

      assert json_response(publishable(channel.publishable_key), 200)
      assert json_response(publishable(channel.publishable_key), 200)
      assert_api_error(publishable(channel.publishable_key), 429, "rate_limited")
    end
  end

  describe "refresh" do
    test "keeps the source and uses the publishable bucket", %{tenant: tenant, channel: channel} do
      # The secret-based bucket is exhausted; publishable refreshes still work.
      {:ok, _} =
        Tenants.update_tenant_limits(tenant, %{
          "token_generate" => %{"limit" => 1, "scale_ms" => 60_000}
        })

      body = channel.publishable_key |> publishable() |> json_response(200)

      token =
        Enum.reduce(1..3, body["token"], fn _, token ->
          refreshed =
            bearer(token) |> post(~p"/api/v1/converger/tokens/refresh") |> json_response(200)

          assert {:ok, %{"src" => "publishable"} = claims} =
                   ConvergerToken.verify_token(refreshed["token"])

          assert claims["conversation_id"] == body["conversationId"]
          refreshed["token"]
        end)

      assert is_binary(token)
    end
  end

  describe "CORS" do
    defp preflight(path, origin) do
      build_conn()
      |> put_req_header("origin", origin)
      |> put_req_header("access-control-request-method", "POST")
      |> options(path)
    end

    test "the client API allows the origins of active publishable keys", %{channel: channel} do
      for path <- ["/api/v1/converger/tokens/publishable", "/api/v1/converger/tokens/refresh"] do
        assert get_resp_header(preflight(path, @origin), "access-control-allow-origin") == [
                 @origin
               ]

        assert get_resp_header(
                 preflight(path, "https://x.widgets.io"),
                 "access-control-allow-origin"
               ) ==
                 ["https://x.widgets.io"]

        assert get_resp_header(
                 preflight(path, "https://evil.example.com"),
                 "access-control-allow-origin"
               ) ==
                 []
      end

      {:ok, _} = Channels.update_client_access(channel, %{}, :none)

      assert get_resp_header(
               preflight("/api/v1/converger/tokens/refresh", @origin),
               "access-control-allow-origin"
             ) == []
    end

    test "other paths never gain origins from publishable keys" do
      for path <- ["/api/v1/conversations", "/admin/login"] do
        assert get_resp_header(preflight(path, @origin), "access-control-allow-origin") == []
      end
    end
  end
end
