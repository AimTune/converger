defmodule ConvergerWeb.ChannelComponents do
  @moduledoc """
  Pieces shared by the admin (`/admin/channels`) and portal
  (`/portal/channels`) channel lists: the filter form, the health history
  sparkline, the revealed-secret alert and the "Send test message" panel.
  See `ConvergerWeb.Live.ChannelList` for the state behind them.
  """
  use Phoenix.Component

  import ConvergerWeb.CoreComponents,
    only: [badge: 1, button: 1, icon: 1, input: 1, panel: 1]

  alias Converger.Channels.TestMessage

  attr :filters, :map, required: true
  attr :tenants, :list, default: nil, doc: "tenants offered in the filter (admin), or nil"
  attr :reset_path, :string, required: true

  def channel_filters(assigns) do
    ~H"""
    <form id="channel-filter" phx-change="filter" phx-submit="filter">
      <div class="grid items-end gap-x-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
        <.input
          type="search"
          id="channel-filter-q"
          name="filters[q]"
          value={@filters["q"]}
          label="Search"
          placeholder="Name or type"
          phx-debounce="300"
        />
        <.input
          :if={@tenants}
          type="select"
          id="channel-filter-tenant"
          name="filters[tenant_id]"
          value={@filters["tenant_id"]}
          label="Tenant"
          prompt="All tenants"
          options={Enum.map(@tenants, &{&1.name, &1.id})}
        />
        <.input
          type="select"
          id="channel-filter-mode"
          name="filters[mode]"
          value={@filters["mode"]}
          label="Mode"
          prompt="All modes"
          options={[{"← Inbound", "inbound"}, {"→ Outbound", "outbound"}, {"↔ Duplex", "duplex"}]}
        />
        <.input
          type="select"
          id="channel-filter-status"
          name="filters[status]"
          value={@filters["status"]}
          label="Status"
          prompt="All statuses"
          options={[{"Active", "active"}, {"Inactive", "inactive"}]}
        />
        <.input
          type="select"
          id="channel-filter-sort"
          name="filters[sort]"
          value={@filters["sort"]}
          label="Sort"
          options={[{"Newest first", "desc"}, {"Oldest first", "asc"}]}
        />
        <div class="mb-2">
          <.button href={@reset_path} variant="ghost">
            <.icon name="hero-x-mark" /> Reset
          </.button>
        </div>
      </div>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :history, :list, required: true, doc: "health checks, newest first"

  @doc """
  An inline SVG sparkline of the failure rate of the last health checks
  (oldest left), colored by the latest status, with a text alternative.
  """
  def health_sparkline(%{history: []} = assigns) do
    ~H"""
    <span id={@id} class="text-xs text-base-content/40">
      -<span class="sr-only">No health history</span>
    </span>
    """
  end

  def health_sparkline(assigns) do
    rates = assigns.history |> Enum.reverse() |> Enum.map(&rate/1)
    latest = List.last(rates)

    assigns =
      assign(assigns,
        points: points(rates),
        single: length(rates) == 1,
        color: sparkline_color(hd(assigns.history).status),
        summary:
          "Failure rate over the last #{length(rates)} health check(s): " <>
            "latest #{percent(latest)}, peak #{percent(Enum.max(rates))}"
      )

    ~H"""
    <svg
      id={@id}
      viewBox="0 0 100 24"
      preserveAspectRatio="none"
      class={["h-6 w-24", @color]}
      role="img"
      aria-label={@summary}
    >
      <title>{@summary}</title>
      <line x1="0" y1="23" x2="100" y2="23" stroke="currentColor" stroke-opacity="0.2" />
      <circle :if={@single} cx="50" cy={y(hd(@points))} r="2" fill="currentColor" />
      <polyline
        :if={!@single}
        points={Enum.map_join(@points, " ", fn {x, y} -> "#{x},#{y}" end)}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp rate(%{failure_rate: rate}) when is_number(rate), do: rate * 1.0
  defp rate(_), do: 0.0

  # Failure rate 0 at the bottom (y = 22), 100% at the top (y = 2).
  defp points([_] = rates), do: [{50.0, y_for(hd(rates))}]

  defp points(rates) do
    step = 100 / (length(rates) - 1)

    rates
    |> Enum.with_index()
    |> Enum.map(fn {rate, i} -> {Float.round(i * step, 2), y_for(rate)} end)
  end

  defp y_for(rate), do: Float.round(22 - min(max(rate, 0.0), 1.0) * 20, 2)
  defp y({_x, y}), do: y

  defp percent(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp sparkline_color("healthy"), do: "text-success"
  defp sparkline_color("degraded"), do: "text-warning"
  defp sparkline_color("unhealthy"), do: "text-error"
  defp sparkline_color(_), do: "text-base-content/50"

  attr :secret, :map, required: true, doc: "%{channel_name: _, secret: _}"

  def revealed_secret(assigns) do
    ~H"""
    <div id="revealed-channel-secret" role="alert" class="alert alert-warning items-start">
      <.icon name="hero-key" class="size-6 shrink-0" />
      <div class="min-w-0 flex-1 space-y-2">
        <h3 class="font-semibold">Secret for {@secret.channel_name}</h3>
        <p class="text-sm">
          Copy this channel secret now. It is stored encrypted and will not be shown again.
        </p>
        <code class="block rounded bg-base-100 p-2 font-mono text-sm break-all text-base-content">{@secret.secret}</code>
        <.button phx-click="dismiss_secret" size="sm" variant="neutral">
          I have saved the secret
        </.button>
      </div>
    </div>
    """
  end

  attr :channel, :map, required: true
  attr :text, :string, required: true
  attr :result, :map, default: nil
  attr :error, :string, default: nil

  def test_message_panel(assigns) do
    assigns = assign(assigns, :max, TestMessage.max_text_length())

    ~H"""
    <.panel id="test-message-panel" title={"Send test message to #{@channel.name}"}>
      <:actions>
        <.button
          type="button"
          phx-click="close_test"
          size="xs"
          variant="ghost"
          aria-label="Close test message panel"
        >
          <.icon name="hero-x-mark" />
        </.button>
      </:actions>
      <p class="text-sm text-base-content/70">
        The message is posted by "{TestMessage.sender()}" into a dedicated test conversation of
        this channel and delivered through the normal pipeline (routing rules of the channel
        apply). Providers that need a recipient (WhatsApp, Telegram, SMS) record a failed delivery.
      </p>
      <form id="test-message-form" phx-submit="send_test_message">
        <input type="hidden" name="test[channel_id]" value={@channel.id} />
        <.input
          type="textarea"
          id="test-message-text"
          name="test[text]"
          value={@text}
          label="Message"
          maxlength={@max}
          required
        />
        <.button type="submit" variant="primary" size="sm" phx-disable-with="Sending...">
          <.icon name="hero-paper-airplane" /> Send
        </.button>
      </form>
      <p :if={@error} id="test-message-error" role="alert" class="text-sm text-error">{@error}</p>
      <div
        :if={@result}
        id="test-message-result"
        role="status"
        aria-live="polite"
        class="flex flex-wrap items-center gap-2 rounded-box border border-base-300 bg-base-200 p-3 text-sm"
      >
        <span>Delivery to this channel:</span>
        <.badge id="test-delivery-status" value={@result.status} />
        <span :if={@result.attempts > 0} class="text-base-content/60">
          {@result.attempts} attempt(s)
        </span>
        <span :if={@result.last_error} class="break-all text-error">{@result.last_error}</span>
        <span class="font-mono text-xs text-base-content/60">
          conversation {@result.conversation_id}
        </span>
      </div>
    </.panel>
    """
  end
end
