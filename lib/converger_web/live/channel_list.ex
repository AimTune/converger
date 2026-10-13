defmodule ConvergerWeb.Live.ChannelList do
  @moduledoc """
  State shared by the admin (`/admin/channels`) and portal
  (`/portal/channels`) channel lists: URL-driven filters (`q`, `tenant_id`
  (admin), `mode`, `status`, `sort`), the keyset-paginated row stream with
  "Load more", the health status and history (sparkline) of the loaded
  channels, and the "Send test message" panel with its live delivery
  result.

  The LiveViews keep their own events and permission checks and call these
  functions on their socket. Options of `init/2`:

    * `:base_path` - `"/admin/channels"` or `"/portal/channels"`
    * `:tenant_id` - forced tenant scope (portal), or `nil` (admin)
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Converger.Channels
  alias Converger.Channels.{Health, TestMessage}
  alias Converger.Deliveries

  @filter_keys ~w(q tenant_id mode status sort)
  @history_points 20
  # Poll the test delivery every 2s for up to 30s, in case no
  # `delivery_status` broadcast arrives (e.g. a retry scheduled by Oban).
  @poll_ms 2_000
  @poll_max 15
  @final_statuses ~w(sent delivered read failed)

  def filter_keys, do: @filter_keys
  def history_points, do: @history_points

  def init(socket, opts) do
    socket
    |> stream_configure(:channels, dom_id: &"channel-#{&1.id}")
    |> assign(
      base_path: Keyword.fetch!(opts, :base_path),
      scope_tenant_id: Keyword.get(opts, :tenant_id),
      filters: default_filters(),
      next_cursor: nil,
      has_more: false,
      loaded_count: 0,
      loaded_ids: MapSet.new(),
      health_map: %{},
      history_map: %{},
      revealed_secret: nil,
      test_channel: nil,
      test_text: "Test message from Converger",
      test_result: nil,
      test_error: nil
    )
  end

  def default_filters do
    %{"q" => "", "tenant_id" => "", "mode" => "", "status" => "", "sort" => "desc"}
  end

  @doc "Apply the URL params (filters) and load the first page."
  def apply_params(socket, params) do
    filters = Map.merge(default_filters(), Map.take(params, @filter_keys))

    socket
    |> assign(filters: filters)
    |> load(reset: true)
  end

  @doc "The patch path for new filter values (blank ones left out)."
  def filter_path(socket, filters) do
    params =
      filters
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    query = if params == %{}, do: "", else: "?" <> URI.encode_query(params)
    socket.assigns.base_path <> query
  end

  @doc "Load the first page (`reset: true`) or the next one."
  def load(socket, opts) do
    reset = Keyword.get(opts, :reset, false)
    filters = socket.assigns.filters
    cursor = if reset, do: nil, else: socket.assigns.next_cursor

    query_filters =
      filters
      |> Map.take(~w(q tenant_id mode status))
      |> scope(socket.assigns.scope_tenant_id)

    page =
      case Channels.paginate_channels(query_filters,
             cursor: cursor,
             direction: if(filters["sort"] == "asc", do: :asc, else: :desc),
             preload: [:tenant]
           ) do
        {:ok, page} -> page
        {:error, :invalid_cursor} -> %Converger.Pagination.Page{}
      end

    ids = Enum.map(page.entries, & &1.id)
    {health, history} = health_maps(ids)

    {loaded_ids, health_map, history_map, count} =
      if reset do
        {MapSet.new(ids), health, history, 0}
      else
        {MapSet.union(socket.assigns.loaded_ids, MapSet.new(ids)),
         Map.merge(socket.assigns.health_map, health),
         Map.merge(socket.assigns.history_map, history), socket.assigns.loaded_count}
      end

    socket
    |> assign(
      next_cursor: page.next_cursor,
      has_more: page.has_more,
      loaded_count: count + length(page.entries),
      loaded_ids: loaded_ids,
      health_map: health_map,
      history_map: history_map
    )
    |> stream(:channels, page.entries, reset: reset)
  end

  defp scope(filters, nil), do: filters
  defp scope(filters, tenant_id), do: Map.put(filters, "tenant_id", tenant_id)

  defp health_maps([]), do: {%{}, %{}}

  defp health_maps(ids) do
    {Health.get_latest_health_map(ids), Health.list_health_history_map(ids, @history_points)}
  end

  @doc "Re-render the row of `channel_id` when it is loaded (after a change)."
  def refresh_row(socket, channel_id) do
    if MapSet.member?(socket.assigns.loaded_ids, channel_id) do
      case Channels.get_channel(channel_id) do
        nil -> drop_row(socket, channel_id)
        channel -> stream_insert(socket, :channels, Converger.Repo.preload(channel, :tenant))
      end
    else
      socket
    end
  end

  @doc "Remove a deleted channel's row."
  def drop_row(socket, channel_id) do
    if MapSet.member?(socket.assigns.loaded_ids, channel_id) do
      socket
      |> stream_delete_by_dom_id(:channels, "channel-#{channel_id}")
      |> assign(
        loaded_ids: MapSet.delete(socket.assigns.loaded_ids, channel_id),
        loaded_count: max(socket.assigns.loaded_count - 1, 0)
      )
    else
      socket
    end
  end

  @doc "A `health_changed` broadcast: update the status and history of a loaded channel."
  def health_changed(socket, payload) do
    id = payload.channel_id

    if MapSet.member?(socket.assigns.loaded_ids, id) do
      check = %Converger.Channels.HealthCheck{
        channel_id: id,
        status: payload.status,
        failure_rate: payload.failure_rate,
        total_deliveries: payload.total_deliveries,
        failed_deliveries: payload.failed_deliveries,
        checked_at: Map.get(payload, :checked_at)
      }

      history =
        [check | Map.get(socket.assigns.history_map, id, [])] |> Enum.take(@history_points)

      socket
      |> assign(
        health_map: Map.put(socket.assigns.health_map, id, check),
        history_map: Map.put(socket.assigns.history_map, id, history)
      )
      |> refresh_row(id)
    else
      socket
    end
  end

  ## Test message

  def open_test(socket, channel) do
    assign(socket, test_channel: channel, test_result: nil, test_error: nil)
  end

  def close_test(socket) do
    socket |> unsubscribe_test() |> assign(test_channel: nil, test_result: nil, test_error: nil)
  end

  @doc "Send the test message and track its delivery to `channel`."
  def send_test(socket, channel, text, actor) do
    case Channels.send_test_message(channel, text, actor) do
      {:ok, %{conversation: conversation, activity: activity, delivery: delivery}} ->
        socket = unsubscribe_test(socket)
        topic = "conversation:#{conversation.id}"
        if connected?(socket), do: ConvergerWeb.Endpoint.subscribe(topic)

        result = %{
          topic: topic,
          channel_id: channel.id,
          conversation_id: conversation.id,
          activity_id: activity.id,
          status: (delivery && delivery.status) || "queued",
          attempts: (delivery && delivery.attempts) || 0,
          last_error: delivery && delivery.last_error
        }

        socket
        |> assign(test_channel: channel, test_text: text, test_result: result, test_error: nil)
        |> maybe_poll(result, 1)

      {:error, reason} ->
        assign(socket, test_text: text, test_error: TestMessage.error_message(reason))
    end
  end

  @doc "A `delivery_status` broadcast on the test conversation."
  def delivery_status(socket, payload) do
    case socket.assigns.test_result do
      %{activity_id: activity_id, channel_id: channel_id} = result
      when activity_id == payload.activity_id and channel_id == payload.channel_id ->
        assign(socket,
          test_result: %{
            result
            | status: payload.status,
              attempts: Map.get(payload, :attempts, result.attempts),
              last_error: Map.get(payload, :last_error)
          }
        )

      _ ->
        socket
    end
  end

  @doc "Re-read the test delivery (fallback when no broadcast arrives)."
  def poll_test(socket, activity_id, n) do
    case socket.assigns.test_result do
      %{activity_id: ^activity_id, channel_id: channel_id} = result ->
        result =
          case Deliveries.get_delivery_for_activity_and_channel(activity_id, channel_id) do
            nil ->
              result

            delivery ->
              %{
                result
                | status: delivery.status,
                  attempts: delivery.attempts,
                  last_error: delivery.last_error
              }
          end

        socket |> assign(test_result: result) |> maybe_poll(result, n + 1)

      _ ->
        socket
    end
  end

  defp maybe_poll(socket, %{status: status, activity_id: activity_id}, n) do
    if connected?(socket) and status not in @final_statuses and n <= @poll_max do
      Process.send_after(self(), {:poll_test_delivery, activity_id, n}, @poll_ms)
    end

    socket
  end

  defp unsubscribe_test(socket) do
    case socket.assigns.test_result do
      %{topic: topic} -> ConvergerWeb.Endpoint.unsubscribe(topic)
      _ -> :ok
    end

    socket
  end
end
