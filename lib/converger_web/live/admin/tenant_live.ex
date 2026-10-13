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
       revealed_key: nil,
       actor: actor
     )}
  end

  def handle_event("save", %{"tenant" => params}, socket) do
    case Tenants.create_tenant(params, socket.assigns.actor) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tenant created")
         |> assign(
           tenants: list_tenants(),
           form: to_form(Tenants.change_tenant(%Tenant{})),
           revealed_key: reveal(tenant)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("rotate_api_key", %{"id" => id}, socket) do
    tenant = Tenants.get_tenant!(id)

    case Tenants.rotate_api_key(tenant, actor: socket.assigns.actor) do
      {:ok, rotated} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key rotated")
         |> assign(tenants: list_tenants(), revealed_key: reveal(rotated))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate API key")}
    end
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, revealed_key: nil)}
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

  def handle_event("cycle_tier", %{"id" => id}, socket) do
    tenant = Tenants.get_tenant!(id)
    tiers = Tenant.tiers()
    index = Enum.find_index(tiers, &(&1 == tenant.tier)) || 0
    next = Enum.at(tiers, rem(index + 1, length(tiers)))

    case Tenants.update_tenant(tenant, %{tier: next}, socket.assigns.actor) do
      {:ok, _tenant} ->
        {:noreply, assign(socket, tenants: list_tenants()) |> put_flash(:info, "Tier updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update tier")}
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

  # The plaintext key only exists on the struct returned right after
  # creation/rotation; it is kept in the socket until dismissed.
  defp reveal(%Tenant{api_key: key} = tenant) when is_binary(key) do
    %{
      tenant_name: tenant.name,
      key: key,
      previous_expires_at: tenant.previous_api_key_expires_at
    }
  end

  defp reveal(_), do: nil

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
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Tenants
        <:subtitle>Organizations that own channels, conversations and API keys.</:subtitle>
      </.header>

      <.panel title="Create tenant">
        <.form for={@form} id="tenant-form" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
            <.input field={@form[:name]} label="Name" placeholder="Tenant name" />
            <div>
              <.input
                field={@form[:alert_webhook_url]}
                label="Alert webhook URL"
                placeholder="https://example.com/alerts (optional)"
              />
              <p class="-mt-1 text-xs text-base-content/60">
                Kept as a managed subscription on channel health events, see Webhooks.
              </p>
            </div>
            <.input field={@form[:tier]} type="select" label="Delivery tier" options={Tenant.tiers()} />
            <.input
              field={@form[:retention_days]}
              type="number"
              label="Retention (days)"
              min={Converger.Retention.min_retention_days()}
            />
          </div>
          <.button type="submit" variant="primary">Create</.button>
        </.form>
      </.panel>

      <div :if={@revealed_key} id="revealed-api-key" role="alert" class="alert alert-warning items-start">
        <.icon name="hero-key" class="size-6 shrink-0" />
        <div class="min-w-0 flex-1 space-y-2">
          <h3 class="font-semibold">API key for {@revealed_key.tenant_name}</h3>
          <p class="text-sm">Copy this key now. It is stored hashed and will not be shown again.</p>
          <code class="block rounded bg-base-100 p-2 font-mono text-sm break-all text-base-content">{@revealed_key.key}</code>
          <p :if={@revealed_key.previous_expires_at} class="text-xs">
            The previous key stays valid until {Calendar.strftime(
              @revealed_key.previous_expires_at,
              "%Y-%m-%d %H:%M UTC"
            )}.
          </p>
          <.button phx-click="dismiss_key" size="sm" variant="neutral">I have saved the key</.button>
        </div>
      </div>

      <.panel>
        <div class="overflow-x-auto">
          <.table id="tenants" rows={@tenants} row_id={&"tenant-#{&1.id}"}>
            <:col :let={tenant} label="Name">
              <div class="font-medium">{tenant.name}</div>
              <div class="font-mono text-xs text-base-content/60">{tenant.id}</div>
            </:col>
            <:col :let={tenant} label="API key">
              <code class="font-mono text-xs">{Tenant.masked_api_key(tenant)}</code>
            </:col>
            <:col :let={tenant} label="Alert webhook">
              <span
                :if={tenant.alert_webhook_url && tenant.alert_webhook_url != ""}
                class="block max-w-60 truncate text-xs text-base-content/70"
                title={tenant.alert_webhook_url}
              >
                {tenant.alert_webhook_url}
              </span>
              <span :if={!tenant.alert_webhook_url || tenant.alert_webhook_url == ""} class="text-base-content/40">
                —
              </span>
            </:col>
            <:col :let={tenant} label="Retention">{tenant.retention_days} days</:col>
            <:col :let={tenant} label="Status"><.badge value={tenant.status} /></:col>
            <:col :let={tenant} label="Tier">
              <button
                type="button"
                phx-click="cycle_tier"
                phx-value-id={tenant.id}
                class={["badge badge-sm cursor-pointer", badge_color(tenant.tier)]}
                title="Delivery queue tier: high → default → bulk (click to change)"
              >
                {tenant.tier}
              </button>
            </:col>
            <:action :let={tenant}>
              <.button phx-click="toggle_status" phx-value-id={tenant.id} size="xs" variant="neutral">
                {if tenant.status == "active", do: "Disable", else: "Enable"}
              </.button>
              <.button
                phx-click="rotate_api_key"
                phx-value-id={tenant.id}
                data-confirm="Generate a new API key? The current key stays valid for a grace period."
                size="xs"
                variant="neutral"
              >
                Rotate key
              </.button>
              <.button
                phx-click="delete"
                phx-value-id={tenant.id}
                data-confirm="Are you sure?"
                size="xs"
                variant="error"
              >
                Delete
              </.button>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@tenants == []}>No tenants yet.</.empty_state>
      </.panel>
    </Layouts.app>
    """
  end
end
