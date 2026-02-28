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

    payload = %{
      id: activity.id,
      type: activity.type,
      sender: activity.sender,
      text: activity.text,
      attachments: activity.attachments,
      metadata: activity.metadata,
      conversation_id: activity.conversation_id,
      tenant_id: activity.tenant_id,
      timestamp: activity.inserted_at
    }

    header_list = Enum.map(headers, fn {k, v} -> {k, v} end)

    case Req.request(
           method: method,
           url: url,
           json: payload,
           headers: header_list,
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "webhook returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "webhook request failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def parse_inbound(_channel, params) do
    {:ok,
     %{
       "sender" => params["sender"] || params["from"] || "external",
       "text" => params["text"] || params["message"] || params["body"],
       "type" => params["type"] || "message",
       "metadata" => params["metadata"] || %{},
       "attachments" => params["attachments"] || []
     }}
  end

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
