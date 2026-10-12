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

  Server-to-server only: requires the tenant API key (`x-api-key`).
  """
  use ConvergerWeb, :controller

  alias Converger.Webhooks
  alias Converger.Webhooks.{Catalog, Subscription}

  plug ConvergerWeb.Plugs.TenantAuth
  plug :require_api_key

  action_fallback ConvergerWeb.FallbackController

  def index(conn, _params) do
    render(conn, :index, subscriptions: Webhooks.list_subscriptions(conn.assigns.tenant.id))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, subscription} <- fetch(conn, id) do
      render(conn, :show, subscription: subscription)
    end
  end

  def create(conn, %{"webhook_subscription" => params}) when is_map(params) do
    with {:ok, subscription} <-
           Webhooks.create_subscription(conn.assigns.tenant.id, params, build_actor(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, subscription: subscription, include_secret: true)
    end
  end

  def create(_conn, _params), do: {:error, "webhook_subscription object is required"}

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

  def delete(conn, %{"id" => id}) do
    with {:ok, subscription} <- fetch(conn, id),
         {:ok, _} <- Webhooks.delete_subscription(subscription, build_actor(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

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
      |> ConvergerWeb.FallbackController.call({:error, :forbidden})
      |> halt()
    else
      conn
    end
  end

  defp build_actor(conn), do: %{type: "tenant_api", id: conn.assigns.tenant.id}
end
