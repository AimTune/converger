defmodule ConvergerWeb.InboundController do
  use ConvergerWeb, :controller

  require Logger

  alias Converger.{Channels, Activities, Conversations, Deliveries}
  alias Converger.Channels.Adapter

  action_fallback ConvergerWeb.FallbackController

  # Channel types whose provider retries any non-200 response (for days, in
  # Meta's case). They always get 200 once the request has been handled,
  # including for messages rejected permanently (retrying cannot fix those).
  @provider_ack_types ~w(whatsapp_meta whatsapp_infobip)

  @doc """
  Inbound webhook. A request may carry several messages and status updates
  (providers batch them, and WhatsApp sends both to the same endpoint).

  ## Batch semantics: per message, idempotent

  Messages are processed in order, each in its own transaction (an activity
  plus its delivery jobs). A batch is not all-or-nothing; instead every
  message carries its provider message id as idempotency key, so the batch
  can always be retried safely:

    * created or already-known (duplicate) messages count as handled;
    * a message rejected permanently (invalid activity, e.g. too large) is
      logged and skipped - retrying would never succeed;
    * a transient failure (e.g. the delivery jobs could not be enqueued) stops
      processing and returns an error, so the provider re-delivers the whole
      batch. Messages committed before the failure are recognised as
      duplicates on re-delivery and the remaining ones are created, in order.

  Status updates are applied best-effort before the messages.
  """
  def create(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, channel} <- Channels.get_active_channel(channel_id),
         :ok <- verify_inbound_signature(conn, channel) do
      status_updates =
        case Adapter.parse_status_update(channel, params) do
          {:ok, updates} when is_list(updates) -> updates
          _ -> []
        end

      case Adapter.parse_inbound(channel, params) do
        {:ok, [_ | _] = messages} ->
          receipts = apply_status_updates(channel, status_updates)
          process_inbound_messages(conn, channel, params, messages, receipts)

        {:ok, []} ->
          process_status_updates(conn, channel, status_updates)

        {:error, _} when status_updates != [] ->
          process_status_updates(conn, channel, status_updates)

        {:error, _} = error ->
          error
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
    processed = apply_status_updates(channel, status_updates)

    conn
    |> put_status(:ok)
    |> json(%{status: "accepted", receipts_processed: processed})
  end

  defp apply_status_updates(_channel, []), do: 0

  defp apply_status_updates(channel, status_updates) do
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

    processed
  end

  defp process_inbound_messages(conn, channel, params, messages, receipts) do
    case verify_inbound_capable(channel) do
      :ok ->
        messages
        |> Enum.reduce_while([], fn message, acc ->
          case process_inbound_message(channel, params, message) do
            {:error, _} = error -> {:halt, error}
            result -> {:cont, [result | acc]}
          end
        end)
        |> respond_to_inbound(conn, channel, receipts)

      # Statuses for an outbound-only channel arrived together with messages:
      # acknowledge the statuses, drop the messages the channel does not accept.
      {:error, _} when receipts > 0 ->
        Logger.warning("Dropped inbound messages on a channel that is not inbound-capable",
          channel_id: channel.id,
          count: length(messages)
        )

        conn
        |> put_status(:ok)
        |> json(%{status: "accepted", receipts_processed: receipts})

      {:error, _} = error ->
        error
    end
  end

  # Returns {:created, activity}, {:duplicate, activity}, {:rejected, changeset}
  # or {:error, reason} (request-level or transient: stop and let the sender retry).
  defp process_inbound_message(channel, params, message) do
    key = message["idempotency_key"]

    case Activities.get_activity_by_channel_idempotency_key(channel.id, key) do
      %Activities.Activity{} = existing ->
        Logger.info("Duplicate inbound message ignored",
          channel_id: channel.id,
          activity_id: existing.id
        )

        {:duplicate, existing}

      nil ->
        with {:ok, conversation} <- resolve_or_create_conversation(channel, params) do
          create_inbound_activity(channel, conversation, message)
        end
    end
  end

  defp create_inbound_activity(channel, conversation, message) do
    case Activities.create_client_activity(message, %{
           tenant_id: channel.tenant_id,
           conversation_id: conversation.id,
           sender: message["sender"],
           idempotency_key: message["idempotency_key"]
         }) do
      {:ok, activity} ->
        Logger.info("Inbound activity received",
          channel_id: channel.id,
          activity_id: activity.id
        )

        {:created, activity}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("Rejected inbound message",
          channel_id: channel.id,
          errors: inspect(changeset.errors)
        )

        {:rejected, changeset}

      {:error, _} = error ->
        error
    end
  end

  defp respond_to_inbound({:error, _} = error, _conn, _channel, _receipts), do: error

  defp respond_to_inbound(results, conn, channel, receipts) do
    results = Enum.reverse(results)
    accepted = for {tag, activity} <- results, tag in [:created, :duplicate], do: activity
    created = Enum.count(results, &match?({:created, _}, &1))
    rejected = for {:rejected, changeset} <- results, do: changeset

    provider_ack? = channel.type in @provider_ack_types

    if accepted == [] and not provider_ack? do
      # A generic webhook client sent an invalid message: tell it why.
      {:error, hd(rejected)}
    else
      # Generic webhooks keep 201 Created; providers get the 200 they expect.
      status = if created > 0 and not provider_ack?, do: :created, else: :ok

      conn
      |> put_status(status)
      |> json(%{
        status: "accepted",
        activity_id: accepted |> List.first() |> then(&(&1 && &1.id)),
        activity_ids: Enum.map(accepted, & &1.id),
        duplicates: Enum.count(results, &match?({:duplicate, _}, &1)),
        rejected: length(rejected),
        receipts_processed: receipts
      })
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
