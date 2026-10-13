defmodule ConvergerWeb.WebhookSubscriptionController do
  @moduledoc """
  Platform event webhook subscriptions of the tenant (ADR-0053).

    * `GET /api/v1/webhook_subscriptions` - list
    * `POST /api/v1/webhook_subscriptions` - create (`{"webhook_subscription": {...}}`);
      the response is the only one that includes the signing `secret`
    * `GET /api/v1/webhook_subscriptions/:id` - show
    * `PATCH|PUT /api/v1/webhook_subscriptions/:id` - update
    * `DELETE /api/v1/webhook_subscriptions/:id` - delete (with its event log)
    * `POST /api/v1/webhook_subscriptions/:id/rotate_secret` - new secret,
      returned once
    * `GET /api/v1/webhook_event_types` - the event catalog

  Server-to-server only: requires the tenant API key (`x-api-key`). Errors
  use the API error envelope (`ConvergerWeb.APIError`, ADR-0050).
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Webhooks
  alias Converger.Webhooks.{Catalog, Subscription}
  alias ConvergerWeb.APIError

  plug ConvergerWeb.Plugs.TenantAuth,
    scopes: [create: "manage", update: "manage", delete: "manage", rotate_secret: "manage"]

  plug :require_api_key

  action_fallback ConvergerWeb.FallbackController

  tags(["Webhooks"])
  security([%{"apiKey" => []}])

  operation(:index,
    summary: "List webhook subscriptions",
    description: "Every platform event webhook subscription of the tenant. Not paginated.",
    operation_id: "listWebhookSubscriptions",
    responses:
      with_errors(
        %{200 => json_schema("Subscriptions", ref("WebhookSubscriptionList"))},
        [401, 403]
      )
  )

  def index(conn, _params) do
    render(conn, :index, subscriptions: Webhooks.list_subscriptions(conn.assigns.tenant.id))
  end

  operation(:show,
    summary: "Get a webhook subscription",
    operation_id: "getWebhookSubscription",
    parameters: [id: path_id("Subscription id")],
    responses:
      with_errors(
        %{200 => json_schema("The subscription", ref("WebhookSubscriptionResponse"))},
        [401, 403, 404]
      )
  )

  def show(conn, %{"id" => id}) do
    with {:ok, subscription} <- fetch(conn, id) do
      render(conn, :show, subscription: subscription)
    end
  end

  operation(:create,
    summary: "Create a webhook subscription",
    description:
      "The response is the only one, besides rotate_secret, that carries the signing `secret`.",
    operation_id: "createWebhookSubscription",
    request_body: json_schema("The subscription", ref("CreateWebhookSubscriptionRequest")),
    responses:
      with_errors(
        %{201 => json_schema("Created", ref("WebhookSubscriptionWithSecretResponse"))},
        [400, 401, 403, 422]
      )
  )

  def create(conn, %{"webhook_subscription" => params}) when is_map(params) do
    with {:ok, subscription} <-
           Webhooks.create_subscription(conn.assigns.tenant.id, params, build_actor(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, subscription: subscription, include_secret: true)
    end
  end

  def create(_conn, _params), do: {:error, "webhook_subscription object is required"}

  operation(:update,
    summary: "Update a webhook subscription",
    description: "A `secret` in the body is ignored; use rotate_secret.",
    operation_id: "updateWebhookSubscription",
    parameters: [id: path_id("Subscription id")],
    request_body: json_schema("Fields to change", ref("UpdateWebhookSubscriptionRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Updated", ref("WebhookSubscriptionResponse"))},
        [400, 401, 403, 404, 422]
      )
  )

  def update(conn, %{"id" => id, "webhook_subscription" => params}) when is_map(params) do
    with {:ok, subscription} <- fetch(conn, id),
         {:ok, subscription} <-
           Webhooks.update_subscription(
             subscription,
             Map.delete(params, "secret"),
             build_actor(conn)
           ) do
      render(conn, :show, subscription: subscription)
    end
  end

  def update(_conn, _params), do: {:error, "webhook_subscription object is required"}

  operation(:delete,
    summary: "Delete a webhook subscription",
    description: "Its event log is deleted with it.",
    operation_id: "deleteWebhookSubscription",
    parameters: [id: path_id("Subscription id")],
    responses: with_errors(%{204 => "Deleted"}, [401, 403, 404])
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, subscription} <- fetch(conn, id),
         {:ok, _} <- Webhooks.delete_subscription(subscription, build_actor(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:rotate_secret,
    summary: "Rotate a webhook subscription's secret",
    description: "Generates a new signing secret, returned once; the old one stops working.",
    operation_id: "rotateWebhookSubscriptionSecret",
    parameters: [webhook_subscription_id: path_id("Subscription id")],
    responses:
      with_errors(
        %{200 => json_schema("The new secret", ref("WebhookSubscriptionWithSecretResponse"))},
        [401, 403, 404, 422]
      )
  )

  def rotate_secret(conn, %{"webhook_subscription_id" => id}) do
    with {:ok, subscription} <- fetch(conn, id),
         {:ok, subscription} <-
           Webhooks.update_subscription(
             subscription,
             %{"secret" => Subscription.generate_secret()},
             build_actor(conn)
           ) do
      render(conn, :show, subscription: subscription, include_secret: true)
    end
  end

  operation(:event_types,
    summary: "List webhook event types",
    description: "The platform event catalog: every type a subscription can name.",
    operation_id: "listWebhookEventTypes",
    responses:
      with_errors(%{200 => json_schema("Event types", ref("WebhookEventTypeList"))}, [401, 403])
  )

  def event_types(conn, _params), do: json(conn, %{data: Catalog.types()})

  defp fetch(conn, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Subscription{} = subscription <-
           Converger.Repo.get_by(Subscription, id: id, tenant_id: conn.assigns.tenant.id) do
      {:ok, subscription}
    else
      _ -> {:error, :not_found}
    end
  end

  defp require_api_key(conn, _opts) do
    if get_req_header(conn, "x-api-key") == [] do
      conn
      |> APIError.send_error(:forbidden, "This endpoint requires the tenant API key (x-api-key)")
    else
      conn
    end
  end

  defp build_actor(conn), do: ConvergerWeb.Plugs.TenantAuth.actor(conn)
end
