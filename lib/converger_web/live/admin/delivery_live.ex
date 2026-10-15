defmodule ConvergerWeb.Admin.DeliveryLive do
  use ConvergerWeb, :live_view

  alias ConvergerWeb.Live.DeliveriesPage

  # Dead-letter inspection and replay across all tenants. Viewers can browse
  # and export; only super_admin and admin can retry.
  def mount(_params, _session, socket) do
    {:ok,
     DeliveriesPage.mount(socket,
       base_path: "/admin/deliveries",
       tenant_id: nil,
       can_retry: socket.assigns.admin_role in ~w(super_admin admin),
       actor: build_actor(socket),
       channels: Converger.Channels.list_channels(),
       tenants: Converger.Tenants.list_tenants()
     )}
  end

  def handle_params(params, _url, socket), do: DeliveriesPage.handle_params(params, socket)

  def handle_event(event, params, socket), do: DeliveriesPage.handle_event(event, params, socket)

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  def render(assigns), do: DeliveriesPage.render(assigns)
end
