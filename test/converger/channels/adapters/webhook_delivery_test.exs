defmodule Converger.Channels.Adapters.WebhookDeliveryTest do
  # Mutates the global :webhook_req_options / :webhook config.
  use Converger.DataCase, async: false

  alias Converger.Activities.Activity
  alias Converger.Channels.Adapters.Webhook
  alias Converger.Channels.DeliveryError
  alias Converger.Channels.InboundSignature
  alias Converger.TestDnsResolver

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  @secret "test-channel-secret"

  setup do
    for key <- [:webhook_req_options, :webhook] do
      previous = Application.get_env(:converger, key)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, key, previous),
          else: Application.delete_env(:converger, key)
      end)
    end

    Application.put_env(:converger, :webhook_req_options, plug: {Req.Test, __MODULE__})
    :ok
  end

  defp channel(config) do
    %{
      id: nil,
      type: "webhook",
      secret: @secret,
      config: Map.merge(%{"url" => "https://hooks.example.com/in"}, config)
    }
  end

  defp activity do
    %Activity{
      id: Ecto.UUID.generate(),
      type: "message",
      sender: "user-1",
      text: "hello",
      attachments: [],
      metadata: %{},
      conversation_id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      seq: 1,
      inserted_at: ~U[2026-10-08 12:00:00.000000Z]
    }
  end

  defp capture_requests(response \\ fn conn -> Req.Test.json(conn, %{ok: true}) end) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:webhook_request, conn, body})
      response.(conn)
    end)
  end

  describe "outbound signing" do
    test "signs the exact body with the channel secret" do
      capture_requests()

      assert :ok = Webhook.deliver_activity(channel(%{}), activity())
      assert_received {:webhook_request, conn, body}

      [signature] = Plug.Conn.get_req_header(conn, "x-converger-signature")
      assert signature =~ ~r/^t=\d+,v1=[0-9a-f]{64}$/
      assert InboundSignature.verify(%{secret: @secret}, conn.req_headers, body) == :ok

      assert InboundSignature.verify(%{secret: "other"}, conn.req_headers, body) ==
               {:error, :invalid_signature}

      assert Plug.Conn.get_req_header(conn, "x-converger-event") == ["activity.created"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert %{"text" => "hello", "timestamp" => _} = Jason.decode!(body)
    end

    test "matches the documented test vector" do
      body = ~s({"id":"9b2f6c1e-0000-4000-8000-000000000001","text":"hello"})

      assert InboundSignature.sign("whsec_test_secret", body, 1_700_000_000) ==
               "t=1700000000,v1=c8945aa2aa4e6d043cdd46907fdf4ab1d4cedd12737ea10bb6f246ed39533a8a"
    end

    test "sends the delivery id of the activity/channel pair" do
      capture_requests()
      tenant = tenant_fixture()
      channel = webhook_channel_fixture(tenant)
      conversation = conversation_fixture(tenant, channel)

      # Creating the activity runs the inline pipeline, which delivers it.
      {:ok, activity} =
        Converger.Activities.create_activity(%{
          type: "message",
          sender: "user-1",
          text: "hi",
          tenant_id: tenant.id,
          conversation_id: conversation.id
        })

      assert_received {:webhook_request, conn, body}

      delivery =
        Converger.Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)

      assert Plug.Conn.get_req_header(conn, "x-converger-delivery-id") == [delivery.id]
      assert InboundSignature.verify(channel, conn.req_headers, body) == :ok
    end
  end

  describe "request hardening" do
    test "reserved user headers are stripped, others are sent" do
      capture_requests()

      config = %{
        "headers" => %{
          "Host" => "evil.internal",
          "Content-Length" => "1",
          "Transfer-Encoding" => "chunked",
          "X-Converger-Signature" => "forged",
          "Authorization" => "Bearer abc"
        }
      }

      assert :ok = Webhook.deliver_activity(channel(config), activity())
      assert_received {:webhook_request, conn, _body}

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer abc"]
      assert [signature] = Plug.Conn.get_req_header(conn, "x-converger-signature")
      refute signature == "forged"
      assert Plug.Conn.get_req_header(conn, "transfer-encoding") == []
      refute conn.host == "evil.internal"
    end

    test "uses the configured method" do
      capture_requests()
      assert :ok = Webhook.deliver_activity(channel(%{"method" => "patch"}), activity())
      assert_received {:webhook_request, %{method: "PATCH"}, _}
    end

    test "an invalid stored method fails the delivery instead of crashing" do
      capture_requests()

      assert {:error, message} =
               Webhook.deliver_activity(channel(%{"method" => "frobnicate"}), activity())

      assert DeliveryError.message(message) =~ "method"
      # A misconfigured method never succeeds: dead-letter, do not retry.
      refute message.retryable?
      refute_received {:webhook_request, _, _}
    end

    test "pins the request to the checked address" do
      capture_requests()
      assert :ok = Webhook.deliver_activity(channel(%{}), activity())
      assert_received {:webhook_request, conn, _}
      assert conn.host == "93.184.215.14"
    end

    test "redirects are not followed" do
      capture_requests(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, message} = Webhook.deliver_activity(channel(%{}), activity())
      assert DeliveryError.message(message) =~ "returned 302"
      refute message.retryable?
      assert_received {:webhook_request, _, _}
      refute_received {:webhook_request, _, _}
    end

    test "reads at most max_response_bytes of the response" do
      capture_requests(fn conn ->
        Plug.Conn.send_resp(conn, 500, String.duplicate("x", 5_000))
      end)

      assert {:error, message} =
               Webhook.deliver_activity(channel(%{"max_response_bytes" => 100}), activity())

      assert DeliveryError.message(message) =~ "returned 500"
      assert message.retryable?
      assert DeliveryError.message(message) =~ String.duplicate("x", 100)
      refute DeliveryError.message(message) =~ String.duplicate("x", 101)
    end
  end

  describe "SSRF guard at request time" do
    test "rejects a host that resolves to a private address after validation (DNS rebinding)" do
      capture_requests()
      config = %{"url" => "https://rebind.test/hook"}
      assert :ok = Webhook.validate_config(config)

      TestDnsResolver.put("rebind.test", {:ok, [{127, 0, 0, 1}]})

      assert {:error, message} = Webhook.deliver_activity(channel(config), activity())
      assert DeliveryError.message(message) =~ "rejected"
      refute message.retryable?
      refute_received {:webhook_request, _, _}
    end

    test "rejects stored private IP literals" do
      capture_requests()

      for url <- ["http://127.0.0.1:5432/", "http://169.254.169.254/latest", "http://[::1]/"] do
        assert {:error, _} = Webhook.deliver_activity(channel(%{"url" => url}), activity())
      end

      refute_received {:webhook_request, _, _}
    end

    test "fails when the host does not resolve" do
      assert {:error, message} =
               Webhook.deliver_activity(
                 channel(%{"url" => "https://unresolvable.test/"}),
                 activity()
               )

      assert DeliveryError.message(message) =~ "could not be resolved"
      # DNS failures may be transient.
      assert message.retryable?
    end

    test "allowed targets can be reached" do
      capture_requests()

      Application.put_env(:converger, :webhook,
        resolver: {TestDnsResolver, :resolve},
        allowed_targets: ["127.0.0.1"]
      )

      assert :ok =
               Webhook.deliver_activity(channel(%{"url" => "http://127.0.0.1:4000/"}), activity())

      assert_received {:webhook_request, _, _}
    end
  end

  describe "validate_config/1 SSRF guard" do
    test "rejects private, loopback, link-local and metadata targets" do
      for url <- [
            "http://127.0.0.1/hook",
            "http://localhost:4000/hook",
            "http://10.1.2.3/",
            "http://192.168.0.1/",
            "http://172.16.5.5/",
            "http://169.254.169.254/latest/meta-data",
            "http://100.100.100.200/",
            "http://0.0.0.0/",
            "http://[::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[fe80::1]/",
            "http://[fd00:ec2::254]/",
            "http://metadata.test/",
            "http://private.test/",
            "http://v6private.test/",
            "http://mixed.test/"
          ] do
        assert {:error, message} = Webhook.validate_config(%{"url" => url}), url
        assert message =~ "not allowed"
      end
    end

    test "accepts public targets and hosts that cannot be resolved yet" do
      assert :ok = Webhook.validate_config(%{"url" => "https://hooks.example.com/in"})
      assert :ok = Webhook.validate_config(%{"url" => "http://93.184.215.14/"})
      assert :ok = Webhook.validate_config(%{"url" => "https://unresolvable.test/"})
    end

    test "allowed_targets accepts listed hosts and ranges" do
      Application.put_env(:converger, :webhook,
        resolver: {TestDnsResolver, :resolve},
        allowed_targets: ["localhost", "10.0.0.0/8", "*.svc.local"]
      )

      TestDnsResolver.put("hook.svc.local", {:ok, [{172, 20, 0, 4}]})

      assert :ok = Webhook.validate_config(%{"url" => "http://localhost:4000/"})
      assert :ok = Webhook.validate_config(%{"url" => "http://10.9.9.9/"})
      assert :ok = Webhook.validate_config(%{"url" => "http://hook.svc.local/"})
      assert {:error, _} = Webhook.validate_config(%{"url" => "http://127.0.0.1/"})
    end

    test "allow_private_targets disables the guard" do
      Application.put_env(:converger, :webhook,
        resolver: {TestDnsResolver, :resolve},
        allow_private_targets: true
      )

      assert :ok = Webhook.validate_config(%{"url" => "http://127.0.0.1/hook"})
    end
  end
end
