defmodule ConvergerWeb.Admin.ConversationLive do
  use ConvergerWeb, :live_view

  alias Converger.Repo

  alias Converger.Tenants
  alias Converger.Channels
  alias Converger.Activities

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: Tenants.list_tenants(),
       channels: Channels.list_channels(),
       filters: %{"tenant_id" => "", "channel_id" => "", "status" => ""},
       page_title: "Conversations"
     )}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filters = Map.merge(socket.assigns.filters, params)

    conversations =
      Converger.Conversations.list_conversations(filters)
      |> Repo.preload([:tenant, :channel])
      |> Enum.sort_by(& &1.inserted_at, :desc)

    assign(socket, conversations: conversations, filters: filters)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    conversation =
      Converger.Conversations.get_conversation!(id)
      |> Repo.preload([:tenant, :channel])

    activities = Activities.list_activities_for_conversation(id)

    assign(socket, conversation: conversation, activities: activities)
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/conversations?#{filters}")}
  end

  def render(assigns) do
    case assigns.live_action do
      :index -> render_index(assigns)
      :show -> render_show(assigns)
    end
  end

  defp render_index(assigns) do
    ~H"""
    <h1>Conversations</h1>

    <div class="card" style="margin-bottom: 20px;">
      <form phx-change="filter" id="filter-form">
        <div style="display: flex; gap: 15px; align-items: flex-end;">
          <div class="input-group" style="margin-bottom: 0;">
            <label>Tenant</label>
            <select name="filters[tenant_id]">
              <option value="">All Tenants</option>
              <option :for={t <- @tenants} value={t.id} selected={@filters["tenant_id"] == t.id}>
                <%= t.name %>
              </option>
            </select>
          </div>

          <div class="input-group" style="margin-bottom: 0;">
            <label>Channel</label>
            <select name="filters[channel_id]">
              <option value="">All Channels</option>
              <option :for={c <- @channels} value={c.id} selected={@filters["channel_id"] == c.id}>
                <%= c.name %> (<%= c.tenant.name %>)
              </option>
            </select>
          </div>

          <div class="input-group" style="margin-bottom: 0;">
            <label>Status</label>
            <select name="filters[status]">
              <option value="">All Statuses</option>
              <option value="active" selected={@filters["status"] == "active"}>Active</option>
              <option value="closed" selected={@filters["status"] == "closed"}>Closed</option>
            </select>
          </div>

          <a href={~p"/admin/conversations"} class="button button-outline" style="margin-bottom: 2px;">Reset</a>
        </div>
      </form>
    </div>

    <div class="card">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Tenant</th>
            <th>Channel</th>
            <th>Status</th>
            <th>Created</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={c <- @conversations}>
            <td><small><%= c.id %></small></td>
            <td><%= c.tenant.name %></td>
            <td><%= c.channel.name %></td>
            <td>
              <span class={"badge badge-#{c.status}"}>
                <%= c.status %>
              </span>
            </td>
            <td><%= c.inserted_at %></td>
            <td>
              <.link patch={~p"/admin/conversations/#{c.id}"} class="button button-clear">View Events</.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <div style="margin-bottom: 20px;">
      <.link patch={~p"/admin/conversations"} class="button button-outline">&larr; Back to List</.link>
    </div>

    <h1>Conversation Details</h1>

    <div class="card" style="margin-bottom: 20px;">
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div>
          <label>ID</label>
          <p><code><%= @conversation.id %></code></p>
          <label>Tenant</label>
          <p><%= @conversation.tenant.name %></p>
        </div>
        <div>
          <label>Channel</label>
          <p><%= @conversation.channel.name %> (<%= @conversation.channel.type %>)</p>
          <label>Status</label>
          <p>
            <span class={"badge badge-#{@conversation.status}"}>
              <%= @conversation.status %>
            </span>
          </p>
        </div>
      </div>
    </div>

    <h2>Events (Activities)</h2>
    <div class="card">
      <table>
        <thead>
          <tr>
            <th>Time</th>
            <th>Sender</th>
            <th>Message</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={a <- @activities}>
            <td style="white-space: nowrap;"><small><%= a.inserted_at %></small></td>
            <td><strong><%= a.sender %></strong></td>
            <td><%= a.text %></td>
          </tr>
          <tr :if={Enum.empty?(@activities)}>
            <td colspan="3" style="text-align: center; color: #999;">No activities found</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
