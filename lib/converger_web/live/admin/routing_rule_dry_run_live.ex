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

  defp outcome_color(:deliver), do: "#2e7d32"
  defp outcome_color(:halted), do: "#c62828"
  defp outcome_color(_), do: "#757575"

  defp rule_color(:matched), do: "#2e7d32"
  defp rule_color(:not_matched), do: "#757575"
  defp rule_color(:skipped), do: "#ef6c00"

  def render(assigns) do
    ~H"""
    <h1 style="margin-bottom: 5px;">Routing Dry Run</h1>
    <p style="color: #666; margin-top: 0; margin-bottom: 20px;">
      Paste an activity and see which routing rules match and what every target channel would receive.
      Nothing is stored or sent. <.link navigate={~p"/admin/routing_rules"}>Back to routing rules</.link>
    </p>

    <div class="card">
      <form id="dry-run-form" phx-submit="run" phx-change="changed">
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 15px;">
          <div>
            <label for="dry_run_tenant_id" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">Tenant</label>
            <select id="dry_run_tenant_id" name="dry_run[tenant_id]" style="width: 100%; padding: 8px;">
              <option value="">Select Tenant</option>
              <option :for={tenant <- @tenants} value={tenant.id} selected={@values["tenant_id"] == tenant.id}>
                {tenant.name}
              </option>
            </select>
          </div>
          <div>
            <label for="dry_run_source_channel_id" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Arrives on (source channel)
            </label>
            <select id="dry_run_source_channel_id" name="dry_run[source_channel_id]" style="width: 100%; padding: 8px;">
              <option value="">Conversation's origin</option>
              <option
                :for={ch <- tenant_channels(@channels, @values["tenant_id"])}
                value={ch.id}
                selected={@values["source_channel_id"] == ch.id}
              >
                {ch.name} ({ch.type})
              </option>
            </select>
          </div>
          <div>
            <label for="dry_run_conversation_id" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Existing conversation id (optional)
            </label>
            <input id="dry_run_conversation_id" type="text" name="dry_run[conversation_id]" value={@values["conversation_id"]} style="width: 100%; padding: 8px;" />
          </div>
          <div>
            <label for="dry_run_origin_channel_id" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              New conversation's origin (optional)
            </label>
            <select id="dry_run_origin_channel_id" name="dry_run[origin_channel_id]" style="width: 100%; padding: 8px;">
              <option value="">Same as source</option>
              <option
                :for={ch <- tenant_channels(@channels, @values["tenant_id"])}
                value={ch.id}
                selected={@values["origin_channel_id"] == ch.id}
              >
                {ch.name} ({ch.type})
              </option>
            </select>
          </div>
          <div>
            <label for="dry_run_at" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              Time (ISO 8601, optional)
            </label>
            <input id="dry_run_at" type="text" name="dry_run[at]" value={@values["at"]} placeholder="2026-10-12T09:30:00Z" style="width: 100%; padding: 8px;" />
          </div>
        </div>

        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 15px; margin-top: 15px;">
          <div>
            <label for="dry_run_activity" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">Activity (JSON)</label>
            <textarea id="dry_run_activity" name="dry_run[activity]" rows="9" style="width: 100%; font-family: monospace; font-size: 0.85em;">{@values["activity"]}</textarea>
          </div>
          <div>
            <label for="dry_run_conversation_metadata" style="display: block; font-weight: 600; margin-bottom: 5px; font-size: 0.9em; color: #555;">
              New conversation's metadata (JSON, optional)
            </label>
            <textarea id="dry_run_conversation_metadata" name="dry_run[conversation_metadata]" rows="4" placeholder={~s({"department": "sales"})} style="width: 100%; font-family: monospace; font-size: 0.85em;">{@values["conversation_metadata"]}</textarea>
            <label for="dry_run_participant" style="display: block; font-weight: 600; margin: 8px 0 5px; font-size: 0.9em; color: #555;">
              New conversation's participant (JSON, optional)
            </label>
            <textarea id="dry_run_participant" name="dry_run[participant]" rows="3" placeholder={~s({"external_id": "905551112233"})} style="width: 100%; font-family: monospace; font-size: 0.85em;">{@values["participant"]}</textarea>
          </div>
        </div>

        <button type="submit" style="margin-top: 15px; padding: 8px 20px;">Run</button>
      </form>
    </div>

    <div :if={@error} id="dry-run-error" class="card" style="color: #c62828;">{@error}</div>

    <div :if={@result} id="dry-run-result">
      <div class="card">
        <h3 style="margin-top: 0;">Route</h3>
        <p>
          Direction: <strong id="dry-run-direction">{@result.direction}</strong>
          · origin {channel_name(@result.origin_channel_id, @channels)}
          · arrives on {channel_name(@result.source_channel_id, @channels)}
          · rules of {channel_name(@result.rule_source_channel_id, @channels)}
        </p>
        <table>
          <thead>
            <tr>
              <th>Rule</th>
              <th>Priority</th>
              <th>Result</th>
              <th>Conditions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @result.rules} id={"dry-run-rule-#{rule.id}"}>
              <td>{rule.name}</td>
              <td>{rule.priority}{if rule.stop_processing, do: " (stop)"}</td>
              <td style={"color: #{rule_color(rule.result)}; font-weight: 600;"}>{rule.result}</td>
              <td><code style="font-size: 0.8em;">{Jason.encode!(rule.conditions)}</code></td>
            </tr>
          </tbody>
        </table>
        <p :if={@result.rules == []} style="color: #888;">No enabled rules for this source channel.</p>
      </div>

      <div class="card">
        <h3 style="margin-top: 0;">Targets</h3>
        <div
          :for={target <- @result.targets}
          id={"dry-run-target-#{target.channel_id}"}
          style="border-top: 1px solid #eee; padding: 10px 0;"
        >
          <strong>{target.channel_name}</strong>
          <span style="color: #888;">({target.channel_type}, {target.reason})</span>
          <span style={"color: #{outcome_color(target.outcome)}; font-weight: 600; margin-left: 8px;"}>
            {target.outcome}{if target.excluded, do: ": #{target.excluded}"}{if target.detail, do: ": #{target.detail}"}
          </span>
          <pre :if={target.payload} style="background: #f8f9fa; padding: 8px; font-size: 0.8em; overflow-x: auto;">{pretty(target.payload)}</pre>
        </div>
        <p :if={@result.targets == []} style="color: #888;">No delivery.</p>
      </div>
    </div>
    """
  end
end
