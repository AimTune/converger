defmodule ConvergerWeb.Portal.DeliveryLive do
  use ConvergerWeb, :live_view

  alias ConvergerWeb.Live.DeliveriesPage

  # The tenant's own deliveries. Owners, admins and members can retry.
  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id

    {:ok,
     DeliveriesPage.mount(socket,
       base_path: "/portal/deliveries",
       tenant_id: tenant_id,
       can_retry: socket.assigns.tenant_role in ~w(owner admin member),
       actor: build_actor(socket),
       channels: Converger.Channels.list_channels_for_tenant(tenant_id),
       tenants: nil
     )}
  end

  def handle_params(params, _url, socket), do: DeliveriesPage.handle_params(params, socket)

  def handle_event(event, params, socket), do: DeliveriesPage.handle_event(event, params, socket)

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  def render(assigns), do: DeliveriesPage.render(assigns)
end
