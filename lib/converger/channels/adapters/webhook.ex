defmodule Converger.Channels.Adapters.Webhook do
  @behaviour Converger.Channels.Adapter

  require Logger

  @impl true
  def supported_modes, do: ~w(inbound outbound duplex)

  @impl true
  def validate_config(config) do
    cond do
      not is_binary(config["url"]) or config["url"] == "" ->
        {:error, "webhook config requires a 'url' field"}

      not valid_url?(config["url"]) ->
        {:error, "webhook config 'url' must be a valid HTTP/HTTPS URL"}

      true ->
        :ok
    end
  end

  @impl true
  def deliver_activity(channel, activity) do
    url = channel.config["url"]
    headers = Map.get(channel.config, "headers", %{})

    method =
      channel.config
      |> Map.get("method", "POST")
      |> String.downcase()
      |> String.to_existing_atom()

    # Canonical activity plus `timestamp`, kept for existing integrations.
    payload =
      activity
      |> Converger.Activities.Serializer.canonical()
      |> Map.put(:timestamp, activity.inserted_at)

    header_list = Enum.map(headers, fn {k, v} -> {k, v} end)

    req_options =
      [method: method, url: url, json: payload, headers: header_list, receive_timeout: 10_000]
      |> Keyword.merge(Application.get_env(:converger, :webhook_req_options, []))

    case Req.request(req_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "webhook returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "webhook request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  A generic webhook carries one message per request. A body that is a
  delivery receipt (see `parse_status_update/2`) carries no message.

  An optional string `"idempotency_key"` makes re-delivery of the same
  message safe: it is unique per conversation (or, for requests without a
  `conversation_id`, per channel). An optional `"external_id"` (plus
  `"display_name"`) identifies the external party, so that requests without
  a `conversation_id` join that participant's active conversation.
  """
  @impl true
  def parse_inbound(channel, params) do
    case parse_status_update(channel, params) do
      {:ok, _receipts} ->
        {:ok, []}

      :ignore ->
        {:ok,
         [
           %{
             "sender" => params["sender"] || params["from"] || "external",
             "text" => params["text"] || params["message"] || params["body"],
             "type" => params["type"] || "message",
             "metadata" => params["metadata"] || %{},
             "attachments" => params["attachments"] || [],
             "idempotency_key" => string_or_nil(params["idempotency_key"]),
             "participant" => participant(params)
           }
         ]}
    end
  end

  # Opt-in participant resolution: with an "external_id" (and no
  # conversation_id), messages from the same external party share their
  # open conversation instead of each starting a new one.
  defp participant(params) do
    case string_or_nil(params["external_id"]) do
      nil -> nil
      external_id -> %{"external_id" => external_id, "display_name" => params["display_name"]}
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  @impl true
  def parse_status_update(_channel, params) do
    cond do
      is_binary(params["delivery_id"]) and is_binary(params["status"]) ->
        {:ok,
         [
           %{
             "delivery_id" => params["delivery_id"],
             "status" => params["status"],
             "timestamp" => params["timestamp"],
             "error" => params["error"]
           }
         ]}

      is_binary(params["provider_message_id"]) and is_binary(params["status"]) ->
        {:ok,
         [
           %{
             "provider_message_id" => params["provider_message_id"],
             "status" => params["status"],
             "timestamp" => params["timestamp"],
             "error" => params["error"]
           }
         ]}

      true ->
        :ignore
    end
  end

  defp valid_url?(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and not is_nil(uri.host)
  end
end
