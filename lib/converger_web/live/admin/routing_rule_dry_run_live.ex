defmodule ConvergerWeb.Admin.RoutingRuleDryRunLive do
  @moduledoc """
  Admin routing dry-run: paste an activity, see which rules match and the
  payload each target channel would get (`Converger.RoutingRules.DryRun`).
  Nothing is stored or sent.
  """
  use ConvergerWeb, :live_view

  alias Converger.Channels
  alias Converger.RoutingRules.DryRun
  alias Converger.Tenants

  @example_activity ~s({\n  "type": "message",\n  "text": "I want to upgrade",\n  "sender": "905551112233",\n  "metadata": {"vip": true}\n})

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Routing Dry Run",
       tenants: Tenants.list_tenants(),
       channels: Channels.list_channels(),
       values: %{
         "tenant_id" => "",
         "source_channel_id" => "",
         "origin_channel_id" => "",
         "conversation_id" => "",
         "activity" => @example_activity,
         "conversation_metadata" => "",
         "participant" => "",
         "at" => ""
       },
       result: nil,
       error: nil
     )}
  end

  def handle_event("changed", %{"dry_run" => values}, socket) do
    {:noreply, assign(socket, values: Map.merge(socket.assigns.values, values))}
  end

  def handle_event("run", %{"dry_run" => values}, socket) do
    values = Map.merge(socket.assigns.values, values)
    socket = assign(socket, values: values)

    with {:ok, tenant_id} <- required(values["tenant_id"], "Select a tenant"),
         {:ok, params} <- build_params(values) do
      case DryRun.run(tenant_id, params) do
        {:ok, result} ->
          {:noreply, assign(socket, result: result, error: nil)}

        {:error, :not_found} ->
          {:noreply, assign(socket, result: nil, error: "Unknown channel or conversation")}

        {:error, {:bad_request, message}} ->
          {:noreply, assign(socket, result: nil, error: message)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           assign(socket, result: nil, error: "Invalid activity: " <> errors(changeset))}
      end
    else
      {:error, message} -> {:noreply, assign(socket, result: nil, error: message)}
    end
  end

  defp required(value, message) when value in [nil, ""], do: {:error, message}
  defp required(value, _message), do: {:ok, value}

  defp build_params(values) do
    with {:ok, activity} <- json(values["activity"], "Activity"),
         {:ok, metadata} <- json(values["conversation_metadata"], "Conversation metadata"),
         {:ok, participant} <- json(values["participant"], "Participant") do
      params =
        %{
          "activity" => activity || %{},
          "source_channel_id" => blank_to_nil(values["source_channel_id"]),
          "origin_channel_id" => blank_to_nil(values["origin_channel_id"]),
          "conversation_id" => blank_to_nil(values["conversation_id"]),
          "conversation" => metadata && %{"metadata" => metadata},
          "participant" => participant,
          "at" => blank_to_nil(values["at"])
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, params}
    end
  end

  defp json(text, label) do
    case String.trim(text || "") do
      "" ->
        {:ok, nil}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, value} -> {:ok, value}
          {:error, error} -> {:error, "#{label} is not valid JSON: #{Exception.message(error)}"}
        end
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp tenant_channels(channels, tenant_id),
    do: Enum.filter(channels, &(&1.tenant_id == tenant_id))

  defp channel_name(nil, _channels), do: "-"

  defp channel_name(channel_id, channels) do
    case Enum.find(channels, &(&1.id == channel_id)) do
      nil -> channel_id
      channel -> "#{channel.name} (#{channel.type})"
    end
  end

  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp outcome_class(:deliver), do: "badge-success"
  defp outcome_class(:halted), do: "badge-error"
  defp outcome_class(_), do: "badge-ghost"

  defp rule_class(:matched), do: "badge-success"
  defp rule_class(:not_matched), do: "badge-ghost"
  defp rule_class(:skipped), do: "badge-warning"

  defp channel_options(channels, tenant_id),
    do: channels |> tenant_channels(tenant_id) |> Enum.map(&{"#{&1.name} (#{&1.type})", &1.id})

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={@nav}>
      <.header>
        Routing Dry Run
        <:subtitle>
          Paste an activity and see which routing rules match and what every target channel would receive.
          Nothing is stored or sent.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/admin/routing_rules"} size="sm" variant="ghost">
            <.icon name="hero-arrow-left" /> Back to routing rules
          </.button>
        </:actions>
      </.header>

      <.panel>
        <form id="dry-run-form" phx-submit="run" phx-change="changed">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-5">
            <.input
              type="select"
              id="dry_run_tenant_id"
              name="dry_run[tenant_id]"
              label="Tenant"
              prompt="Select Tenant"
              options={Enum.map(@tenants, &{&1.name, &1.id})}
              value={@values["tenant_id"]}
            />
            <.input
              type="select"
              id="dry_run_source_channel_id"
              name="dry_run[source_channel_id]"
              label="Arrives on (source channel)"
              prompt="Conversation's origin"
              options={channel_options(@channels, @values["tenant_id"])}
              value={@values["source_channel_id"]}
            />
            <.input
              type="text"
              id="dry_run_conversation_id"
              name="dry_run[conversation_id]"
              label="Existing conversation id (optional)"
              value={@values["conversation_id"]}
              class="input w-full font-mono text-xs"
            />
            <.input
              type="select"
              id="dry_run_origin_channel_id"
              name="dry_run[origin_channel_id]"
              label="New conversation's origin (optional)"
              prompt="Same as source"
              options={channel_options(@channels, @values["tenant_id"])}
              value={@values["origin_channel_id"]}
            />
            <.input
              type="text"
              id="dry_run_at"
              name="dry_run[at]"
              label="Time (ISO 8601, optional)"
              value={@values["at"]}
              placeholder="2026-10-12T09:30:00Z"
            />
          </div>

          <div class="grid gap-x-4 md:grid-cols-2">
            <.input
              type="textarea"
              id="dry_run_activity"
              name="dry_run[activity]"
              label="Activity (JSON)"
              rows="9"
              value={@values["activity"]}
              class="textarea w-full font-mono text-xs"
            />
            <div>
              <.input
                type="textarea"
                id="dry_run_conversation_metadata"
                name="dry_run[conversation_metadata]"
                label="New conversation's metadata (JSON, optional)"
                rows="4"
                placeholder={~s({"department": "sales"})}
                value={@values["conversation_metadata"]}
                class="textarea w-full font-mono text-xs"
              />
              <.input
                type="textarea"
                id="dry_run_participant"
                name="dry_run[participant]"
                label="New conversation's participant (JSON, optional)"
                rows="3"
                placeholder={~s({"external_id": "905551112233"})}
                value={@values["participant"]}
                class="textarea w-full font-mono text-xs"
              />
            </div>
          </div>

          <.button type="submit" variant="primary">
            <.icon name="hero-play" /> Run
          </.button>
        </form>
      </.panel>

      <div :if={@error} id="dry-run-error" role="alert" class="alert alert-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        <span>{@error}</span>
      </div>

      <div :if={@result} id="dry-run-result" class="space-y-4">
        <.panel title="Route">
          <p class="text-sm">
            Direction: <strong id="dry-run-direction">{@result.direction}</strong>
            <span class="text-base-content/60">
              · origin {channel_name(@result.origin_channel_id, @channels)}
              · arrives on {channel_name(@result.source_channel_id, @channels)}
              · rules of {channel_name(@result.rule_source_channel_id, @channels)}
            </span>
          </p>
          <div :if={@result.rules != []} class="overflow-x-auto">
            <.table id="dry-run-rules" rows={@result.rules} row_id={&"dry-run-rule-#{&1.id}"}>
              <:col :let={rule} label="Rule"><span class="font-medium">{rule.name}</span></:col>
              <:col :let={rule} label="Priority">
                {rule.priority}{if rule.stop_processing, do: " (stop)"}
              </:col>
              <:col :let={rule} label="Result">
                <span class={["badge badge-sm whitespace-nowrap", rule_class(rule.result)]}>
                  {rule.result}
                </span>
              </:col>
              <:col :let={rule} label="Conditions">
                <code class="block max-w-96 font-mono text-xs break-all">
                  {Jason.encode!(rule.conditions)}
                </code>
              </:col>
            </.table>
          </div>
          <.empty_state :if={@result.rules == []}>
            No enabled rules for this source channel.
          </.empty_state>
        </.panel>

        <.panel title="Targets">
          <div class="divide-y divide-base-300">
            <div
              :for={target <- @result.targets}
              id={"dry-run-target-#{target.channel_id}"}
              class="space-y-2 py-3"
            >
              <div class="flex flex-wrap items-center gap-2">
                <strong>{target.channel_name}</strong>
                <span class="text-sm text-base-content/60">
                  ({target.channel_type}, {target.reason})
                </span>
                <span class={["badge badge-sm", outcome_class(target.outcome)]}>
                  {target.outcome}{if target.excluded, do: ": #{target.excluded}"}{if target.detail,
                    do: ": #{target.detail}"}
                </span>
              </div>
              <pre
                :if={target.payload}
                class="bg-base-200 rounded-box p-3 text-xs overflow-auto max-h-60"
              >{pretty(target.payload)}</pre>
            </div>
          </div>
          <.empty_state :if={@result.targets == []}>No delivery.</.empty_state>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
