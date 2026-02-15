defmodule ConvergerWeb.Admin.ChannelLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.Channels.Channel
  alias Converger.Tenants
  alias Converger.Auth.Token

  def mount(_params, _session, socket) do
    tenants = Tenants.list_tenants()
    # If no tenants exist, we can't create channels comfortably.

    {:ok,
     assign(socket,
       channels: Channels.list_channels(),
       tenants: tenants,
       form: to_form(Channels.change_channel(%Channel{})),
       page_title: "Channels"
     )}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    case Channels.create_channel(params) do
      {:ok, _channel} ->
        {:noreply,
         socket
         |> put_flash(:info, "Channel created")
         |> assign(
           channels: Channels.list_channels(),
           form: to_form(Channels.change_channel(%Channel{}))
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)
    new_status = if channel.status == "active", do: "inactive", else: "active"

    case Channels.update_channel(channel, %{status: new_status}) do
      {:ok, _} ->
        {:noreply,
         assign(socket, channels: Channels.list_channels()) |> put_flash(:info, "Status updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)

    case Channels.delete_channel(channel) do
      {:ok, _} ->
        {:noreply,
         assign(socket, channels: Channels.list_channels()) |> put_flash(:info, "Channel deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete channel")}
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Channels</h1>

    <div class="card">
      <h3>Create Channel</h3>
      <.form for={@form} phx-submit="save">
        <label>Tenant</label>
        <select name="channel[tenant_id]" required style="padding: 5px; margin-right: 10px;">
          <option value="">Select Tenant</option>
          <%= for tenant <- @tenants do %>
            <option value={tenant.id}><%= tenant.name %></option>
          <% end %>
        </select>
        <select name="channel[type]" required style="padding: 5px; margin-right: 10px;">
          <option value="webhook">Webhook</option>
          <option value="echo">Echo</option>
        </select>
        <.input field={@form[:name]} placeholder="Channel Name" />
        <button type="submit">Create</button>
      </.form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Name</th>
            <th>Token</th>
            <th>Type</th>
            <th>Tenant</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={channel <- @channels}>
            <td><small><%= channel.id %></small></td>
            <td><%= channel.name %></td>
            <td>
              <% {:ok, token, _} = Token.generate_channel_token(channel) %>
              <div style="max-width: 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title={token}>
                <code style="font-size: 0.8em;"><%= token %></code>
              </div>
              <button onclick={"navigator.clipboard.writeText('#{token}')"} class="badge" style="margin-top: 2px; cursor: pointer;">Copy</button>
              <input type="hidden" id={"token-#{channel.id}"} value={token} />
            </td>
            <td><span class="badge"><%= channel.type %></span></td>
            <td><%= if channel.tenant, do: channel.tenant.name, else: "-" %></td>
            <td>
              <span class={"badge badge-#{channel.status}"}>
                <%= channel.status %>
              </span>
            </td>
            <td>
              <button phx-click="toggle_status" phx-value-id={channel.id} class="badge">
                <%= if channel.status == "active", do: "Disable", else: "Enable" %>
              </button>
              <button phx-click="delete" phx-value-id={channel.id} phx-confirm="Are you sure?" class="badge badge-inactive">
                Delete
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
