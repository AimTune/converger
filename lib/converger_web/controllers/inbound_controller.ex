defmodule ConvergerWeb.InboundController do
  use ConvergerWeb, :controller

  require Logger

  alias Converger.{Channels, Activities, Conversations, Deliveries}
  alias Converger.Channels.Adapter

  action_fallback ConvergerWeb.FallbackController

  def create(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id),
         :ok <- verify_inbound_signature(conn, channel) do
      # Try parsing as status update first (WhatsApp sends statuses and messages
      # to the same endpoint)
      case Adapter.parse_status_update(channel, params) do
        {:ok, status_updates} when status_updates != [] ->
          process_status_updates(conn, channel, status_updates)

        _ ->
          process_inbound_message(conn, channel, params)
      end
    end
  end

  def status(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id),
         :ok <- verify_inbound_signature(conn, channel),
         {:ok, status_updates} <- Adapter.parse_status_update(channel, params) do
      process_status_updates(conn, channel, status_updates)
    end
  end

  # Meta's webhook handshake requires echoing `hub.challenge` verbatim once the
  # verify token matches.
  # sobelow_skip ["XSS.SendResp"]
  def verify(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id) do
      case channel.type do
        "whatsapp_meta" ->
          verify_token = channel.config["verify_token"]

          provided = params["hub.verify_token"]

          if is_binary(verify_token) and is_binary(provided) and
               Plug.Crypto.secure_compare(provided, verify_token) do
            send_resp(conn, 200, params["hub.challenge"] || "")
          else
            send_resp(conn, 403, "Verification failed")
          end

        _ ->
          send_resp(conn, 200, "ok")
      end
    end
  end

  defp process_status_updates(conn, channel, status_updates) do
    results =
      Enum.map(status_updates, fn update ->
        Deliveries.apply_status_update(channel.id, update)
      end)

    processed =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    Logger.info("Status updates processed",
      channel_id: channel.id,
      total: length(results),
      processed: processed
    )

    conn
    |> put_status(:ok)
    |> json(%{status: "accepted", receipts_processed: processed})
  end

  defp process_inbound_message(conn, channel, params) do
    with :ok <- verify_inbound_capable(channel),
         {:ok, parsed} <- Adapter.parse_inbound(channel, params),
         {:ok, conversation} <- resolve_or_create_conversation(channel, params),
         {:ok, activity} <-
           Activities.create_client_activity(parsed, %{
             tenant_id: channel.tenant_id,
             conversation_id: conversation.id,
             sender: parsed["sender"]
           }) do
      Logger.info("Inbound activity received",
        channel_id: channel.id,
        activity_id: activity.id
      )

      conn
      |> put_status(:created)
      |> json(%{status: "accepted", activity_id: activity.id})
    end
  end

  defp verify_inbound_capable(%{mode: mode}) when mode in ["inbound", "duplex"], do: :ok
  defp verify_inbound_capable(_channel), do: {:error, :inbound_not_supported}

  # Signature policy:
  #   * a signature that is present but invalid is always rejected (401);
  #   * channels with `require_signature: true` reject missing signatures and
  #     legacy (non-timestamped) generic signatures;
  #   * channels with `require_signature: false` (pre-existing channels) still
  #     accept unsigned / legacy-signed requests, with a deprecation warning.
  defp verify_inbound_signature(conn, channel) do
    raw_body = conn.assigns[:raw_body]

    case Adapter.verify_inbound_signature(channel, conn.req_headers, raw_body) do
      :ok ->
        :ok

      result when result in [:missing, :legacy] ->
        if channel.require_signature do
          Logger.warning("Rejected inbound request: signature required",
            channel_id: channel.id,
            reason: result
          )

          {:error, :unauthorized}
        else
          Logger.warning(
            "DEPRECATED: accepted inbound request with #{deprecation_reason(result)}. " <>
              "Sign requests and enable require_signature on this channel; " <>
              "unsigned requests will be rejected in a future release.",
            channel_id: channel.id
          )

          :ok
        end

      {:error, reason} ->
        Logger.warning("Rejected inbound request: invalid signature",
          channel_id: channel.id,
          reason: inspect(reason)
        )

        {:error, :unauthorized}
    end
  end

  defp deprecation_reason(:missing), do: "no signature"
  defp deprecation_reason(:legacy), do: "a legacy (non-timestamped) signature"

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
