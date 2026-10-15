defmodule ConvergerWeb.Portal.ChannelLive do
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.Channels.TestMessage
  alias ConvergerWeb.Live.{ChannelAccess, ChannelList}

  import ConvergerWeb.ChannelComponents

  # Members may enable/disable channels; owners and admins also manage
  # deliveries (pause/resume), send test messages, rotate secrets and manage
  # client access (test tokens, the publishable key).
  def mount(_params, _session, socket) do
    role = socket.assigns.tenant_role
    tenant_id = socket.assigns.current_tenant.id

    if connected?(socket) do
      ConvergerWeb.Endpoint.subscribe("channel_health")
    end

    {:ok,
     socket
     |> ChannelList.init(base_path: "/portal/channels", tenant_id: tenant_id)
     |> ChannelAccess.init()
     |> assign(
       page_title: "Channels",
       can_edit: role in ~w(owner admin member),
       can_manage: role in ~w(owner admin)
     )}
  end

  def handle_params(params, url, socket) do
    {:noreply, socket |> ChannelAccess.put_base_url(url) |> ChannelList.apply_params(params)}
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

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ChannelList.filter_path(socket, filters))}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more,
      do: {:noreply, ChannelList.load(socket, reset: false)},
      else: {:noreply, socket}
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    with_channel(socket, :can_edit, id, &toggle_channel_status(&2, &1))
  end

  def handle_event("pause_deliveries", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:ok, _} = Channels.pause_deliveries(channel, build_actor(socket))

      {:noreply,
       socket |> ChannelList.refresh_row(channel.id) |> put_flash(:info, "Deliveries paused")}
    end)
  end

  def handle_event("resume_deliveries", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:ok, _} = Channels.resume_deliveries(channel, build_actor(socket))

      {:noreply,
       socket |> ChannelList.refresh_row(channel.id) |> put_flash(:info, "Deliveries resumed")}
    end)
  end

  def handle_event("rotate_secret", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      case Channels.rotate_secret(channel, build_actor(socket)) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(revealed_secret: %{channel_name: updated.name, secret: updated.secret})
           |> ChannelList.refresh_row(updated.id)
           |> put_flash(:info, "Secret rotated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to rotate the secret")}
      end
    end)
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, revealed_secret: nil)}
  end

  def handle_event("open_test", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply, ChannelList.open_test(socket, channel)}
    end)
  end

  def handle_event("close_test", _params, socket) do
    {:noreply, ChannelList.close_test(socket)}
  end

  def handle_event("send_test_message", %{"test" => %{"channel_id" => id} = test}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply, ChannelList.send_test(socket, channel, test["text"], build_actor(socket))}
    end)
  end

  def handle_event("open_access", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply, ChannelAccess.open(socket, channel)}
    end)
  end

  def handle_event("close_access", _params, socket) do
    {:noreply, ChannelAccess.close(socket)}
  end

  def handle_event("issue_test_token", %{"access" => %{"channel_id" => id} = access}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply,
       ChannelAccess.issue_test_token(socket, channel, access["user_id"], build_actor(socket))}
    end)
  end

  def handle_event("save_origins", %{"access" => %{"channel_id" => id} = access} = params, socket) do
    key = if params["key"] == "new", do: :new, else: :keep
    attrs = %{"allowed_origins" => access["allowed_origins"] || ""}

    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply, ChannelAccess.update_key(socket, channel, attrs, key, build_actor(socket))}
    end)
  end

  def handle_event("rotate_publishable_key", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply, ChannelAccess.update_key(socket, channel, %{}, :new, build_actor(socket))}
    end)
  end

  def handle_event("disable_publishable_key", %{"id" => id}, socket) do
    with_channel(socket, :can_manage, id, fn channel, socket ->
      {:noreply, ChannelAccess.update_key(socket, channel, %{}, :none, build_actor(socket))}
    end)
  end

  # Re-checks the permission and the tenant scope of every event: the
  # channel is looked up within the current tenant only.
  defp with_channel(socket, permission, id, fun) do
    cond do
      not socket.assigns[permission] ->
        {:noreply, put_flash(socket, :error, "You don't have permission to do this.")}

      channel = Channels.get_channel(id, socket.assigns.current_tenant.id) ->
        fun.(channel, socket)

      true ->
        {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp toggle_channel_status(socket, channel) do
    new_status = if channel.status == "active", do: "inactive", else: "active"

    case Channels.update_channel(channel, %{status: new_status}, build_actor(socket)) do
      {:ok, _} ->
        {:noreply,
         socket |> ChannelList.refresh_row(channel.id) |> put_flash(:info, "Status updated")}

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

  defp test_blocked_reason(channel) do
    case TestMessage.check_sendable(channel) do
      :ok -> nil
      {:error, reason} -> TestMessage.error_message(reason)
    end
  end

  defp health_status(health_map, channel_id) do
    case Map.get(health_map, channel_id) do
      %{status: status} -> status
      _ -> "unknown"
    end
  end

  defp circuit_label("closed"), do: "Flowing"
  defp circuit_label("half_open"), do: "Probing"
  defp circuit_label("open"), do: "Breaker open"
  defp circuit_label("paused"), do: "Paused"
  defp circuit_label(state), do: state

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Channels
        <:subtitle>The messaging channels connected to your organization.</:subtitle>
      </.header>

      <.revealed_secret :if={@revealed_secret} secret={@revealed_secret} />

      <.test_message_panel
        :if={@test_channel}
        channel={@test_channel}
        text={@test_text}
        result={@test_result}
        error={@test_error}
      />

      <.client_access_panel
        :if={@access_channel}
        channel={@access_channel}
        base_url={@access_base_url}
        user_id={@access_user_id}
        test_token={@test_token}
        origins_error={@origins_error}
      />

      <.panel>
        <.channel_filters filters={@filters} reset_path={~p"/portal/channels"} />

        <div class="overflow-x-auto">
          <.table id="channels" rows={@streams.channels} row_item={fn {_id, channel} -> channel end}>
            <:col :let={channel} label="Name">
              <span class="font-medium">{channel.name}</span>
            </:col>
            <:col :let={channel} label="Type"><.badge value={channel.type} /></:col>
            <:col :let={channel} label="Mode"><.badge value={channel.mode} /></:col>
            <:col :let={channel} label="Status"><.badge value={channel.status} /></:col>
            <:col :let={channel} label="Health">
              <div class="flex flex-col gap-1">
                <.badge value={health_status(@health_map, channel.id)} />
                <.health_sparkline
                  id={"health-sparkline-#{channel.id}"}
                  history={Map.get(@history_map, channel.id, [])}
                />
              </div>
            </:col>
            <:col :let={channel} label="Delivery">
              <span id={"circuit-#{channel.id}"}>
                <.badge value={channel.circuit_state}>{circuit_label(channel.circuit_state)}</.badge>
              </span>
            </:col>
            <:action :let={channel} :if={@can_edit}>
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
                  :if={@can_manage and channel.circuit_state == "closed"}
                  phx-click="pause_deliveries"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Park outbound deliveries until resumed"
                >
                  Pause deliveries
                </.button>
                <.button
                  :if={@can_manage and channel.circuit_state != "closed"}
                  phx-click="resume_deliveries"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Close the breaker and release parked deliveries"
                >
                  Resume deliveries
                </.button>
                <.button
                  :if={@can_manage}
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
                  :if={@can_manage}
                  id={"client-access-#{channel.id}"}
                  phx-click="open_access"
                  phx-value-id={channel.id}
                  size="xs"
                  variant="neutral"
                  title="Endpoints, a test token and the publishable key for chat clients"
                >
                  Client access
                </.button>
                <.button
                  :if={@can_manage}
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
