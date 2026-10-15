defmodule ConvergerWeb.FallbackController do
  @moduledoc """
  Translates controller error returns to the API error envelope
  (`ConvergerWeb.APIError`, ADR-0050).

    * `{:error, %APIError{}}` - sent as is;
    * `{:error, %Ecto.Changeset{}}` - `422`, `invalid_message` for an
      activity, `validation_failed` otherwise, the errors per field in
      `details`;
    * `{:error, atom}` - the atoms below;
    * `{:error, message}` - `400 bad_request` with the message;
    * `nil` - `404 not_found`.
  """
  use ConvergerWeb, :controller

  alias Converger.Activities.Activity
  alias ConvergerWeb.APIError

  require Logger

  def call(conn, {:error, %APIError{} = error}), do: APIError.send_error(conn, error)

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    code =
      if match?(%Activity{}, changeset.data), do: "invalid_message", else: "validation_failed"

    APIError.send_error(conn, code, nil, APIError.changeset_details(changeset))
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    APIError.send_error(conn, from_atom(reason))
  end

  def call(conn, {:error, message}) when is_binary(message) do
    APIError.send_error(conn, "bad_request", message)
  end

  def call(conn, nil), do: APIError.send_error(conn, "not_found")

  defp from_atom(:not_found), do: APIError.new(:not_found)
  defp from_atom(:unauthorized), do: APIError.new(:unauthorized)
  defp from_atom(:forbidden), do: APIError.new(:forbidden)
  defp from_atom(:channel_inactive), do: APIError.new(:channel_inactive)
  defp from_atom(:inbound_not_supported), do: APIError.new(:inbound_not_supported)

  defp from_atom(:empty_inbound_message),
    do: APIError.new(:invalid_message, "Inbound message has no text and no attachments")

  # The activity was rolled back because its deliveries could not be enqueued.
  # Retrying is safe when an idempotency key is used.
  defp from_atom(:delivery_enqueue_failed),
    do:
      APIError.new(:unavailable, "Activity could not be accepted, please retry", %{
        reason: "delivery_enqueue_failed"
      })

  # The conversation is closed (manually or by inactivity) and does not accept
  # activities until it is reopened.
  defp from_atom(:conversation_closed), do: APIError.new(:conversation_closed)

  defp from_atom(:invalid_watermark), do: APIError.new(:invalid_watermark)
  defp from_atom(:invalid_cursor), do: APIError.new(:bad_request, "Invalid cursor")
  defp from_atom(:not_failed), do: APIError.new(:not_failed)

  # An error the controller did not expect: a server-side problem.
  defp from_atom(other) do
    Logger.error("Unhandled controller error: #{inspect(other)}")
    APIError.new(:internal)
  end
end
