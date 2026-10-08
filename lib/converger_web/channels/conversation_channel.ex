defmodule ConvergerWeb.ConversationChannel do
  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, Conversations, Channels}

  @impl true
  def join("conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns[:claims] || %{}

    if authorized?(conversation_id, claims) do
      send(self(), {:after_join, payload})
      {:ok, socket}
    else
      Logger.warning("WebSocket channel join unauthorized",
        conversation_id: conversation_id,
        claims: claims
      )

      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("new_activity", payload, socket) do
    claims = socket.assigns.claims

    # Only client fields are taken from the payload; the sender is the
    # authenticated token subject, never client-supplied.
    system_attrs = %{
      tenant_id: claims["tenant_id"],
      conversation_id: claims["conversation_id"],
      sender: claims["sub"] || "user"
    }

    # The pipeline (run by create_activity) is the only delivery path: it
    # applies middleware, tracks deliveries, retries and fans out via routing rules.
    case Activities.create_client_activity(payload, system_attrs) do
      {:ok, _activity} ->
        {:reply, :ok, socket}

      {:error, :conversation_closed} ->
        {:reply, {:error, %{reason: "conversation_closed"}}, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, {:error, %{reason: "invalid_activity", errors: errors(changeset)}}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "invalid_activity"}}, socket}
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end

  @impl true
  def handle_info({:after_join, payload}, socket) do
    conversation_id = socket.assigns.claims["conversation_id"]

    conversation = Conversations.get_conversation!(conversation_id)
    channel = Channels.get_channel!(conversation.channel_id)

    socket =
      socket
      |> assign(:channel_type, channel.type)
      |> assign(:channel, channel)

    Logger.info("WebSocket channel joined",
      conversation_id: conversation_id,
      tenant_id: conversation.tenant_id
    )

    if last_id = payload["last_activity_id"] do
      conversation_id
      |> Activities.list_activities_after(last_id)
      |> Enum.each(fn activity ->
        # Same payload as the live `new_activity` broadcast.
        push(socket, "new_activity", Converger.Activities.Serializer.canonical(activity))
      end)
    end

    {:noreply, socket}
  end

  defp authorized?(conversation_id, %{"conversation_id" => claim_cid}) do
    conversation_id == claim_cid
  end

  defp authorized?(_, _), do: false
end
