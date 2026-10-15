defmodule ConvergerWeb.Admin.ChannelLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.Channels.Channel
  alias Converger.Channels.Adapter
  alias Converger.Channels.TestMessage
  alias Converger.Tenants
  alias Converger.Auth.Token
  alias ConvergerWeb.Live.ChannelList

  import ConvergerWeb.ChannelComponents

  @default_type "webhook"

  # Admin `viewer`s browse only (docs/security/overview.md); every other event
  # mutates a channel or reveals a secret.
  @read_only_events ~w(filter load_more)
  @manager_roles ~w(super_admin admin)

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

    supported = Adapter.supported_modes(@default_type)

    {:ok,
     socket
     |> ChannelList.init(base_path: "/admin/channels")
     |> assign(
       tenants: Tenants.list_tenants(),
       form: to_form(Channels.change_channel(%Channel{})),
       selected_type: @default_type,
       supported_modes: supported,
       selected_mode: default_mode(supported),
       transformations: [],
       page_title: "Channels",
       can_manage: socket.assigns[:admin_role] in @manager_roles,
       actor: build_actor(socket)
     )}
  end

  def handle_params(params, _url, socket) do
    {:noreply, ChannelList.apply_params(socket, params)}
  end

  def handle_info(%{event: "health_changed", payload: payload}, socket) do
    {:noreply, ChannelList.health_changed(socket, payload)}
  end

  def handle_info(%{event: "circuit_changed", payload: payload}, socket) do
    {:noreply, ChannelList.refresh_row(socket, payload.channel_id)}
  end

  def handle_info(
        %{topic: "conversation:" <> _, event: "delivery_status", payload: payload},
        socket
      ) do
    {:noreply, ChannelList.delivery_status(socket, payload)}
  end

  def handle_info({:poll_test_delivery, activity_id, n}, socket) do
    {:noreply, ChannelList.poll_test(socket, activity_id, n)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{can_manage: false}} = socket)
      when event not in @read_only_events do
    {:noreply, put_flash(socket, :error, "Viewers have read-only access to channels.")}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ChannelList.filter_path(socket, filters))}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, ChannelList.load(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("pause_deliveries", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)
    {:ok, _} = Channels.pause_deliveries(channel, socket.assigns.actor)

    {:noreply,
     socket
     |> ChannelList.refresh_row(channel.id)
     |> put_flash(:info, "Deliveries paused")}
  end

  def handle_event("resume_deliveries", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)
    {:ok, _} = Channels.resume_deliveries(channel, socket.assigns.actor)

    {:noreply,
     socket
     |> ChannelList.refresh_row(channel.id)
     |> put_flash(:info, "Deliveries resumed")}
  end

  def handle_event("rotate_secret", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)

    case Channels.rotate_secret(channel, socket.assigns.actor) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(revealed_secret: %{channel_name: updated.name, secret: updated.secret})
         |> ChannelList.refresh_row(updated.id)
         |> put_flash(:info, "Secret rotated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to rotate the secret")}
    end
  end

  def handle_event("open_test", %{"id" => id}, socket) do
    {:noreply, ChannelList.open_test(socket, Channels.get_channel!(id))}
  end

  def handle_event("close_test", _params, socket) do
    {:noreply, ChannelList.close_test(socket)}
  end

  def handle_event("send_test_message", %{"test" => %{"channel_id" => id} = test}, socket) do
    case Channels.get_channel(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Channel not found")}

      channel ->
        {:noreply, ChannelList.send_test(socket, channel, test["text"], socket.assigns.actor)}
    end
  end

  def handle_event("save", %{"channel" => params}, socket) do
    transformations = build_transformations(socket.assigns.transformations)
    params = Map.put(params, "transformations", transformations)

    case Channels.create_channel(params, socket.assigns.actor) do
      {:ok, channel} ->
        supported = Adapter.supported_modes(@default_type)

        {:noreply,
         socket
         |> put_flash(:info, "Channel created")
         |> assign(
           form: to_form(Channels.change_channel(%Channel{})),
           selected_type: @default_type,
           supported_modes: supported,
           selected_mode: default_mode(supported),
           transformations: [],
           revealed_secret: %{channel_name: channel.name, secret: channel.secret}
         )
         |> ChannelList.load(reset: true)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, revealed_secret: nil)}
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

  def handle_event(
        "change_transformation",
        %{"index" => index, "field" => field, "value" => value},
        socket
      ) do
    idx = String.to_integer(index)
    entry = Enum.at(socket.assigns.transformations, idx)
    updated_entry = Map.put(entry, field, value)
    updated = List.replace_at(socket.assigns.transformations, idx, updated_entry)
    {:noreply, assign(socket, transformations: updated)}
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)
    new_status = if channel.status == "active", do: "inactive", else: "active"

    case Channels.update_channel(channel, %{status: new_status}, socket.assigns.actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> ChannelList.refresh_row(channel.id)
         |> put_flash(:info, "Status updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  def handle_event("toggle_require_signature", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)

    case Channels.update_channel(
           channel,
           %{require_signature: !channel.require_signature},
           socket.assigns.actor
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> ChannelList.refresh_row(channel.id)
         |> put_flash(:info, "Signature requirement updated")}

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          case Keyword.get_values(changeset.errors, :config) do
            [{msg, _} | _] -> msg
            _ -> "Failed to update signature requirement"
          end

        {:noreply, put_flash(socket, :error, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update signature requirement")}
    end
  end

  def handle_event("register_webhook", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)
    inbound_url = url(~p"/api/v1/channels/#{channel.id}/inbound")

    case Channels.register_webhook(channel, inbound_url, socket.assigns.actor) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Webhook registered: #{inbound_url}")}

      {:error, reason} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        {:noreply, put_flash(socket, :error, "Webhook registration failed: #{message}")}

      :unsupported ->
        {:noreply, put_flash(socket, :error, "This channel type has no webhook registration")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    channel = Channels.get_channel!(id)

    case Channels.delete_channel(channel, socket.assigns.actor) do
      {:ok, _} ->
        socket =
          case socket.assigns.test_channel do
            %{id: ^id} -> ChannelList.close_test(socket)
            _ -> socket
          end

        {:noreply,
         socket
         |> ChannelList.drop_row(channel.id)
         |> put_flash(:info, "Channel deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete channel")}
    end
  end

  defp handle_channel_type_change(%{"channel" => %{"type" => type}}, socket) do
    supported = Adapter.supported_modes(type)

    mode =
      if socket.assigns.selected_mode in supported,
        do: socket.assigns.selected_mode,
        else: default_mode(supported)

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
          updated =
            List.replace_at(acc.assigns.transformations, idx, default_transformation(type))

          assign(acc, transformations: updated)
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  # Status dot + text colour classes (literal so Tailwind picks them up).
  defp health_class("healthy"), do: {"status-success", "text-success"}
  defp health_class("degraded"), do: {"status-warning", "text-warning"}
  defp health_class("unhealthy"), do: {"status-error", "text-error"}
  defp health_class(_), do: {"status-neutral", "text-base-content/50"}

  defp health_label("healthy"), do: "Healthy"
  defp health_label("degraded"), do: "Degraded"
  defp health_label("unhealthy"), do: "Unhealthy"
  defp health_label(_), do: "—"

  defp circuit_class("closed"), do: {"status-success", "text-success"}
  defp circuit_class("half_open"), do: {"status-warning", "text-warning"}
  defp circuit_class("open"), do: {"status-error", "text-error"}
  defp circuit_class("paused"), do: {"status-info", "text-info"}
  defp circuit_class(_), do: {"status-neutral", "text-base-content/50"}

  defp circuit_label("closed"), do: "Flowing"
  defp circuit_label("half_open"), do: "Probing"
  defp circuit_label("open"), do: "Breaker open"
  defp circuit_label("paused"), do: "Paused"
  defp circuit_label(state), do: state

  defp channel_health_status(health_map, channel_id) do
    case Map.get(health_map, channel_id) do
      %{status: status} -> status
      _ -> "unknown"
    end
  end

  defp build_actor(socket) do
    case socket.assigns[:current_admin_user] do
      %{email: email} -> %{type: "admin", id: email}
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

  defp default_transformation("text_replace"),
    do: %{"type" => "text_replace", "pattern" => "", "replacement" => ""}

  defp default_transformation("truncate_text"),
    do: %{"type" => "truncate_text", "max_length" => 160, "ellipsis" => "..."}

  defp default_transformation("set_metadata"),
    do: %{"type" => "set_metadata", "values_text" => ""}

  defp default_transformation("content_filter"),
    do: %{"type" => "content_filter", "patterns_text" => ""}

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

  # The schema fields marked `summary: true` with a value, e.g. the webhook
  # URL or the WhatsApp phone number id.
  defp config_summary(%{type: type, config: config}) when is_map(config) do
    for %{summary: true} = field <- Adapter.config_schema(type),
        value = config[field.name],
        is_binary(value) and value != "" do
      if field.type == :url, do: value, else: "#{field_label(field)}: #{value}"
    end
    |> Enum.join(", ")
  end

  defp config_summary(_), do: ""

  defp config_detail(%{config: config}) when config == %{}, do: ""

  defp config_detail(%{type: type, config: config}) do
    secret_fields = for %{secret: true, name: name} <- Adapter.config_schema(type), do: name

    config
    |> Converger.Secrets.redact()
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.map_join("\n", fn {k, v} ->
      if k in secret_fields or Converger.Secrets.sensitive_key?(k),
        do: "#{k}: #{Converger.Secrets.mask(config[k])}",
        else: "#{k}: #{format_config_value(v)}"
    end)
  end

  defp format_config_value(v) when is_binary(v), do: v
  defp format_config_value(v), do: inspect(v)

  # The admin form renders the adapter's config schema. Map fields (such as
  # the webhook's headers) and fields with `form: false` are API only.
  defp config_fields(type) do
    for field <- Adapter.config_schema(type),
        field.type != :map and Map.get(field, :form, true),
        do: field
  end

  defp field_label(field), do: Map.get(field, :label, field.name)

  defp field_placeholder(%{placeholder: placeholder}), do: placeholder
  defp field_placeholder(%{help: help}), do: help
  defp field_placeholder(_field), do: ""

  defp field_input_type(%{secret: true}), do: "password"
  defp field_input_type(%{type: :integer}), do: "number"
  defp field_input_type(%{type: :url}), do: "url"
  defp field_input_type(_field), do: "text"

  defp mode_label("inbound"), do: "← Inbound (receive only)"
  defp mode_label("outbound"), do: "→ Outbound (send only)"
  defp mode_label("duplex"), do: "↔ Duplex (send & receive)"

  defp mode_indicator("inbound"), do: "← Inbound"
  defp mode_indicator("outbound"), do: "→ Outbound"
  defp mode_indicator("duplex"), do: "↔ Duplex"

  defp config_field_label(field) do
    if Map.get(field, :required) == true,
      do: "#{field_label(field)} *",
      else: field_label(field)
  end

  attr :class, :any, required: true
  slot :inner_block, required: true

  defp status_dot(assigns) do
    {dot, text} = assigns.class
    assigns = assign(assigns, dot: dot, text: text)

    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-xs whitespace-nowrap", @text]}>
      <span class={["status", @dot]}></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :channel, :map, required: true

  # The token is generated once per render so the shown value, its tooltip
  # and the copy button agree.
  defp channel_token(assigns) do
    {:ok, token, _} = Token.generate_channel_token(assigns.channel)
    assigns = assign(assigns, token: token)

    ~H"""
    <div class="flex items-center gap-1">
      <code class="block max-w-32 truncate font-mono text-xs" title={@token}>{@token}</code>
      <button
        type="button"
        onclick={"navigator.clipboard.writeText('#{@token}')"}
        class="btn btn-ghost btn-xs"
        title="Copy token"
      >
        Copy
      </button>
    </div>
    """
  end

  attr :idx, :integer, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :type, :string, default: "text"
  attr :min, :string, default: nil
  attr :class, :any, default: "w-48"

  # Middleware step fields are saved on blur (`change_transformation`), not
  # through the form's params, so they carry no `name`.
  defp mw_text(assigns) do
    ~H"""
    <div class={@class}>
      <label class="fieldset" for={"mw-#{@idx}-#{@field}"}>
        <span class="label mb-1">{@label}</span>
        <input
          id={"mw-#{@idx}-#{@field}"}
          type={@type}
          value={@value}
          placeholder={@placeholder}
          min={@min}
          phx-blur="change_transformation"
          phx-value-index={@idx}
          phx-value-field={@field}
          class="input input-sm w-full"
        />
      </label>
    </div>
    """
  end

  # Why the "Send test" button is disabled for a channel, or nil.
  defp test_blocked_reason(channel) do
    case TestMessage.check_sendable(channel) do
      :ok -> nil
      {:error, reason} -> TestMessage.error_message(reason)
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Channels
        <:subtitle>
          Connections to messaging providers, with health, delivery state and tokens.
        </:subtitle>
      </.header>

      <.revealed_secret :if={@revealed_secret} secret={@revealed_secret} />

      <.panel :if={@can_manage} title="Create Channel">
        <.form for={@form} id="channel-form" phx-submit="save" phx-change="form_changed">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-3">
            <.input
              type="select"
              id="channel-tenant"
              name="channel[tenant_id]"
              label="Tenant"
              value={nil}
              prompt="Select Tenant"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
              required
            />
            <.input
              type="select"
              id="channel-type"
              name="channel[type]"
              label="Type"
              value={@selected_type}
              options={Channel.channel_types()}
              required
            />
            <.input
              type="select"
              id="channel-mode"
              name="channel[mode]"
              label="Mode"
              value={@selected_mode}
              options={Enum.map(@supported_modes, &{mode_label(&1), &1})}
              required
            />
            <.input field={@form[:name]} label="Name" placeholder="Channel Name" />
            <.input field={@form[:rate_limit]} label="Rate limit" placeholder="e.g. 80/s (optional)" />
            <div class="flex items-end">
              <.input
                type="checkbox"
                field={@form[:require_signature]}
                label="Require signed inbound webhooks"
              />
            </div>
          </div>
          <.error :for={{msg, _} <- Keyword.get_values(@form.errors, :config)}>{msg}</.error>

          <div
            :if={config_fields(@selected_type) != []}
            class="mt-3 rounded-box border border-base-300 bg-base-200 p-4"
          >
            <h3 class="mb-2 text-sm font-semibold text-base-content/70">Configuration</h3>
            <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-3">
              <div :for={field <- config_fields(@selected_type)} title={Map.get(field, :help)}>
                <.input
                  :if={field.type == :boolean}
                  type="select"
                  id={"channel-config-#{field.name}"}
                  name={"channel[config][#{field.name}]"}
                  label={config_field_label(field)}
                  value={nil}
                  options={[{"default", ""}, "true", "false"]}
                />
                <.input
                  :if={field.type != :boolean}
                  type={field_input_type(field)}
                  id={"channel-config-#{field.name}"}
                  name={"channel[config][#{field.name}]"}
                  label={config_field_label(field)}
                  value={nil}
                  placeholder={field_placeholder(field)}
                />
              </div>
            </div>
          </div>

          <div class="mt-3 rounded-box border border-base-300 bg-base-200 p-4">
            <div class="mb-2 flex items-center justify-between gap-2">
              <h3 class="text-sm font-semibold text-base-content/70">Middleware Pipeline</h3>
              <.button type="button" phx-click="add_transformation" size="xs" variant="neutral">
                + Add Step
              </.button>
            </div>
            <p :if={@transformations == []} class="py-1 text-sm text-base-content/60">
              No middleware configured. Messages will be delivered as-is.
            </p>
            <div
              :for={{t, idx} <- Enum.with_index(@transformations)}
              class="mb-2 flex flex-wrap items-start gap-3 rounded-box border border-base-300 bg-base-100 p-3"
            >
              <span class="pt-7 text-xs font-semibold text-base-content/50">#{idx + 1}</span>
              <div class="w-44">
                <.input
                  type="select"
                  id={"mw-type-#{idx}"}
                  name={"mw_type_#{idx}"}
                  label="Type"
                  value={t["type"]}
                  options={Enum.map(middleware_types(), fn {val, label} -> {label, val} end)}
                  class="w-full select select-sm"
                />
              </div>
              <%= case t["type"] do %>
                <% "add_prefix" -> %>
                  <.mw_text
                    idx={idx}
                    field="prefix"
                    label="Prefix"
                    value={t["prefix"]}
                    placeholder="[Alert] "
                  />
                <% "add_suffix" -> %>
                  <.mw_text
                    idx={idx}
                    field="suffix"
                    label="Suffix"
                    value={t["suffix"]}
                    placeholder=" [end]"
                  />
                <% "text_replace" -> %>
                  <.mw_text
                    idx={idx}
                    field="pattern"
                    label="Pattern"
                    value={t["pattern"]}
                    placeholder="find this"
                  />
                  <.mw_text
                    idx={idx}
                    field="replacement"
                    label="Replacement"
                    value={t["replacement"]}
                    placeholder="replace with"
                  />
                <% "truncate_text" -> %>
                  <.mw_text
                    idx={idx}
                    field="max_length"
                    label="Max Length"
                    value={t["max_length"]}
                    placeholder="160"
                    type="number"
                    min="1"
                    class="w-28"
                  />
                  <.mw_text
                    idx={idx}
                    field="ellipsis"
                    label="Ellipsis"
                    value={t["ellipsis"]}
                    placeholder="..."
                    class="w-24"
                  />
                <% "set_metadata" -> %>
                  <div class="w-64">
                    <label class="fieldset" for={"mw-#{idx}-values_text"}>
                      <span class="label mb-1">Values (key=value, one per line)</span>
                      <textarea
                        id={"mw-#{idx}-values_text"}
                        rows="2"
                        placeholder={"source=converger\nenv=prod"}
                        phx-blur="change_transformation"
                        phx-value-index={idx}
                        phx-value-field="values_text"
                        class="textarea textarea-sm w-full"
                      >{t["values_text"]}</textarea>
                    </label>
                  </div>
                <% "content_filter" -> %>
                  <.mw_text
                    idx={idx}
                    field="patterns_text"
                    label="Block Patterns (comma-separated)"
                    value={t["patterns_text"]}
                    placeholder="spam, blocked, unwanted"
                    class="w-72"
                  />
                <% _ -> %>
              <% end %>
              <div class="ml-auto pt-7">
                <.button
                  type="button"
                  phx-click="remove_transformation"
                  phx-value-index={idx}
                  size="xs"
                  variant="error"
                >
                  Remove
                </.button>
              </div>
            </div>
          </div>

          <div class="mt-3">
            <.button type="submit" variant="primary">Create</.button>
          </div>
        </.form>
      </.panel>


      <.test_message_panel
        :if={@test_channel}
        channel={@test_channel}
        text={@test_text}
        result={@test_result}
        error={@test_error}
      />

      <.panel>
        <.channel_filters filters={@filters} tenants={@tenants} reset_path={~p"/admin/channels"} />

        <div class="overflow-x-auto">
          <.table id="channels" rows={@streams.channels} row_item={fn {_id, channel} -> channel end}>
            <:col :let={channel} label="Name">
              <span class="font-medium">{channel.name}</span>
            </:col>
            <:col :let={channel} label="Type"><.badge value={channel.type} /></:col>
            <:col :let={channel} label="Mode">
              <.badge value={channel.mode}>{mode_indicator(channel.mode)}</.badge>
            </:col>
            <:col :let={channel} label="Tenant">
              {if channel.tenant, do: channel.tenant.name, else: "-"}
            </:col>
            <:col :let={channel} label="Status"><.badge value={channel.status} /></:col>
            <:col :let={channel} label="Health">
              <div class="flex flex-col gap-1">
                <.status_dot class={health_class(channel_health_status(@health_map, channel.id))}>
                  {health_label(channel_health_status(@health_map, channel.id))}
                </.status_dot>
                <.health_sparkline
                  id={"health-sparkline-#{channel.id}"}
                  history={Map.get(@history_map, channel.id, [])}
                />
              </div>
            </:col>
            <:col :let={channel} label="Delivery">
              <span
                id={"circuit-#{channel.id}"}
                title={"#{channel.consecutive_failures} consecutive failure(s); rate limit: #{channel.rate_limit || "adapter default"}"}
              >
                <.status_dot class={circuit_class(channel.circuit_state)}>
                  {circuit_label(channel.circuit_state)}
                </.status_dot>
              </span>
            </:col>
            <:col :let={channel} label="Config">
              <span
                :if={config_summary(channel) != ""}
                class="block max-w-60 truncate text-xs text-base-content/70"
                title={config_detail(channel)}
              >
                {config_summary(channel)}
              </span>
              <span :if={config_summary(channel) == ""} class="text-base-content/40">-</span>
            </:col>
            <:col :let={channel} label="Middleware">
              <.badge
                :if={length(channel.transformations || []) > 0}
                value="steps"
                title={Enum.map_join(channel.transformations, ", ", & &1["type"])}
              >
                {length(channel.transformations)} step(s)
              </.badge>
              <span :if={length(channel.transformations || []) == 0} class="text-base-content/40">
                -
              </span>
            </:col>
            <:col :let={channel} label="Token"><.channel_token channel={channel} /></:col>
            <:action :let={channel} :if={@can_manage}>
              <div class="flex flex-wrap gap-1">
                <.button
                  phx-click="toggle_status"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                >
                  {if channel.status == "active", do: "Disable", else: "Enable"}
                </.button>
                <.button
                  :if={channel.circuit_state == "closed"}
                  phx-click="pause_deliveries"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Park outbound deliveries until resumed"
                >
                  Pause deliveries
                </.button>
                <.button
                  :if={channel.circuit_state != "closed"}
                  phx-click="resume_deliveries"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Close the breaker and release parked deliveries"
                >
                  Resume deliveries
                </.button>
                <.button
                  id={"send-test-#{channel.id}"}
                  phx-click="open_test"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  disabled={test_blocked_reason(channel) != nil}
                  title={test_blocked_reason(channel) || "Send a test message through the pipeline"}
                >
                  Send test
                </.button>
                <.button
                  phx-click="toggle_require_signature"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Whether unsigned inbound webhooks are rejected"
                >
                  {if channel.require_signature,
                    do: "Signature: required",
                    else: "Signature: optional"}
                </.button>
                <.button
                  :if={Adapter.supports?(channel.type, :register_webhook, 2)}
                  id={"register-webhook-#{channel.id}"}
                  phx-click="register_webhook"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Point the provider's webhook at this channel's inbound URL"
                >
                  Register webhook
                </.button>
                <.button
                  id={"rotate-secret-#{channel.id}"}
                  phx-click="rotate_secret"
                  phx-value-id={channel.id}
                  data-confirm="Rotate this channel's secret? The current secret stops working immediately."
                  size="xs"
                  variant="neutral"
                  title="Generate a new channel secret (shown once)"
                >
                  Rotate secret
                </.button>
                <.button
                  phx-click="delete"
                  phx-value-id={channel.id}
                  data-confirm="Are you sure?"
                  size="xs"
                  variant="error"
                >
                  Delete
                </.button>
              </div>
            </:action>
          </.table>
        </div>
        <.empty_state :if={@loaded_count == 0}>No channels found.</.empty_state>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="text-sm text-base-content/60">Showing {@loaded_count} channels</span>
          <.button
            :if={@has_more}
            id="load-more-channels"
            phx-click="load_more"
            size="sm"
            variant="neutral"
          >
            Load more
          </.button>
        </div>
      </.panel>
    </Layouts.app>
    """
  end
end
