defmodule ConvergerWeb.Admin.TenantLive do
  use ConvergerWeb, :live_view

  alias Converger.Tenants
  alias Converger.Tenants.Tenant

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Converger.PubSub, "tenants")

    actor = build_actor(socket)

    {:ok,
     assign(socket,
       tenants: list_tenants(),
       page_title: "Tenants",
       form: to_form(Tenants.change_tenant(%Tenant{})),
       actor: actor
     )}
  end

  def handle_event("save", %{"tenant" => params}, socket) do
    case Tenants.create_tenant(params, socket.assigns.actor) do
      {:ok, _tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tenant created")
         |> assign(tenants: list_tenants(), form: to_form(Tenants.change_tenant(%Tenant{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    tenant = Tenants.get_tenant!(id)
    new_status = if tenant.status == "active", do: "inactive", else: "active"

    case Tenants.update_tenant(tenant, %{status: new_status}, socket.assigns.actor) do
      {:ok, _tenant} ->
        {:noreply, assign(socket, tenants: list_tenants()) |> put_flash(:info, "Status updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    tenant = Tenants.get_tenant!(id)

    case Tenants.delete_tenant(tenant, socket.assigns.actor) do
      {:ok, _} ->
        {:noreply, assign(socket, tenants: list_tenants()) |> put_flash(:info, "Tenant deleted")}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to delete tenant (ensure no active channels/conversations)"
         )}
    end
  end

  defp list_tenants do
    Tenants.list_tenants() |> Enum.sort_by(& &1.inserted_at, :desc)
  end

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Tenants</h1>

    <div class="card">
      <h3>Create Tenant</h3>
      <.form for={@form} phx-submit="save">
        <div style="display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap;">
          <div>
            <.input field={@form[:name]} placeholder="Tenant Name" />
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Alert Webhook URL</label>
            <input
              type="text"
              name="tenant[alert_webhook_url]"
              placeholder="https://example.com/alerts (optional)"
              style="padding: 8px; border: 1px solid #ddd; border-radius: 4px; min-width: 300px;"
            />
          </div>
          <button type="submit">Create</button>
        </div>
      </.form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Name</th>
            <th>API Key</th>
            <th>Alert Webhook</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={tenant <- @tenants}>
            <td><small><%= tenant.id %></small></td>
            <td><%= tenant.name %></td>
            <td><code style="font-size: 0.8em;"><%= tenant.api_key %></code></td>
            <td>
              <span :if={tenant.alert_webhook_url && tenant.alert_webhook_url != ""} style="font-size: 0.8em; color: #666;" title={tenant.alert_webhook_url}>
                <%= String.slice(tenant.alert_webhook_url, 0, 40) %><%= if String.length(tenant.alert_webhook_url) > 40, do: "..." %>
              </span>
              <span :if={!tenant.alert_webhook_url || tenant.alert_webhook_url == ""} style="color: #aaa;">—</span>
            </td>
            <td>
              <span class={"badge badge-#{tenant.status}"}>
                <%= tenant.status %>
              </span>
            </td>
            <td>
              <button phx-click="toggle_status" phx-value-id={tenant.id} class="badge">
                <%= if tenant.status == "active", do: "Disable", else: "Enable" %>
              </button>
              <button phx-click="delete" phx-value-id={tenant.id} phx-confirm="Are you sure?" class="badge badge-inactive">
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
