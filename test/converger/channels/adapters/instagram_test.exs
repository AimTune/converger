defmodule Converger.Channels.Adapters.InstagramTest do
  # Global Req stub (config :converger, :instagram_req_options): not async.
  use ConvergerWeb.ConnCase

  import Converger.TenantsFixtures

  alias Converger.Activities.Activity
  alias Converger.{Channels, Repo, Uploads}
  alias Converger.Channels.{Adapter, DeliveryError, InboundSignature}
  alias Converger.Channels.Adapters.Instagram

  @app_secret "instagram-app-secret"
  @account_id "17841400000000001"
  @igsid "5432109876543210"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::size(256)>>

  setup do
    Application.put_env(:converger, :instagram_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:converger, :instagram_req_options) end)

    tenant = tenant_fixture()

    {:ok, channel} =
      Channels.create_channel(%{
        name: "instagram-#{System.unique_integer([:positive])}",
        type: "instagram",
        mode: "duplex",
        status: "active",
        tenant_id: tenant.id,
        config: %{
          "account_id" => @account_id,
          "access_token" => "ig-token",
          "api_host" => "graph.instagram.com",
          "verify_token" => "verify-ig",
          "app_secret" => @app_secret
        }
      })

    %{tenant: tenant, channel: channel}
  end

  defp stub_graph(respond) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:graph, conn.method, conn.host, conn.request_path, body})
      respond.(conn, body)
    end)
  end

  defp activity(attrs) do
    struct(
      Activity,
      Map.merge(
        %{text: nil, attachments: [], metadata: %{"recipient_id" => @igsid}},
        Map.new(attrs)
      )
    )
  end

  defp webhook(events) do
    %{"object" => "instagram", "entry" => [%{"id" => @account_id, "messaging" => events}]}
  end

  defp event(extra) do
    Map.merge(
      %{
        "sender" => %{"id" => @igsid},
        "recipient" => %{"id" => @account_id},
        "timestamp" => 1_700_000_000_123
      },
      extra
    )
  end

  test "is registered as a duplex built-in" do
    assert {:ok, Instagram} = Adapter.adapter_for("instagram")
    assert Instagram.supported_modes() == ~w(inbound outbound duplex)
    assert Adapter.rate_limit("instagram") == "100/s"
  end

  test "config checks the account id and API host" do
    base = %{"account_id" => @account_id, "access_token" => "t", "verify_token" => "v"}
    assert :ok = Adapter.validate_config("instagram", base)
    assert {:error, _} = Adapter.validate_config("instagram", %{base | "account_id" => "me"})

    assert {:error, message} =
             Adapter.validate_config("instagram", Map.put(base, "api_host", "evil.example"))

    assert message =~ "api_host"
  end

  test "a signed DM with a story reply creates an activity", %{conn: conn, channel: channel} do
    params =
      webhook([
        event(%{
          "message" => %{
            "mid" => "aWdfZAG1-in",
            "text" => "Love this!",
            "reply_to" => %{"story" => %{"url" => "https://lookaside.fbsbx.com/s", "id" => "1"}}
          }
        })
      ])

    body = Jason.encode!(params)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", InboundSignature.sign_legacy(@app_secret, body))
      |> post(~p"/api/v1/channels/#{channel.id}/inbound", body)

    assert %{"activity_ids" => [id]} = json_response(conn, 200)
    activity = Repo.get!(Activity, id)
    assert activity.text == "Love this!"
    assert activity.metadata["story"]["id"] == "1"
    assert activity.metadata["instagram_recipient_id"] == @account_id
  end

  test "a page webhook is not an Instagram webhook", %{channel: channel} do
    assert {:error, _} = Instagram.parse_inbound(channel, %{"object" => "page", "entry" => []})
  end

  test "read receipts name the message", %{channel: channel} do
    assert {:ok,
            [%{"provider_message_id" => "m1", "status" => "read", "timestamp" => 1_700_000_000}]} =
             Instagram.parse_status_update(
               channel,
               webhook([event(%{"read" => %{"mid" => "m1"}})])
             )
  end

  test "sends on graph.instagram.com and splits long text", %{channel: channel} do
    stub_graph(fn conn, _ ->
      Req.Test.json(conn, %{"message_id" => "m-#{System.unique_integer()}"})
    end)

    text = String.duplicate("word ", 150)

    assert {:ok, %{meta_message_ids: [_, _]}} =
             Instagram.deliver_activity(channel, activity(text: text))

    assert_received {:graph, "POST", "graph.instagram.com",
                     "/v26.0/" <> @account_id <> "/messages", first}

    assert String.length(Jason.decode!(first)["message"]["text"]) <= 500
  end

  test "a file stored in Converger cannot be sent", %{channel: channel, tenant: tenant} do
    {:ok, stored} = Uploads.create_attachment(tenant.id, {"photo.png", @png})

    activity =
      activity(
        attachments: [
          %{
            "contentType" => "image/png",
            "contentUrl" => "/api/v1/converger/attachments/#{stored.id}"
          }
        ]
      )

    assert {:error, %DeliveryError{retryable?: false, reason: reason}} =
             Instagram.deliver_activity(channel, activity)

    assert reason =~ "public contentUrl"
  end

  test "rate limit errors are retried", %{channel: channel} do
    stub_graph(fn conn, _ ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => %{"code" => 80_002}})
    end)

    assert {:error, %DeliveryError{retryable?: true}} =
             Instagram.deliver_activity(channel, activity(text: "hi"))
  end
end
