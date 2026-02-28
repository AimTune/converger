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
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}
    else
      channel = Channels.get_channel!(id)

      # Ensure channel belongs to this tenant
      if channel.tenant_id != socket.assigns.current_tenant.id do
        {:noreply, put_flash(socket, :error, "Unauthorized")}
      else
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
    <h1>Channels</h1>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Mode</th>
            <th>Status</th>
            <th :if={@can_edit}>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={channel <- @channels}>
            <td style="font-weight: 500;"><%= channel.name %></td>
            <td><span class="badge"><%= channel.type %></span></td>
            <td>
              <span class={"badge badge-#{channel.mode}"}><%= channel.mode %></span>
            </td>
            <td>
              <span class={"badge badge-#{channel.status}"}><%= channel.status %></span>
            </td>
            <td :if={@can_edit}>
              <button phx-click="toggle_status" phx-value-id={channel.id} class="badge">
                <%= if channel.status == "active", do: "Disable", else: "Enable" %>
              </button>
            </td>
          </tr>
          <tr :if={@channels == []}>
            <td colspan="5" style="text-align: center; color: #999;">No channels found.</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
