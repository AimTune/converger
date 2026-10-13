defmodule ConvergerWeb.Portal.ChannelLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels

  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.current_tenant.id
    can_edit = socket.assigns.tenant_role in ~w(owner admin member)

    {:ok,
     assign(socket,
       channels: Channels.list_channels_for_tenant(tenant_id),
       page_title: "Channels",
       can_edit: can_edit
     )}
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if socket.assigns.can_edit do
      channel = Channels.get_channel!(id)

      # Ensure channel belongs to this tenant
      if channel.tenant_id == socket.assigns.current_tenant.id do
        toggle_channel_status(socket, channel)
      else
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    end
  end

  defp toggle_channel_status(socket, channel) do
    new_status = if channel.status == "active", do: "inactive", else: "active"

    case Channels.update_channel(channel, %{status: new_status}, build_actor(socket)) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           channels: Channels.list_channels_for_tenant(socket.assigns.current_tenant.id)
         )
         |> put_flash(:info, "Status updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  defp build_actor(socket) do
    case socket.assigns[:current_tenant_user] do
      %{email: email} -> %{type: "tenant_user", id: email}
      _ -> %{type: "tenant_user", id: "unknown"}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Channels
        <:subtitle>The messaging channels connected to your organization.</:subtitle>
      </.header>

      <.panel>
        <div class="overflow-x-auto">
          <.table id="channels" rows={@channels} row_id={&"channel-#{&1.id}"}>
            <:col :let={channel} label="Name">
              <span class="font-medium">{channel.name}</span>
            </:col>
            <:col :let={channel} label="Type"><.badge value={channel.type} /></:col>
            <:col :let={channel} label="Mode"><.badge value={channel.mode} /></:col>
            <:col :let={channel} label="Status"><.badge value={channel.status} /></:col>
            <:action :let={channel} :if={@can_edit}>
              <.button phx-click="toggle_status" phx-value-id={channel.id} size="xs" variant="neutral">
                {if channel.status == "active", do: "Disable", else: "Enable"}
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@channels == []}>No channels found.</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
