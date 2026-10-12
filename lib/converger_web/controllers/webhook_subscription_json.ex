defmodule ConvergerWeb.WebhookSubscriptionJSON do
  alias Converger.Webhooks.Subscription

  def index(%{subscriptions: subscriptions}) do
    %{data: for(subscription <- subscriptions, do: data(subscription, false))}
  end

  def show(%{subscription: subscription} = assigns) do
    %{data: data(subscription, Map.get(assigns, :include_secret, false))}
  end

  @doc """
  A subscription as JSON. Header values are never returned (they may be
  credentials), only their names; the secret only when `include_secret`.
  """
  def data(%Subscription{} = subscription, include_secret) do
    base = %{
      id: subscription.id,
      tenant_id: subscription.tenant_id,
      url: subscription.url,
      description: subscription.description,
      events: subscription.events,
      enabled: subscription.enabled,
      header_names: Map.keys(subscription.headers || %{}),
      managed_by: subscription.managed_by,
      inserted_at: subscription.inserted_at,
      updated_at: subscription.updated_at
    }

    if include_secret, do: Map.put(base, :secret, subscription.secret), else: base
  end
end
