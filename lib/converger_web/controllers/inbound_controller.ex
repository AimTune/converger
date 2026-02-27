defmodule ConvergerWeb.InboundController do
  use ConvergerWeb, :controller

  require Logger

  alias Converger.{Channels, Activities, Conversations}
  alias Converger.Channels.Adapter

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id),
         :ok <- verify_inbound_capable(channel),
         :ok <- verify_inbound_signature(conn, channel),
         {:ok, parsed} <- Adapter.parse_inbound(channel, params),
         {:ok, conversation} <- resolve_or_create_conversation(channel, params),
         {:ok, activity} <-
           Activities.create_activity(
             parsed
             |> Map.put("tenant_id", channel.tenant_id)
             |> Map.put("conversation_id", conversation.id)
           ) do
      Logger.info("Inbound activity received",
        channel_id: channel_id,
        activity_id: activity.id
      )

      conn
      |> put_status(:created)
      |> json(%{status: "accepted", activity_id: activity.id})
    end
  end

  def verify(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id) do
      case channel.type do
        "whatsapp_meta" ->
          verify_token = channel.config["verify_token"]

          if params["hub.verify_token"] == verify_token do
            send_resp(conn, 200, params["hub.challenge"] || "")
          else
            send_resp(conn, 403, "Verification failed")
          end

        _ ->
          send_resp(conn, 200, "ok")
      end
    end
  end

  defp verify_inbound_capable(%{mode: mode}) when mode in ["inbound", "duplex"], do: :ok
  defp verify_inbound_capable(_channel), do: {:error, :inbound_not_supported}

  defp verify_inbound_signature(conn, channel) do
    signature = get_req_header(conn, "x-converger-signature") |> List.first()

    if signature && channel.secret do
      raw_body = conn.assigns[:raw_body]

      if raw_body do
        expected =
          :crypto.mac(:hmac, :sha256, channel.secret, raw_body)
          |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare("sha256=#{expected}", signature) do
          :ok
        else
          {:error, :unauthorized}
        end
      else
        :ok
      end
    else
      # Signature verification is optional when header is not present
      :ok
    end
  end

  defp resolve_or_create_conversation(channel, params) do
    conversation_id = params["conversation_id"]

    if conversation_id do
      case Conversations.get_conversation(conversation_id, channel.tenant_id) do
        %Conversations.Conversation{} = conv -> {:ok, conv}
        nil -> {:error, :not_found}
      end
    else
      Conversations.create_conversation(%{
        "tenant_id" => channel.tenant_id,
        "channel_id" => channel.id,
        "metadata" => %{"source" => "inbound_webhook"}
      })
    end
  end
end
