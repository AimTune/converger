defmodule ConvergerWeb.Admin.WebhookLive do
  use ConvergerWeb, :live_view

  alias ConvergerWeb.Live.WebhooksPage

  # Platform event webhooks of every tenant. Viewers can browse; only
  # super_admin and admin can change subscriptions or redeliver.
  def mount(_params, _session, socket) do
    {:ok,
     WebhooksPage.mount(socket,
       tenant_id: nil,
       can_edit: socket.assigns.admin_role in ~w(super_admin admin),
       actor: build_actor(socket),
       tenants: Converger.Tenants.list_tenants()
     )}
  end

  def handle_params(params, _url, socket), do: WebhooksPage.handle_params(params, socket)

  def handle_event(event, params, socket), do: WebhooksPage.handle_event(event, params, socket)

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  def render(assigns), do: WebhooksPage.render(assigns)
end
