defmodule ConvergerWeb.Admin.ChannelLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.Channels.Channel
  alias Converger.Channels.Adapter
  alias Converger.Channels.Health
  alias Converger.Tenants
  alias Converger.Auth.Token

  @default_type "webhook"

  @middleware_types [
    {"add_prefix", "Add Prefix"},
    {"add_suffix", "Add Suffix"},
    {"text_replace", "Text Replace"},
    {"truncate_text", "Truncate Text"},
    {"set_metadata", "Set Metadata"},
    {"content_filter", "Content Filter"}
  ]

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
       transformations: [],
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
    transformations = build_transformations(socket.assigns.transformations)
    params = Map.put(params, "transformations", transformations)

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
           selected_mode: default_mode(supported),
           transformations: []
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("form_changed", params, socket) do
    socket = handle_channel_type_change(params, socket)
    socket = handle_mw_type_changes(params, socket)
    {:noreply, socket}
  end

  def handle_event("add_transformation", _params, socket) do
    new = %{"type" => "add_prefix", "prefix" => ""}
    {:noreply, assign(socket, transformations: socket.assigns.transformations ++ [new])}
  end

  def handle_event("remove_transformation", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    updated = List.delete_at(socket.assigns.transformations, idx)
    {:noreply, assign(socket, transformations: updated)}
  end

  def handle_event("change_transformation", %{"index" => index, "field" => field, "value" => value}, socket) do
    idx = String.to_integer(index)
    entry = Enum.at(socket.assigns.transformations, idx)
    updated_entry = Map.put(entry, field, value)
    updated = List.replace_at(socket.assigns.transformations, idx, updated_entry)
    {:noreply, assign(socket, transformations: updated)}
  end

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

  defp handle_channel_type_change(%{"channel" => %{"type" => type}}, socket) do
    supported = Adapter.supported_modes(type)
    mode = if socket.assigns.selected_mode in supported, do: socket.assigns.selected_mode, else: default_mode(supported)

    assign(socket,
      selected_type: type,
      supported_modes: supported,
      selected_mode: mode
    )
  end

  defp handle_channel_type_change(_params, socket), do: socket

  defp handle_mw_type_changes(params, socket) do
    Enum.reduce(params, socket, fn
      {"mw_type_" <> idx_str, type}, acc ->
        idx = String.to_integer(idx_str)

        if idx < length(acc.assigns.transformations) do
          updated = List.replace_at(acc.assigns.transformations, idx, default_transformation(type))
          assign(acc, transformations: updated)
        else
          acc
        end

      _, acc ->
        acc
    end)
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

  defp default_transformation("add_prefix"), do: %{"type" => "add_prefix", "prefix" => ""}
  defp default_transformation("add_suffix"), do: %{"type" => "add_suffix", "suffix" => ""}
  defp default_transformation("text_replace"), do: %{"type" => "text_replace", "pattern" => "", "replacement" => ""}
  defp default_transformation("truncate_text"), do: %{"type" => "truncate_text", "max_length" => 160, "ellipsis" => "..."}
  defp default_transformation("set_metadata"), do: %{"type" => "set_metadata", "values_text" => ""}
  defp default_transformation("content_filter"), do: %{"type" => "content_filter", "patterns_text" => ""}
  defp default_transformation(_), do: %{"type" => "add_prefix", "prefix" => ""}

  defp build_transformations(transformations) do
    Enum.map(transformations, fn
      %{"type" => "set_metadata", "values_text" => text} ->
        values =
          text
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, "=", parts: 2) do
              [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
              _ -> acc
            end
          end)

        %{"type" => "set_metadata", "values" => values}

      %{"type" => "content_filter", "patterns_text" => text} ->
        patterns = text |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        %{"type" => "content_filter", "block_patterns" => patterns}

      %{"type" => "truncate_text", "max_length" => ml} = t ->
        max_length = if is_binary(ml), do: String.to_integer(ml), else: ml
        Map.put(t, "max_length", max_length)

      t ->
        t
    end)
  end

  defp middleware_types, do: @middleware_types

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

        <div style="margin-top: 12px; padding: 12px; background: #f0f4ff; border-radius: 6px; border: 1px solid #d0d8ef;">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
            <h4 style="margin: 0; font-size: 0.9em; color: #555;">Middleware Pipeline</h4>
            <button type="button" phx-click="add_transformation" class="badge" style="cursor: pointer; font-size: 0.8em;">
              + Add Step
            </button>
          </div>
          <div :if={@transformations == []} style="color: #999; font-size: 0.85em; padding: 4px 0;">
            No middleware configured. Messages will be delivered as-is.
          </div>
          <div :for={{t, idx} <- Enum.with_index(@transformations)} style="display: flex; gap: 8px; align-items: flex-start; margin-bottom: 8px; padding: 8px; background: #fff; border-radius: 4px; border: 1px solid #e0e0e0;">
            <div style="min-width: 60px;">
              <span style="font-size: 0.75em; color: #999; font-weight: 600;">#<%= idx + 1 %></span>
            </div>
            <div>
              <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Type</label>
              <select
                name={"mw_type_#{idx}"}
                style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em;"
              >
                <%= for {val, label} <- middleware_types() do %>
                  <option value={val} selected={val == t["type"]}><%= label %></option>
                <% end %>
              </select>
            </div>
            <%= case t["type"] do %>
              <% "add_prefix" -> %>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Prefix</label>
                  <input type="text" value={t["prefix"]} placeholder="[Alert] "
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="prefix"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 180px;" />
                </div>
              <% "add_suffix" -> %>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Suffix</label>
                  <input type="text" value={t["suffix"]} placeholder=" [end]"
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="suffix"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 180px;" />
                </div>
              <% "text_replace" -> %>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Pattern</label>
                  <input type="text" value={t["pattern"]} placeholder="find this"
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="pattern"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 140px;" />
                </div>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Replacement</label>
                  <input type="text" value={t["replacement"]} placeholder="replace with"
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="replacement"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 140px;" />
                </div>
              <% "truncate_text" -> %>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Max Length</label>
                  <input type="number" value={t["max_length"]} placeholder="160" min="1"
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="max_length"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 80px;" />
                </div>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Ellipsis</label>
                  <input type="text" value={t["ellipsis"]} placeholder="..."
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="ellipsis"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 60px;" />
                </div>
              <% "set_metadata" -> %>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Values (key=value, one per line)</label>
                  <textarea rows="2" placeholder={"source=converger\nenv=prod"}
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="values_text"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 220px;"><%= t["values_text"] %></textarea>
                </div>
              <% "content_filter" -> %>
                <div>
                  <label style="display: block; font-weight: 600; margin-bottom: 4px; font-size: 0.8em; color: #555;">Block Patterns (comma-separated)</label>
                  <input type="text" value={t["patterns_text"]} placeholder="spam, blocked, unwanted"
                    phx-blur="change_transformation" phx-value-index={idx} phx-value-field="patterns_text"
                    style="padding: 6px; border: 1px solid #ddd; border-radius: 4px; font-size: 0.85em; width: 250px;" />
                </div>
              <% _ -> %>
            <% end %>
            <div style="margin-left: auto; padding-top: 18px;">
              <button type="button" phx-click="remove_transformation" phx-value-index={idx}
                class="badge badge-inactive" style="cursor: pointer; font-size: 0.75em;">
                Remove
              </button>
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
            <th>Middleware</th>
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
              <span :if={length(channel.transformations || []) > 0}
                class="badge"
                title={channel.transformations |> Enum.map_join(", ", &(&1["type"]))}>
                <%= length(channel.transformations) %> step(s)
              </span>
              <span :if={length(channel.transformations || []) == 0} style="color: #aaa;">-</span>
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
