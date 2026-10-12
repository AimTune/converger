defmodule ConvergerWeb.ChannelTemplateController do
  @moduledoc """
  `GET /api/v1/channels/:channel_id/templates`: the provider message
  templates (WhatsApp HSM) of a channel, proxied from the provider and cached
  (`Converger.Channels.Templates`). `?refresh=true` skips the cache.
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Channels
  alias Converger.Channels.Templates
  alias ConvergerWeb.APIError

  plug ConvergerWeb.Plugs.TenantAuth

  action_fallback ConvergerWeb.FallbackController

  tags(["Channels"])
  security([%{"apiKey" => []}, %{"channelToken" => []}])

  operation(:index,
    summary: "List a channel's message templates",
    description:
      "Provider message templates (WhatsApp HSM), proxied and cached per node for 5 minutes.",
    operation_id: "listChannelTemplates",
    parameters: [
      channel_id: path_id("Channel id"),
      refresh: query(%OpenApiSpex.Schema{type: :boolean}, "Skip the cache")
    ],
    responses:
      with_errors(
        %{200 => json_schema("The templates", ref("MessageTemplateList"))},
        [400, 401, 404, 422, 502]
      )
  )

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
        {:error,
         APIError.new(
           :unsupported_channel_type,
           "Channel type #{channel.type} has no message templates"
         )}

      {:error, {:invalid_config, message}} ->
        {:error, APIError.new(:invalid_channel_config, message)}

      {:error, message} ->
        {:error, APIError.new(:upstream_unavailable, to_string(message))}
    end
  end
end
