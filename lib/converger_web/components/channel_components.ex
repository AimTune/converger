defmodule ConvergerWeb.ChannelComponents do
  @moduledoc """
  Pieces shared by the admin (`/admin/channels`) and portal
  (`/portal/channels`) channel lists: the filter form, the health history
  sparkline, the revealed-secret alert, the "Send test message" panel and
  the Client access panel. See `ConvergerWeb.Live.ChannelList` and
  `ConvergerWeb.Live.ChannelAccess` for the state behind them.
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

  attr :channel, :map, required: true
  attr :base_url, :string, default: nil
  attr :user_id, :string, required: true
  attr :test_token, :map, default: nil
  attr :origins_error, :string, default: nil

  def client_access_panel(assigns) do
    base = assigns.base_url || ""

    assigns =
      assign(assigns,
        socket_url: String.replace_prefix(base, "http", "ws") <> "/socket/converger/v1",
        origins_text: Enum.join(assigns.channel.allowed_origins || [], "\n"),
        active?: assigns.channel.status == "active"
      )

    ~H"""
    <.panel id="client-access-panel" title={"Client access: #{@channel.name}"}>
      <:actions>
        <.button
          type="button"
          phx-click="close_access"
          size="xs"
          variant="ghost"
          aria-label="Close client access panel"
        >
          <.icon name="hero-x-mark" />
        </.button>
      </:actions>

      <div :if={@base_url} class="grid gap-2 text-sm sm:grid-cols-2">
        <.copy_field id="access-base-url" label="Base URL" value={@base_url} />
        <.copy_field id="access-socket-url" label="WebSocket" value={@socket_url} />
      </div>

      <section class="space-y-2 rounded-box border border-base-300 bg-base-200 p-4">
        <h3 class="text-sm font-semibold">Test token</h3>
        <p class="text-sm text-base-content/70">
          A client token for this channel, as <code>POST /api/v1/converger/tokens/generate</code>
          would return with the channel secret. Paste it into a chat client to try the channel. It
          expires in 30 minutes; issuing it is audit-logged.
        </p>
        <form id="test-token-form" phx-submit="issue_test_token" class="flex flex-wrap items-end gap-2">
          <input type="hidden" name="access[channel_id]" value={@channel.id} />
          <div class="w-56">
            <.input
              id="test-token-user-id"
              name="access[user_id]"
              value={@user_id}
              label="End user id"
              maxlength="128"
            />
          </div>
          <div class="pb-2">
            <.button
              type="submit"
              size="sm"
              variant="primary"
              disabled={not @active?}
              title={if @active?, do: nil, else: "Enable the channel first"}
            >
              <.icon name="hero-key" /> Issue test token
            </.button>
          </div>
        </form>
        <div :if={@test_token} id="test-token-result" class="space-y-1 text-sm">
          <.copy_field id="test-token-value" label="Token" value={@test_token.token} />
          <p class="text-base-content/60">
            End user <code>{@test_token.user_id || "(none)"}</code>, expires {Calendar.strftime(
              @test_token.expires_at,
              "%Y-%m-%d %H:%M:%S UTC"
            )}
          </p>
        </div>
      </section>

      <section class="space-y-2 rounded-box border border-base-300 bg-base-200 p-4">
        <div class="flex items-center gap-2">
          <h3 class="text-sm font-semibold">Publishable key</h3>
          <.badge
            id="publishable-key-status"
            value={if @channel.publishable_key, do: "active", else: "inactive"}
          >
            {if @channel.publishable_key, do: "Enabled", else: "Disabled"}
          </.badge>
        </div>
        <p class="text-sm text-base-content/70">
          A key that is safe in page source, for sites without a backend. It only works from the
          allowed origins, only creates anonymous visitors and gives each one a token for its own
          conversation (<code>POST /api/v1/converger/tokens/publishable</code>).
        </p>
        <.copy_field
          :if={@channel.publishable_key}
          id="publishable-key-value"
          label="Key"
          value={@channel.publishable_key}
        />
        <form id="allowed-origins-form" phx-submit="save_origins" class="space-y-2">
          <input type="hidden" name="access[channel_id]" value={@channel.id} />
          <.input
            type="textarea"
            id="allowed-origins"
            name="access[allowed_origins]"
            value={@origins_text}
            label="Allowed origins (one per line, e.g. https://shop.example.com or https://*.example.com)"
            rows="3"
          />
          <p :if={@origins_error} id="allowed-origins-error" role="alert" class="text-sm text-error">
            {@origins_error}
          </p>
          <div class="flex flex-wrap gap-2">
            <.button type="submit" size="sm" variant="neutral">Save origins</.button>
            <.button
              :if={is_nil(@channel.publishable_key)}
              id="enable-publishable-key"
              type="submit"
              name="key"
              value="new"
              size="sm"
              variant="primary"
            >
              Save and enable key
            </.button>
            <.button
              :if={@channel.publishable_key}
              id="rotate-publishable-key"
              type="button"
              phx-click="rotate_publishable_key"
              phx-value-id={@channel.id}
              data-confirm="Rotate the publishable key? The current key stops working immediately; update it on your site."
              size="sm"
              variant="neutral"
            >
              Rotate key
            </.button>
            <.button
              :if={@channel.publishable_key}
              id="disable-publishable-key"
              type="button"
              phx-click="disable_publishable_key"
              phx-value-id={@channel.id}
              data-confirm="Disable the publishable key? Widgets using it stop getting tokens."
              size="sm"
              variant="error"
            >
              Disable key
            </.button>
          </div>
        </form>
      </section>
    </.panel>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  # The value travels in data-copy, never inside the handler's JavaScript.
  defp copy_field(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="text-xs text-base-content/60">{@label}</span>
      <div class="flex items-center gap-1">
        <code id={@id} class="block min-w-0 flex-1 truncate rounded bg-base-100 p-1 font-mono text-xs" title={@value}>{@value}</code>
        <button
          type="button"
          data-copy={@value}
          onclick="navigator.clipboard.writeText(this.dataset.copy)"
          class="btn btn-ghost btn-xs"
          title={"Copy #{String.downcase(@label)}"}
        >
          Copy
        </button>
      </div>
    </div>
    """
  end
end
