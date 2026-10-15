defmodule Converger.Channels.Adapters.Instagram do
  @moduledoc """
  Instagram Direct (DM) channel adapter (duplex) for an Instagram
  professional account, through the Messenger Platform.

    * Inbound: webhooks with `object: "instagram"` on
      `POST /api/v1/channels/:id/inbound`, signed with `X-Hub-Signature-256`
      (the app secret), and the `hub.challenge` handshake on `GET`.
    * Outbound: the Send API (`POST /<version>/<account_id>/messages`):
      on `graph.facebook.com` with a Page access token ("Instagram API with
      Facebook Login", `account_id` = the linked Page id), or on
      `graph.instagram.com` with an Instagram user token ("Instagram API with
      Instagram Login", `account_id` = the Instagram account id).
    * Receipts: `read` events with a `mid` mark deliveries `read`.

  Instagram fetches media from a URL: files stored in Converger cannot be
  sent (permanent error). Shares the Meta code with `whatsapp_meta` and
  `messenger`. See `docs/channels/instagram.md`.
  """

  use Converger.Channels.Adapter, type: "instagram"

  alias Converger.Channels.Meta.{Graph, Messaging}

  @hosts ~w(graph.facebook.com graph.instagram.com)

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      :media,
      activity_types: ~w(message),
      # Typed media messages arrive as file attachments (#68, ADR-0064);
      # actions as a numbered list (Converger.Channels.RichContent).
      message_types: ~w(image file video audio)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "account_id",
        type: :string,
        required: true,
        label: "Account ID",
        placeholder: "Page ID (Facebook Login) or Instagram account ID",
        help: "The id the Send API is called on: /<account_id>/messages",
        summary: true
      },
      %{
        name: "access_token",
        type: :string,
        required: true,
        secret: true,
        label: "Access Token",
        placeholder: "Page token or Instagram user token"
      },
      %{
        name: "api_host",
        type: :string,
        label: "API host",
        placeholder: "graph.facebook.com",
        help: "graph.facebook.com (Facebook Login) or graph.instagram.com (Instagram Login)"
      },
      %{
        name: "verify_token",
        type: :string,
        required: true,
        secret: true,
        label: "Verify Token",
        placeholder: "Webhook verify token"
      },
      %{
        name: "app_secret",
        type: :string,
        required: :with_signature,
        secret: true,
        label: "App Secret",
        placeholder: "Signs X-Hub-Signature-256"
      },
      %{
        name: "graph_api_version",
        type: :string,
        label: "Graph API version",
        placeholder: Graph.default_version()
      },
      %{
        name: "download_media",
        type: :boolean,
        label: "Download inbound media",
        help: "Store inbound images, audio, video and story media in Converger (default true)"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    cond do
      not Regex.match?(~r/\A\d+\z/, to_string(config["account_id"])) ->
        {:error, "instagram config 'account_id' must be a numeric id"}

      config["api_host"] not in [nil, "" | @hosts] ->
        {:error, "instagram config 'api_host' must be one of #{Enum.join(@hosts, ", ")}"}

      true ->
        :ok
    end
  end

  # Instagram Send API: 100 calls per second per professional account for
  # text, links, reactions and stickers.
  @impl true
  def rate_limit, do: "100/s"

  @doc false
  def spec(channel) do
    config = Map.get(channel, :config) || %{}

    %{
      provider: "instagram",
      object: "instagram",
      label: "Instagram API",
      host: if(config["api_host"] in @hosts, do: config["api_host"], else: "graph.facebook.com"),
      version: Graph.version(channel, __MODULE__),
      account_id: config["account_id"],
      token: config["access_token"],
      req_options_key: :instagram_req_options,
      upload?: false,
      # Instagram text messages: 1000 bytes; 500 characters keeps any UTF-8 text under it.
      max_text: 500
    }
  end

  @impl true
  def deliver_activity(channel, activity) do
    spec = Map.put(spec(channel), :timeout_ms, Messaging.timeout_ms(channel))
    Messaging.deliver(channel, activity, spec)
  end

  @impl true
  def parse_inbound(channel, params), do: Messaging.parse_inbound(params, spec(channel))

  @impl true
  def parse_status_update(channel, params),
    do: Messaging.parse_status_update(params, spec(channel))

  @impl true
  def fetch_media(channel, attachment), do: Messaging.fetch_media(attachment, spec(channel))

  @doc "Verifies `X-Hub-Signature-256` with the channel's `app_secret`."
  @impl true
  def verify_inbound_signature(channel, headers, raw_body),
    do: Graph.verify_signature((channel.config || %{})["app_secret"], headers, raw_body)

  @doc "Meta's `hub.challenge` handshake against the channel's `verify_token`."
  @impl true
  def verify_subscription(channel, params),
    do: Graph.verify_subscription((channel.config || %{})["verify_token"], params)

  @doc "Reads the account (`GET /<version>/<account_id>?fields=id`) with the token."
  @impl true
  def health_probe(channel), do: Messaging.health_probe(spec(channel))
end
