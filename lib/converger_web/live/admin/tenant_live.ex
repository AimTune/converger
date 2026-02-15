defmodule ConvergerWeb.Admin.TenantLive do
  use ConvergerWeb, :live_view

  alias Converger.Tenants
  alias Converger.Tenants.Tenant

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Converger.PubSub, "tenants")

    {:ok,
     assign(socket,
       tenants: list_tenants(),
       page_title: "Tenants",
       form: to_form(Tenants.change_tenant(%Tenant{}))
     )}
  end

  def handle_event("save", %{"tenant" => params}, socket) do
    case Tenants.create_tenant(params) do
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

    case Tenants.update_tenant(tenant, %{status: new_status}) do
      {:ok, _tenant} ->
        {:noreply, assign(socket, tenants: list_tenants()) |> put_flash(:info, "Status updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    tenant = Tenants.get_tenant!(id)

    case Tenants.delete_tenant(tenant) do
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

  def render(assigns) do
    ~H"""
    <h1>Tenants</h1>

    <div class="card">
      <h3>Create Tenant</h3>
      <.form for={@form} phx-submit="save">
        <.input field={@form[:name]} placeholder="Name" />
        <button type="submit">Create</button>
      </.form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Name</th>
            <th>API Key</th>
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
