defmodule ConvergerWeb.Admin.ChannelLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.Channels.Channel
  alias Converger.Channels.Adapter
  alias Converger.Channels.Health
  alias Converger.Tenants
  alias Converger.Auth.Token

  @default_type "webhook"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      ConvergerWeb.Endpoint.subscribe("channel_health")
    end

    tenants = Tenants.list_tenants()
    actor = build_actor(socket)
    supported = Adapter.supported_modes(@default_type)
    channels = Channels.list_channels()
    health_map = load_health_map(channels)

    {:ok,
     assign(socket,
       channels: channels,
       tenants: tenants,
       form: to_form(Channels.change_channel(%Channel{})),
       mode_filter: "all",
       selected_type: @default_type,
       supported_modes: supported,
       selected_mode: default_mode(supported),
       health_map: health_map,
       page_title: "Channels",
       actor: actor
     )}
  end

  def handle_info(%{event: "health_changed", payload: payload}, socket) do
    health_map =
      Map.put(socket.assigns.health_map, payload.channel_id, %{
        status: payload.status,
        failure_rate: payload.failure_rate,
        total_deliveries: payload.total_deliveries,
        failed_deliveries: payload.failed_deliveries
      })

    {:noreply, assign(socket, health_map: health_map)}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    case Channels.create_channel(params, socket.assigns.actor) do
      {:ok, _channel} ->
        supported = Adapter.supported_modes(@default_type)
        channels = load_channels(socket.assigns.mode_filter)

        {:noreply,
         socket
         |> put_flash(:info, "Channel created")
         |> assign(
           channels: channels,
           health_map: load_health_map(channels),
           form: to_form(Channels.change_channel(%Channel{})),
           selected_type: @default_type,
           supported_modes: supported,
           selected_mode: default_mode(supported)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("form_changed", %{"channel" => %{"type" => type}}, socket) do
    supported = Adapter.supported_modes(type)
    mode = if socket.assigns.selected_mode in supported, do: socket.assigns.selected_mode, else: default_mode(supported)

    {:noreply,
     assign(socket,
       selected_type: type,
       supported_modes: supported,
       selected_mode: mode
     )}
  end

  def handle_event("form_changed", _params, socket), do: {:noreply, socket}

  def handle_event("filter_mode", %{"mode" => mode}, socket) do
    channels = load_channels(mode)
    {:noreply, assign(socket, channels: channels, health_map: load_health_map(channels), mode_filter: mode)}
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)
    new_status = if channel.status == "active", do: "inactive", else: "active"

    case Channels.update_channel(channel, %{status: new_status}, socket.assigns.actor) do
      {:ok, _} ->
        channels = load_channels(socket.assigns.mode_filter)

        {:noreply,
         assign(socket, channels: channels, health_map: load_health_map(channels))
         |> put_flash(:info, "Status updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)

    case Channels.delete_channel(channel, socket.assigns.actor) do
      {:ok, _} ->
        channels = load_channels(socket.assigns.mode_filter)

        {:noreply,
         assign(socket, channels: channels, health_map: load_health_map(channels))
         |> put_flash(:info, "Channel deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete channel")}
    end
  end

  defp load_channels("all"), do: Channels.list_channels()
  defp load_channels(mode), do: Channels.list_channels_by_mode(mode)

  defp load_health_map(channels) do
    channel_ids = Enum.map(channels, & &1.id)
    Health.get_latest_health_map(channel_ids)
  end

  defp health_color("healthy"), do: "#4CAF50"
  defp health_color("degraded"), do: "#FF9800"
  defp health_color("unhealthy"), do: "#f44336"
  defp health_color(_), do: "#9E9E9E"

  defp health_label("healthy"), do: "Healthy"
  defp health_label("degraded"), do: "Degraded"
  defp health_label("unhealthy"), do: "Unhealthy"
  defp health_label(_), do: "—"

  defp channel_health_status(health_map, channel_id) do
    case Map.get(health_map, channel_id) do
      %{status: status} -> status
      _ -> "unknown"
    end
  end

  defp build_actor(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> %{type: "admin", id: address |> :inet.ntoa() |> to_string()}
      _ -> %{type: "admin", id: "unknown"}
    end
  end

  defp default_mode(supported) do
    cond do
      "duplex" in supported -> "duplex"
      "outbound" in supported -> "outbound"
      true -> hd(supported)
    end
  end

  defp config_summary(%{type: "webhook", config: %{"url" => url}}) when url != "", do: url
  defp config_summary(%{type: "whatsapp_meta", config: %{"phone_number_id" => id}}) when id != "", do: "Phone: #{id}"
  defp config_summary(%{type: "whatsapp_infobip", config: %{"sender" => s}}) when s != "", do: "Sender: #{s}"
  defp config_summary(_), do: ""

  defp config_detail(%{config: config}) when config == %{}, do: ""
  defp config_detail(%{config: config}) do
    config
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.map_join("\n", fn {k, v} ->
      if k in ["access_token", "api_key", "verify_token"],
        do: "#{k}: ****",
        else: "#{k}: #{v}"
    end)
  end

  defp config_fields("webhook") do
    [
      {"url", "Webhook URL", "https://example.com/webhook", :text},
      {"method", "HTTP Method", "POST", :text}
    ]
  end

  defp config_fields("whatsapp_meta") do
    [
      {"phone_number_id", "Phone Number ID", "e.g. 1234567890", :text},
      {"access_token", "Access Token", "Graph API access token", :password},
      {"verify_token", "Verify Token", "Webhook verify token", :password}
    ]
  end

  defp config_fields("whatsapp_infobip") do
    [
      {"base_url", "Base URL", "https://xxxxx.api.infobip.com", :text},
      {"api_key", "API Key", "Infobip API key", :password},
      {"sender", "Sender", "Sender phone number", :text}
    ]
  end

  defp config_fields(_), do: []

  defp mode_label("inbound"), do: "← Inbound (receive only)"
  defp mode_label("outbound"), do: "→ Outbound (send only)"
  defp mode_label("duplex"), do: "↔ Duplex (send & receive)"

  defp mode_indicator("inbound"), do: "← Inbound"
  defp mode_indicator("outbound"), do: "→ Outbound"
  defp mode_indicator("duplex"), do: "↔ Duplex"

  def render(assigns) do
    ~H"""
    <h1>Channels</h1>

    <div class="card">
      <h3>Create Channel</h3>
      <.form for={@form} phx-submit="save" phx-change="form_changed">
        <div style="display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap;">
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Tenant</label>
            <select name="channel[tenant_id]" required style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">Select Tenant</option>
              <%= for tenant <- @tenants do %>
                <option value={tenant.id}><%= tenant.name %></option>
              <% end %>
            </select>
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Type</label>
            <select name="channel[type]" required style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <%= for type <- Channel.channel_types() do %>
                <option value={type} selected={type == @selected_type}><%= type %></option>
              <% end %>
            </select>
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Mode</label>
            <select name="channel[mode]" required style="padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <%= for mode <- @supported_modes do %>
                <option value={mode} selected={mode == @selected_mode}><%= mode_label(mode) %></option>
              <% end %>
            </select>
          </div>
          <div>
            <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;">Name</label>
            <.input field={@form[:name]} placeholder="Channel Name" />
          </div>
        </div>

        <div :if={config_fields(@selected_type) != []} style="margin-top: 12px; padding: 12px; background: #f8f9fa; border-radius: 6px; border: 1px solid #e9ecef;">
          <h4 style="margin: 0 0 10px 0; font-size: 0.9em; color: #555;">Configuration</h4>
          <div style="display: flex; gap: 10px; flex-wrap: wrap;">
            <div :for={{key, label, placeholder, type} <- config_fields(@selected_type)}>
              <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.85em; color: #555;"><%= label %></label>
              <input
                type={if type == :password, do: "password", else: "text"}
                name={"channel[config][#{key}]"}
                placeholder={placeholder}
                style="padding: 8px; border: 1px solid #ddd; border-radius: 4px; min-width: 200px;"
              />
            </div>
          </div>
        </div>

        <div style="margin-top: 12px;">
          <button type="submit" style="height: 38px;">Create</button>
        </div>
      </.form>
    </div>

    <div style="margin-bottom: 15px; display: flex; gap: 8px;">
      <button phx-click="filter_mode" phx-value-mode="all"
        class={"badge #{if @mode_filter == "all", do: "badge-active", else: ""}"}>
        All
      </button>
      <button phx-click="filter_mode" phx-value-mode="inbound"
        class={"badge #{if @mode_filter == "inbound", do: "badge-inbound", else: ""}"}>
        ← Inbound
      </button>
      <button phx-click="filter_mode" phx-value-mode="outbound"
        class={"badge #{if @mode_filter == "outbound", do: "badge-outbound", else: ""}"}>
        → Outbound
      </button>
      <button phx-click="filter_mode" phx-value-mode="duplex"
        class={"badge #{if @mode_filter == "duplex", do: "badge-duplex", else: ""}"}>
        ↔ Duplex
      </button>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Mode</th>
            <th>Tenant</th>
            <th>Status</th>
            <th>Health</th>
            <th>Config</th>
            <th>Token</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={channel <- @channels}>
            <td style="font-weight: 500;"><%= channel.name %></td>
            <td><span class="badge"><%= channel.type %></span></td>
            <td>
              <span class={"badge badge-#{channel.mode}"}>
                <%= mode_indicator(channel.mode) %>
              </span>
            </td>
            <td><%= if channel.tenant, do: channel.tenant.name, else: "-" %></td>
            <td>
              <span class={"badge badge-#{channel.status}"}>
                <%= channel.status %>
              </span>
            </td>
            <td>
              <% health_status = channel_health_status(@health_map, channel.id) %>
              <span style={"display: inline-flex; align-items: center; gap: 4px; color: #{health_color(health_status)}; font-size: 0.85em;"}>
                <span style={"width: 8px; height: 8px; border-radius: 50%; background: #{health_color(health_status)}; display: inline-block;"}></span>
                <%= health_label(health_status) %>
              </span>
            </td>
            <td>
              <span :if={config_summary(channel) != ""} style="font-size: 0.8em; color: #666;" title={config_detail(channel)}>
                <%= config_summary(channel) %>
              </span>
              <span :if={config_summary(channel) == ""} style="color: #aaa;">-</span>
            </td>
            <td>
              <% {:ok, token, _} = Token.generate_channel_token(channel) %>
              <div style="display: flex; align-items: center; gap: 4px;">
                <code style="font-size: 0.75em; max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title={token}><%= token %></code>
                <button onclick={"navigator.clipboard.writeText('#{token}')"} class="badge" style="cursor: pointer; font-size: 0.7em;">Copy</button>
              </div>
            </td>
            <td style="white-space: nowrap;">
              <button phx-click="toggle_status" phx-value-id={channel.id} class="badge">
                <%= if channel.status == "active", do: "Disable", else: "Enable" %>
              </button>
              <button phx-click="delete" phx-value-id={channel.id} phx-confirm="Are you sure?" class="badge badge-inactive" style="margin-left: 4px;">
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
