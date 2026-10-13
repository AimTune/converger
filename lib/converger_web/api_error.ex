defmodule ConvergerWeb.APIError do
  @moduledoc """
  The one error envelope of the HTTP API (issue #45, ADR-0050):

      {"error": {"code": "conversation_closed",
                 "message": "Conversation is closed",
                 "details": null,
                 "request_id": "F6x..."}}

    * `code` - stable, machine-readable key from `codes/0`. Codes the REST
      API shares with Converger Protocol v1 (docs/protocol/v1.md section 12.2)
      are spelled the same.
    * `message` - human-readable, may change; never parse it.
    * `details` - `null` or an object with code-specific data (changeset
      errors per field, `retry_after_ms`, the supported subprotocols, ...).
    * `request_id` - the `x-request-id` of the request (`Plug.RequestId`),
      also on the server's log lines; `null` when not known.

  Every key is always present. Controllers return
  `{:error, APIError.new(code, message, details)}` to the
  `ConvergerWeb.FallbackController`; plugs call `send_error/4` directly.
  """

  import Plug.Conn

  defstruct [:code, :status, :message, :details]

  @type t :: %__MODULE__{
          code: String.t(),
          status: pos_integer(),
          message: String.t(),
          details: map() | nil
        }

  # code => {default HTTP status, default message, description for the docs}
  @codes [
    {"bad_request", 400, "Bad request",
     "Malformed request: invalid JSON, a missing or mistyped parameter, an invalid cursor or filter"},
    {"invalid_watermark", 400, "Invalid watermark", "The watermark could not be decoded"},
    {"channel_inactive", 400, "Channel is inactive",
     "The addressed channel is disabled (403 when it is the channel of the presented token)"},
    {"inbound_not_supported", 400, "Channel does not accept inbound messages",
     "Inbound message to an outbound-only channel, or a payload the channel type cannot parse"},
    {"unsupported_protocol", 400, "Unsupported WebSocket subprotocol",
     "The WebSocket upgrade offered only subprotocols the server does not speak"},
    {"unauthorized", 401, "Unauthorized",
     "Missing or invalid credential (API key, token, channel secret, inbound signature)"},
    {"token_expired", 401, "Token expired", "The Converger token expired; refresh or reissue it"},
    {"token_revoked", 401, "Token revoked",
     "The Converger token was revoked, refreshed more than the grace period ago, or reused after rotation (which revokes its family); generate a new one"},
    {"forbidden", 403, "Forbidden",
     "Authenticated but not allowed: wrong conversation for the token, channel token where an API key is required, IP not allowed"},
    {"insufficient_permission", 403, "Insufficient permission",
     "The Converger token lacks the permission (read, write, typing) the operation needs; details.required names it"},
    {"not_found", 404, "Not found",
     "Unknown route or resource, or a resource of another tenant or channel (existence is never revealed)"},
    {"method_not_allowed", 405, "Method not allowed", "The route does not accept this method"},
    {"not_acceptable", 406, "Not acceptable", "The Accept header excludes JSON"},
    {"conversation_closed", 409, "Conversation is closed",
     "The conversation is closed; reopen it before posting activities"},
    {"conflict", 409, "Conflict", "The request conflicts with the current state of the resource"},
    {"not_failed", 409, "Only failed deliveries can be retried",
     "Replay of a delivery, or redelivery of a platform webhook event, that is not failed"},
    {"payload_too_large", 413, "Payload too large", "A size limit was exceeded"},
    {"unsupported_media_type", 415, "Unsupported media type",
     "The uploaded file type is not allowed"},
    {"invalid_message", 422, "Invalid message",
     "The activity failed validation; details has the errors per field"},
    {"validation_failed", 422, "Validation failed",
     "The resource failed validation; details has the errors per field"},
    {"unsupported_channel_type", 422, "Unsupported channel type",
     "The channel type does not support the operation (outbox, templates)"},
    {"invalid_channel_config", 422, "Invalid channel configuration",
     "The channel configuration lacks what the operation needs"},
    {"upgrade_required", 426, "Upgrade required", "The endpoint only accepts WebSocket upgrades"},
    {"rate_limited", 429, "Too many requests. Please try again later.",
     "Rate limit hit; wait Retry-After seconds (details.retry_after_ms)"},
    {"internal", 500, "Internal server error", "Unexpected server error"},
    {"upstream_unavailable", 502, "Upstream service unavailable",
     "A provider or storage backend call failed"},
    {"unavailable", 503, "Service unavailable",
     "Retry later (Retry-After): the node is draining, the database is unavailable, or the activity could not be enqueued"}
  ]

  @by_code Map.new(@codes, fn {code, status, message, _} -> {code, {status, message}} end)

  # Status => code for errors raised as exceptions (ConvergerWeb.ErrorJSON).
  @by_status %{
    400 => "bad_request",
    401 => "unauthorized",
    403 => "forbidden",
    404 => "not_found",
    405 => "method_not_allowed",
    406 => "not_acceptable",
    409 => "conflict",
    413 => "payload_too_large",
    415 => "unsupported_media_type",
    422 => "validation_failed",
    426 => "upgrade_required",
    429 => "rate_limited",
    500 => "internal",
    502 => "upstream_unavailable",
    503 => "unavailable"
  }

  @doc "The code catalog: `[{code, default_status, default_message, description}]`."
  def codes, do: @codes

  @doc "Every code, sorted."
  def code_names, do: @codes |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  @doc """
  Builds an error. `code` must be in `codes/0`; `message` defaults to the
  code's message. Options: `:status` (overrides the code's default status).
  """
  @spec new(String.t() | atom(), String.t() | nil, map() | nil, keyword()) :: t()
  def new(code, message \\ nil, details \\ nil, opts \\ []) do
    code = to_string(code)

    {status, default_message} =
      Map.get(@by_code, code) || raise ArgumentError, "unknown API error code #{inspect(code)}"

    %__MODULE__{
      code: code,
      status: Keyword.get(opts, :status, status),
      message: message || default_message,
      details: details
    }
  end

  @doc "The code for an HTTP status (errors raised as exceptions)."
  @spec code_for_status(pos_integer()) :: String.t()
  def code_for_status(status) do
    case Map.fetch(@by_status, status) do
      {:ok, code} -> code
      :error when status >= 500 -> "internal"
      :error -> "bad_request"
    end
  end

  @doc "The default message of a code."
  def default_message(code), do: @by_code |> Map.fetch!(to_string(code)) |> elem(1)

  @doc "The envelope map for an error."
  @spec body(t(), String.t() | nil) :: map()
  def body(%__MODULE__{} = error, request_id) do
    %{
      error: %{
        code: error.code,
        message: error.message,
        details: error.details,
        request_id: request_id
      }
    }
  end

  @doc """
  The `x-request-id` of the request: the response header set by
  `Plug.RequestId`, else the Logger metadata of the request process.
  """
  @spec request_id(Plug.Conn.t() | nil) :: String.t() | nil
  def request_id(conn) do
    header =
      case conn do
        %Plug.Conn{} -> conn |> get_resp_header("x-request-id") |> List.first()
        _ -> nil
      end

    header || Logger.metadata()[:request_id]
  end

  @doc """
  Sends the envelope for `error` (or for `code`, `message`, `details`) and
  halts the connection.
  """
  @spec send_error(Plug.Conn.t(), t() | String.t() | atom(), String.t() | nil, map() | nil) ::
          Plug.Conn.t()
  def send_error(conn, error, message \\ nil, details \\ nil)

  def send_error(conn, %__MODULE__{} = error, _message, _details) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(error.status, Jason.encode_to_iodata!(body(error, request_id(conn))))
    |> halt()
  end

  def send_error(conn, code, message, details),
    do: send_error(conn, new(code, message, details), nil, nil)

  @doc """
  Changeset errors as `%{field => [message]}`, the `details` of
  `validation_failed` / `invalid_message`.
  """
  @spec changeset_details(Ecto.Changeset.t()) :: map()
  def changeset_details(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc "Retry-After in whole seconds (at least 1) for a delay in milliseconds."
  def retry_after_seconds(ms), do: max(div(ms + 999, 1000), 1)
end
