defmodule ConvergerWeb.ChannelTemplateController do
  @moduledoc """
  `GET /api/v1/channels/:channel_id/templates`: the provider message
  templates (WhatsApp HSM) of a channel, proxied from the provider and cached
  (`Converger.Channels.Templates`). `?refresh=true` skips the cache.
  """
  use ConvergerWeb, :controller

  alias Converger.Channels
  alias Converger.Channels.Templates

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  def index(conn, %{"channel_id" => id} = params) do
    channel = Channels.get_channel!(id, conn.assigns.tenant.id)

    case Templates.list(channel, refresh: params["refresh"] in ["true", "1"]) do
      {:ok, templates, meta} ->
        json(conn, %{
          data: templates,
          cached: meta.cached,
          fetched_at: DateTime.to_iso8601(meta.fetched_at)
        })

      {:error, :unsupported} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Channel type #{channel.type} has no message templates"})

      {:error, {:invalid_config, message}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, message} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: message})
    end
  end
end
