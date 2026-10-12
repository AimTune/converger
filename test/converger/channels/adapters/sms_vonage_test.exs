defmodule Converger.Channels.Adapters.SmsVonageTest do
  use ExUnit.Case, async: false

  alias Converger.Channels.Adapters.SmsVonage
  alias Converger.Channels.DeliveryError

  @basic %{"api_key" => "key", "api_secret" => "secret", "from" => "ACME"}

  setup do
    Application.put_env(:converger, :sms_req_options, plug: {Req.Test, __MODULE__}, retry: false)
    on_exit(fn -> Application.delete_env(:converger, :sms_req_options) end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:vonage, Plug.Conn.get_req_header(conn, "authorization"), body})
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"message_uuid" => "uuid-1"})
    end)

    pem =
      {:rsa, 2048, 65_537}
      |> :public_key.generate_key()
      |> then(&:public_key.pem_entry_encode(:RSAPrivateKey, &1))
      |> List.wrap()
      |> :public_key.pem_encode()

    %{pem: pem}
  end

  defp activity(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        conversation_id: nil,
        text: "hi",
        attachments: [],
        metadata: %{"to" => "+14155550100"}
      },
      attrs
    )
  end

  defp channel(config), do: %{id: nil, config: config}

  describe "validate_config/1" do
    test "needs basic or application credentials", %{pem: pem} do
      assert SmsVonage.validate_config(@basic) == :ok

      assert SmsVonage.validate_config(%{
               "application_id" => "app",
               "private_key" => pem,
               "from" => "ACME"
             }) == :ok

      assert {:error, _} = SmsVonage.validate_config(%{"from" => "ACME", "api_key" => "key"})

      assert {:error, msg} =
               SmsVonage.validate_config(%{"application_id" => "app", "private_key" => "nope"})

      assert msg =~ "private_key"
    end
  end

  describe "deliver_activity/2" do
    test "basic auth, E.164 without +, the activity id as client_ref" do
      activity = activity(%{})

      assert {:ok, %{provider_message_id: "uuid-1", sms_segments: 1}} =
               SmsVonage.deliver_activity(channel(@basic), activity)

      assert_received {:vonage, ["Basic " <> _], body}

      assert %{"to" => "14155550100", "from" => "ACME", "channel" => "sms", "client_ref" => ref} =
               Jason.decode!(body)

      assert ref == activity.id
    end

    test "an application JWT signed with the private key", %{pem: pem} do
      config = %{"application_id" => "app-1", "private_key" => pem, "from" => "ACME"}
      assert {:ok, _} = SmsVonage.deliver_activity(channel(config), activity(%{}))

      assert_received {:vonage, ["Bearer " <> token], _body}
      assert {:ok, claims} = Joken.verify(token, Joken.Signer.create("RS256", %{"pem" => pem}))
      assert claims["application_id"] == "app-1"
      assert is_binary(claims["jti"])
    end

    test "an empty text is a permanent error" do
      assert {:error, %DeliveryError{retryable?: false}} =
               SmsVonage.deliver_activity(channel(@basic), activity(%{text: "  "}))
    end
  end

  describe "parsing" do
    test "a status webhook is not a message; statuses are mapped" do
      params = %{"message_uuid" => "u1", "status" => "delivered", "to" => "1"}
      assert SmsVonage.parse_inbound(channel(@basic), params) == {:ok, []}

      for {vonage, ours} <- [
            {"submitted", "sent"},
            {"delivered", "delivered"},
            {"read", "read"},
            {"rejected", "failed"},
            {"undeliverable", "failed"}
          ] do
        params = %{"message_uuid" => "u1", "status" => vonage}

        assert {:ok, [%{"status" => ^ours}]} =
                 SmsVonage.parse_status_update(channel(@basic), params)
      end
    end

    test "a failure carries the Vonage error" do
      params = %{
        "message_uuid" => "u1",
        "status" => "rejected",
        "error" => %{"title" => "Invalid number", "detail" => "Not a mobile"}
      }

      assert {:ok, [%{"error" => "Vonage: Invalid number: Not a mobile"}]} =
               SmsVonage.parse_status_update(channel(@basic), params)
    end
  end

  describe "verify_inbound_signature/3" do
    defp token(claims, secret \\ "sig") do
      {:ok, token, _} = Joken.encode_and_sign(claims, Joken.Signer.create("HS256", secret))
      [{"authorization", "Bearer " <> token}]
    end

    defp hash(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    test "checks the JWT and the payload hash" do
      channel = channel(Map.put(@basic, "signature_secret", "sig"))
      body = ~s({"message_uuid":"u1"})

      assert SmsVonage.verify_inbound_signature(
               channel,
               token(%{"payload_hash" => hash(body)}),
               body
             ) ==
               :ok

      assert SmsVonage.verify_inbound_signature(
               channel,
               token(%{"payload_hash" => hash(body)}),
               body <> " "
             ) == {:error, :invalid_signature}

      assert SmsVonage.verify_inbound_signature(channel, token(%{"iss" => "Vonage"}), body) ==
               {:error, :invalid_signature}

      assert SmsVonage.verify_inbound_signature(
               channel,
               token(%{"payload_hash" => hash(body)}, "other"),
               body
             ) == {:error, :invalid_signature}
    end

    test "missing token or secret" do
      assert SmsVonage.verify_inbound_signature(channel(@basic), [], "") == :missing

      assert SmsVonage.verify_inbound_signature(channel(@basic), token(%{}), "") == :missing
    end
  end
end
