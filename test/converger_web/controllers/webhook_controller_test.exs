defmodule ConvergerWeb.WebhookControllerTest do
  # Mutates the global :platform_webhook_req_options config.
  use ConvergerWeb.ConnCase, async: false

  import Converger.TenantsFixtures
  import Ecto.Query

  alias Converger.{Repo, Webhooks}
  alias Converger.Webhooks.Event

  setup %{conn: conn} do
    previous = Application.get_env(:converger, :platform_webhook_req_options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:converger, :platform_webhook_req_options, previous),
        else: Application.delete_env(:converger, :platform_webhook_req_options)
    end)

    Application.put_env(:converger, :platform_webhook_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 400, "nope") end
    )

    tenant = tenant_fixture()

    api =
      conn
      |> put_req_header("x-api-key", tenant.api_key)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, api: api, tenant: tenant}
  end

  defp create_body(attrs \\ %{}) do
    %{
      "webhook_subscription" =>
        Map.merge(
          %{
            "url" => "https://hooks.example.com/events",
            "events" => ["delivery.failed", "conversation.closed"],
            "description" => "CRM sync",
            "headers" => %{"authorization" => "Bearer abc"}
          },
          attrs
        )
    }
  end

  describe "subscriptions CRUD" do
    test "create returns the secret once, then list/show/update/delete", %{api: api} do
      conn = post(api, ~p"/api/v1/webhook_subscriptions", create_body())
      assert %{"data" => created} = json_response(conn, 201)
      assert "whsec_" <> _ = created["secret"]
      assert created["events"] == ["delivery.failed", "conversation.closed"]
      assert created["header_names"] == ["authorization"]
      refute Map.has_key?(created, "headers")

      id = created["id"]

      assert %{"data" => [listed]} =
               json_response(get(api, ~p"/api/v1/webhook_subscriptions"), 200)

      assert listed["id"] == id
      refute Map.has_key?(listed, "secret")

      assert %{"data" => shown} =
               json_response(get(api, ~p"/api/v1/webhook_subscriptions/#{id}"), 200)

      refute Map.has_key?(shown, "secret")

      conn =
        patch(api, ~p"/api/v1/webhook_subscriptions/#{id}", %{
          "webhook_subscription" => %{"enabled" => false, "secret" => "ignored-secret-value"}
        })

      assert %{"data" => %{"enabled" => false}} = json_response(conn, 200)
      assert Webhooks.get_subscription!(id).secret == created["secret"]

      conn = post(api, ~p"/api/v1/webhook_subscriptions/#{id}/rotate_secret")
      assert %{"data" => %{"secret" => rotated}} = json_response(conn, 200)
      refute rotated == created["secret"]

      assert response(delete(api, ~p"/api/v1/webhook_subscriptions/#{id}"), 204)
      assert json_response(get(api, ~p"/api/v1/webhook_subscriptions/#{id}"), 404)
    end

    test "invalid input is a 422", %{api: api} do
      conn =
        post(api, ~p"/api/v1/webhook_subscriptions", create_body(%{"events" => ["nope"]}))

      assert %{"errors" => %{"events" => [_]}} = json_response(conn, 422)

      conn =
        post(
          api,
          ~p"/api/v1/webhook_subscriptions",
          create_body(%{"url" => "http://private.test/"})
        )

      assert %{"errors" => %{"url" => [_]}} = json_response(conn, 422)
    end

    test "lists the event catalog", %{api: api} do
      assert %{"data" => types} = json_response(get(api, ~p"/api/v1/webhook_event_types"), 200)
      assert "delivery.failed" in types
      assert "participant.opted_out" in types
    end

    test "requires the API key", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/webhook_subscriptions"), 401)
    end
  end

  describe "tenant isolation" do
    test "another tenant's subscriptions and events are not visible", %{api: api, tenant: tenant} do
      other = tenant_fixture()

      {:ok, theirs} =
        Webhooks.create_subscription(other.id, %{
          "url" => "https://hooks.example.com/other",
          "events" => ["conversation.closed"]
        })

      Webhooks.emit(other.id, "conversation.closed", %{conversation_id: Ecto.UUID.generate()})
      [their_event] = Repo.all(from e in Event, where: e.subscription_id == ^theirs.id)

      assert json_response(get(api, ~p"/api/v1/webhook_subscriptions/#{theirs.id}"), 404)

      assert json_response(
               patch(api, ~p"/api/v1/webhook_subscriptions/#{theirs.id}", %{
                 "webhook_subscription" => %{"enabled" => false}
               }),
               404
             )

      assert json_response(delete(api, ~p"/api/v1/webhook_subscriptions/#{theirs.id}"), 404)
      assert json_response(get(api, ~p"/api/v1/webhook_events/#{their_event.id}"), 404)

      assert json_response(post(api, ~p"/api/v1/webhook_events/#{their_event.id}/redeliver"), 404)

      assert %{"data" => []} = json_response(get(api, ~p"/api/v1/webhook_subscriptions"), 200)
      assert %{"data" => []} = json_response(get(api, ~p"/api/v1/webhook_events"), 200)
      assert Webhooks.list_subscriptions(tenant.id) == []
      assert Repo.reload!(theirs).enabled
    end
  end

  describe "events" do
    test "list, filter, show and redeliver", %{api: api, tenant: tenant} do
      {:ok, subscription} =
        Webhooks.create_subscription(tenant.id, %{
          "url" => "https://hooks.example.com/events",
          "events" => ["conversation.closed"]
        })

      Webhooks.emit(tenant.id, "conversation.closed", %{conversation_id: "c-1", reason: "manual"})

      conn = get(api, ~p"/api/v1/webhook_events?status=failed&subscription_id=#{subscription.id}")
      assert %{"data" => [event], "meta" => %{"has_more" => false}} = json_response(conn, 200)
      assert event["type"] == "conversation.closed"
      assert event["status"] == "failed"
      assert event["response_status"] == 400
      assert event["payload"] == %{"conversation_id" => "c-1", "reason" => "manual"}

      assert %{"data" => []} =
               json_response(get(api, ~p"/api/v1/webhook_events?status=delivered"), 200)

      assert json_response(get(api, ~p"/api/v1/webhook_events?status=bogus"), 400)

      assert %{"data" => %{"id" => id}} =
               json_response(get(api, ~p"/api/v1/webhook_events/#{event["id"]}"), 200)

      assert id == event["id"]

      Application.put_env(:converger, :platform_webhook_req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end
      )

      conn = post(api, ~p"/api/v1/webhook_events/#{id}/redeliver")
      assert %{"data" => %{"status" => "delivered", "attempts" => 1}} = json_response(conn, 202)

      assert %{"error" => "not_failed"} =
               json_response(post(api, ~p"/api/v1/webhook_events/#{id}/redeliver"), 409)
    end
  end
end
