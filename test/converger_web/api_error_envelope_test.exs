defmodule ConvergerWeb.ApiErrorEnvelopeTest do
  @moduledoc """
  Every error path of the HTTP API answers the one envelope
  `{"error": {"code", "message", "details", "request_id"}}` (issue #45,
  ADR-0050): the fallback controller, the auth and rate-limit plugs, the
  exception handlers (404, 400, 406, 500), and the controller-specific
  errors. `assert_api_error/3` (ConvergerWeb.ConnCase) checks the shape, the
  code, the request id and the OpenAPI `ErrorResponse` schema.
  """
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.{APIError, FallbackController, SocketGuard}
  alias ConvergerWeb.Plugs.{AdminAuth, ConvergerAuth, RateLimit, TenantAuth}

  defp decode_sent({_status, _headers, body}), do: Jason.decode!(body)

  defp assert_envelope(body, code) do
    assert %{"error" => %{"code" => ^code} = error} = body
    assert error |> Map.keys() |> Enum.sort() == ~w(code details message request_id)
    OpenApiSpex.TestAssertions.assert_schema(body, "ErrorResponse", ConvergerWeb.ApiSpec.spec())
    error
  end

  describe "the code catalog" do
    test "every code has a status, a message and a description" do
      for {code, status, message, description} <- APIError.codes() do
        assert code =~ ~r/^[a-z_]+$/
        assert status in 400..599
        assert message != "" and description != ""
      end

      assert APIError.code_names() == Enum.uniq(APIError.code_names())
    end

    test "the OpenAPI ErrorCode enum is the catalog" do
      assert ConvergerWeb.ApiSpec.spec().components.schemas["ErrorCode"].enum ==
               APIError.code_names()
    end

    test "codes shared with Protocol v1 are spelled the same" do
      shared =
        ~w(bad_request invalid_watermark invalid_message unauthorized token_expired forbidden
           channel_inactive rate_limited payload_too_large conversation_closed internal unavailable)

      assert shared -- ConvergerWeb.Protocol.Frames.error_codes() == []
      assert shared -- APIError.code_names() == []
    end

    test "every code is documented in docs/api/errors.md" do
      doc = File.read!("docs/api/errors.md")

      for code <- APIError.code_names() do
        assert doc =~ "`#{code}`", "#{code} is missing from docs/api/errors.md"
      end
    end

    test "new/2 rejects unknown codes" do
      assert_raise ArgumentError, fn -> APIError.new(:no_such_code) end
    end
  end

  describe "FallbackController" do
    test "maps every error return to the envelope" do
      cases = [
        {{:error, :not_found}, 404, "not_found"},
        {{:error, :unauthorized}, 401, "unauthorized"},
        {{:error, :forbidden}, 403, "forbidden"},
        {{:error, :channel_inactive}, 400, "channel_inactive"},
        {{:error, :inbound_not_supported}, 400, "inbound_not_supported"},
        {{:error, :empty_inbound_message}, 422, "invalid_message"},
        {{:error, :delivery_enqueue_failed}, 503, "unavailable"},
        {{:error, :conversation_closed}, 409, "conversation_closed"},
        {{:error, :invalid_watermark}, 400, "invalid_watermark"},
        {{:error, :invalid_cursor}, 400, "bad_request"},
        {{:error, :not_failed}, 409, "not_failed"},
        {{:error, :something_unexpected}, 500, "internal"},
        {{:error, "Missing x-channel-token header"}, 400, "bad_request"},
        {{:error, APIError.new(:upstream_unavailable, "boom")}, 502, "upstream_unavailable"},
        {nil, 404, "not_found"}
      ]

      for {result, status, code} <- cases do
        conn =
          build_conn()
          |> put_resp_header("x-request-id", "req-42")
          |> FallbackController.call(result)

        error = assert_api_error(conn, status, code)
        assert error["request_id"] == "req-42"
      end
    end

    test "changesets are 422 with the errors per field in details" do
      changeset =
        %Converger.Activities.Activity{}
        |> Converger.Activities.Activity.client_changeset(%{"type" => "bogus"})

      error =
        build_conn()
        |> FallbackController.call({:error, changeset})
        |> assert_api_error(422, "invalid_message")

      assert %{"type" => ["is invalid"]} = error["details"]

      changeset =
        Ecto.Changeset.add_error(
          Ecto.Changeset.change({%{}, %{name: :string}}),
          :name,
          "can't be blank"
        )

      error =
        build_conn()
        |> FallbackController.call({:error, changeset})
        |> assert_api_error(422, "validation_failed")

      assert error["details"] == %{"name" => ["can't be blank"]}
    end
  end

  describe "plugs" do
    test "AdminAuth answers 403 forbidden" do
      conn = AdminAuth.call(%{build_conn() | remote_ip: {10, 9, 8, 7}}, AdminAuth.init([]))
      assert conn.halted
      assert_api_error(conn, 403, "forbidden")
    end

    test "TenantAuth answers 401 unauthorized" do
      conn = TenantAuth.call(build_conn(), TenantAuth.init([]))

      assert assert_api_error(conn, 401, "unauthorized")["message"] ==
               "Missing authentication headers"

      conn = build_conn() |> put_req_header("x-api-key", "nope") |> TenantAuth.call([])
      assert_api_error(conn, 401, "unauthorized")
    end

    test "ConvergerAuth: missing, invalid, expired token and inactive channel" do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      opts = ConvergerAuth.init(mode: :token)

      conn = ConvergerAuth.call(build_conn(), opts)
      assert_api_error(conn, 401, "unauthorized")

      conn =
        build_conn() |> put_req_header("authorization", "Bearer nope") |> ConvergerAuth.call(opts)

      assert_api_error(conn, 401, "unauthorized")

      {:ok, expired, _} = ConvergerToken.generate_token(channel, expires_in: -60)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{expired}")
        |> ConvergerAuth.call(opts)

      assert_api_error(conn, 401, "token_expired")

      {:ok, token, _} = ConvergerToken.generate_token(channel)
      {:ok, _} = Converger.Channels.update_channel(channel, %{status: "inactive"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> ConvergerAuth.call(opts)

      assert_api_error(conn, 403, "channel_inactive")
    end

    test "RateLimit answers 429 rate_limited with Retry-After and details" do
      opts =
        RateLimit.init(
          scope: :ip,
          key_prefix: "env-#{System.unique_integer()}",
          limit: 1,
          scale_ms: 60_000
        )

      build_conn() |> RateLimit.call(opts)
      conn = build_conn() |> RateLimit.call(opts)

      error = assert_api_error(conn, 429, "rate_limited")
      assert [_seconds] = get_resp_header(conn, "retry-after")
      assert error["details"]["retry_after_ms"] > 0
    end

    test "refused socket connections (draining, other) use the envelope" do
      conn = SocketGuard.handle_error(build_conn(), :draining)

      assert %{"details" => %{"reason" => "draining"}} =
               assert_api_error(conn, 503, "unavailable")

      conn = SocketGuard.handle_error(build_conn(), :unauthorized)
      assert_api_error(conn, 403, "forbidden")
    end
  end

  describe "exception handlers" do
    test "an unknown route is 404 not_found" do
      build_conn() |> get("/api/v1/no/such/route") |> assert_api_error(404, "not_found")
    end

    test "a malformed UUID is 400 bad_request" do
      tenant = tenant_fixture()

      body =
        assert_error_sent(400, fn ->
          build_conn()
          |> put_req_header("x-api-key", tenant.api_key)
          |> get("/api/v1/routing_rules/not-a-uuid")
        end)
        |> decode_sent()

      assert_envelope(body, "bad_request")
    end

    test "malformed JSON is 400 bad_request" do
      body =
        assert_error_sent(400, fn ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/api/v1/converger/tokens/generate", "{not json")
        end)
        |> decode_sent()

      assert_envelope(body, "bad_request")
    end

    test "an Accept header without JSON is 406 not_acceptable" do
      body =
        assert_error_sent(406, fn ->
          build_conn() |> put_req_header("accept", "text/html") |> get("/api/v1/routing_rules")
        end)
        |> decode_sent()

      assert_envelope(body, "not_acceptable")
    end

    test "500 does not leak the exception" do
      assert %{error: %{code: "internal", message: "Internal server error", details: nil}} =
               ConvergerWeb.ErrorJSON.render("500.json", %{})
    end
  end

  describe "controller-specific errors" do
    setup do
      tenant = tenant_fixture()
      channel = channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)
      {:ok, token, _} = ConvergerToken.generate_token(channel)
      %{tenant: tenant, channel: channel, conversation: conversation, token: token}
    end

    test "unknown attachment is 404 not_found", %{token: token} do
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/converger/attachments/#{Ecto.UUID.generate()}")
      |> assert_api_error(404, "not_found")
    end

    test "Protocol socket: unsupported subprotocol and no upgrade" do
      error =
        build_conn()
        |> put_req_header("sec-websocket-protocol", "bogus.v9")
        |> get("/socket/converger/v1")
        |> assert_api_error(400, "unsupported_protocol")

      assert is_list(error["details"]["supported"])

      build_conn() |> get("/socket/converger/v1") |> assert_api_error(426, "upgrade_required")
    end

    test "an invalid inbound signature is 401 unauthorized", %{tenant: tenant} do
      channel = webhook_channel_fixture(tenant)

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-converger-signature", "t=1,v1=deadbeef")
      |> post("/api/v1/channels/#{channel.id}/inbound", Jason.encode!(%{"text" => "hi"}))
      |> assert_api_error(401, "unauthorized")
    end

    test "a channel token where the API key is required is 403 forbidden", %{channel: channel} do
      {:ok, channel_token, _} = Converger.Auth.Token.generate_channel_token(channel)

      error =
        build_conn()
        |> put_req_header("x-channel-token", channel_token)
        |> get("/api/v1/conversations")
        |> assert_api_error(403, "forbidden")

      assert error["message"] =~ "x-api-key"
    end

    test "the API docs routes answer 404 not_found when disabled" do
      original = Application.get_env(:converger, :api_docs)
      Application.put_env(:converger, :api_docs, enabled: false)
      on_exit(fn -> Application.put_env(:converger, :api_docs, original) end)

      build_conn() |> get("/api/docs") |> assert_api_error(404, "not_found")
      build_conn() |> get("/api/openapi.json") |> assert_api_error(404, "not_found")
    end
  end
end
