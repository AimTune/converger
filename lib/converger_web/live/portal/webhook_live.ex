defmodule ConvergerWeb.Portal.WebhookLive do
  use ConvergerWeb, :live_view

  alias ConvergerWeb.Live.WebhooksPage

  # The tenant's platform event webhooks. Owners and admins manage them
  # (subscriptions carry signing secrets); members and viewers can browse.
  def mount(_params, _session, socket) do
    {:ok,
     WebhooksPage.mount(socket,
       tenant_id: socket.assigns.current_tenant.id,
       can_edit: socket.assigns.tenant_role in ~w(owner admin),
       actor: build_actor(socket),
       tenants: nil
     )}
  end

  def handle_event(event, params, socket), do: WebhooksPage.handle_event(event, params, socket)

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  def render(assigns), do: WebhooksPage.render(assigns)
end
