defmodule Converger.Channels.Adapters.Messenger do
  @moduledoc """
  Facebook Messenger channel adapter (duplex) for a Facebook Page.

    * Inbound: Messenger Platform webhooks (`object: "page"`) on
      `POST /api/v1/channels/:id/inbound`, signed with `X-Hub-Signature-256`
      (the app secret), and the `hub.challenge` handshake on `GET`.
    * Outbound: the Send API (`POST /<version>/<page_id>/messages`) with the
      Page access token: files as attachment messages (files stored in
      Converger are uploaded), text with card buttons as quick replies.
    * Receipts: `delivery` events mark deliveries `delivered`.

  Signatures, the handshake, Graph errors and media downloads are shared with
  `whatsapp_meta` and `instagram` (`Converger.Channels.Meta.Graph`,
  `Converger.Channels.Meta.Messaging`). See `docs/channels/messenger.md`.
  """

  use Converger.Channels.Adapter, type: "messenger"

  alias Converger.Channels.Meta.{Graph, Messaging}

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      :media,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "page_id",
        type: :string,
        required: true,
        label: "Page ID",
        placeholder: "e.g. 104512345678901",
        summary: true
      },
      %{
        name: "page_access_token",
        type: :string,
        required: true,
        secret: true,
        label: "Page Access Token",
        placeholder: "Page token with pages_messaging"
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
        help: "Store inbound images, audio, video and files in Converger (default true)"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    if Regex.match?(~r/\A\d+\z/, to_string(config["page_id"])),
      do: :ok,
      else: {:error, "messenger config 'page_id' must be a numeric Page ID"}
  end

  @doc false
  def spec(channel) do
    config = Map.get(channel, :config) || %{}

    %{
      provider: "messenger",
      object: "page",
      label: "Messenger API",
      host: "graph.facebook.com",
      version: Graph.version(channel, __MODULE__),
      account_id: config["page_id"],
      token: config["page_access_token"],
      req_options_key: :messenger_req_options,
      upload?: true,
      # Send API: text messages up to 2000 characters.
      max_text: 2000
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

  @doc "Reads the Page (`GET /<version>/<page_id>?fields=id`) with the Page token."
  @impl true
  def health_probe(channel), do: Messaging.health_probe(spec(channel))
end
