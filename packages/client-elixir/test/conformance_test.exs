defmodule ConvergerClient.ConformanceTest do
  use ExUnit.Case, async: true

  alias ConvergerClient.{ClientAPI, Conformance, Error, TenantAPI, Webhook}
  alias ConvergerClient.Protocol.Session

  @signatures Conformance.load("webhook-signatures.json")
  @errors Conformance.load("errors.json")
  @rest Conformance.load("rest.json")
  @protocol Conformance.load("protocol.json")

  describe "webhook signatures" do
    for v <- @signatures["sign"] do
      @v v
      test "sign #{v["name"]}" do
        assert Webhook.sign(@v["secret"], @v["body"], @v["timestamp"]) == @v["header"]
      end
    end

    for v <- @signatures["verify"] do
      @v v
      test "verify #{v["name"]}" do
        opts = [
          now: @v["now"],
          tolerance: @v["tolerance"] || @signatures["default_tolerance_seconds"]
        ]

        expected = if @v["valid"], do: :ok, else: {:error, String.to_atom(@v["error"])}
        assert Webhook.verify_signature(@v["headers"], @v["body"], @v["secret"], opts) == expected

        assert Webhook.verify_signature(
                 Map.to_list(@v["headers"]),
                 @v["body"],
                 @v["secret"],
                 opts
               ) == expected
      end
    end

    test "a fresh signature verifies with the clock" do
      header = Webhook.sign("whsec_x", "{}")
      assert Webhook.valid_signature?([{"x-converger-signature", header}], "{}", "whsec_x")
    end
  end

  describe "error normalization" do
    for c <- @errors["cases"] do
      @c c
      test @c["name"] do
        err = Error.from_response(@c["status"], @c["headers"], @c["body"])

        got =
          Map.new(@c["expected"], fn {k, _} ->
            {k, Map.fetch!(err, String.to_existing_atom(k))}
          end)

        assert got == @c["expected"]
      end
    end
  end

  describe "REST" do
    for c <- @rest["cases"] do
      @c c
      test @c["name"] do
        test_pid = self()
        resp = @c["response"]

        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:request, conn, body})

          conn
          |> then(fn conn ->
            Enum.reduce(resp["headers"] || %{}, conn, fn {k, v}, c ->
              Plug.Conn.put_resp_header(c, k, v)
            end)
          end)
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(resp["status"], Jason.encode!(resp["body"]))
        end

        client =
          ConvergerClient.new(@rest["client"]["base_url"],
            api_key: @rest["client"]["api_key"],
            channel_secret: @rest["client"]["channel_secret"],
            req_options: [plug: plug]
          )

        result = call(client, @c["operation"], @c["args"])

        assert_received {:request, conn, body}
        exp = @c["request"]
        assert conn.method == exp["method"]
        assert conn.request_path == exp["path"]
        assert URI.decode_query(conn.query_string) == exp["query"]

        for {name, value} <- exp["headers"] do
          [got | _] = Plug.Conn.get_req_header(conn, name)
          assert got |> String.split(";") |> hd() == value, name
        end

        if Map.has_key?(exp, "json"), do: assert(Jason.decode!(body) == exp["json"])

        case @c do
          %{"error" => expected} ->
            assert {:error, %Error{} = err} = result

            for {k, v} <- expected,
                do: assert(Map.fetch!(err, String.to_existing_atom(k)) == v, k)

          %{"result" => expected} ->
            assert {:ok, value} = result
            for {path, v} <- expected, do: assert(Conformance.resolve(value, path) == v, path)
        end
      end
    end

    test "the tenant API needs an API key" do
      assert {:error, %ArgumentError{}} =
               TenantAPI.get_conversation(ConvergerClient.new("http://x"), "c")
    end
  end

  defp call(client, op, a) do
    act = Map.new(a["activity"] || %{}, fn {k, v} -> {String.to_atom(k), v} end)

    case op do
      "client_api.generate_token" ->
        ClientAPI.generate_token(client, user_id: a["user_id"], scope: a["scope"])

      "client_api.refresh_token" ->
        ClientAPI.refresh_token(client, a["token"])

      "client_api.create_conversation" ->
        ClientAPI.create_conversation(client, a["token"])

      "client_api.get_conversation" ->
        ClientAPI.get_conversation(client, a["token"], a["conversation_id"],
          watermark: a["watermark"]
        )

      "client_api.close_conversation" ->
        ClientAPI.close_conversation(client, a["token"], a["conversation_id"])

      "client_api.reopen_conversation" ->
        ClientAPI.reopen_conversation(client, a["token"], a["conversation_id"])

      "client_api.post_activity" ->
        ClientAPI.post_activity(client, a["token"], a["conversation_id"], act,
          idempotency_key: a["idempotency_key"]
        )

      "client_api.list_activities" ->
        ClientAPI.list_activities(client, a["token"], a["conversation_id"],
          watermark: a["watermark"],
          limit: a["limit"]
        )

      "tenant_api.list_conversations" ->
        TenantAPI.list_conversations(client,
          limit: a["limit"],
          cursor: a["cursor"],
          status: a["status"],
          channel_id: a["channel_id"],
          external_id: a["external_id"]
        )

      "tenant_api.get_conversation" ->
        TenantAPI.get_conversation(client, a["conversation_id"])

      "tenant_api.close_conversation" ->
        TenantAPI.close_conversation(client, a["conversation_id"])

      "tenant_api.reopen_conversation" ->
        TenantAPI.reopen_conversation(client, a["conversation_id"])

      "tenant_api.post_activity" ->
        TenantAPI.post_activity(client, a["conversation_id"], act,
          idempotency_key: a["idempotency_key"]
        )

      "tenant_api.list_activities" ->
        TenantAPI.list_activities(client, a["conversation_id"],
          watermark: a["watermark"],
          limit: a["limit"]
        )
    end
  end

  describe "protocol session" do
    for sc <- @protocol["scenarios"] do
      @sc sc
      test @sc["name"] do
        init = @sc["initial"]
        session = Session.new(init["watermark"] || 0, init["conversation_id"])
        assert Session.hello(session) == @sc["hello"]

        @sc["steps"]
        |> Enum.with_index()
        |> Enum.reduce(session, fn {step, i}, session ->
          {session, out} = Session.on_frame(session, step["recv"])
          expect = step["expect"]

          labels =
            Enum.map(out.deliver, fn f ->
              if is_integer(f["seq"]), do: "#{f["type"]}:#{f["seq"]}", else: f["type"]
            end)

          assert labels == (expect["deliver"] || []), "step #{i} deliver"
          assert out.send == (expect["send"] || []), "step #{i} send"

          assert Enum.map(out.schedule, fn {ms, f} -> %{"after_ms" => ms, "frame" => f} end) ==
                   (expect["schedule"] || []),
                 "step #{i} schedule"

          if Map.has_key?(expect, "watermark"),
            do: assert(session.watermark == expect["watermark"], "step #{i} watermark")

          session
        end)
      end
    end
  end
end
