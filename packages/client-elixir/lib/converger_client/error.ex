defmodule ConvergerClient.Error do
  @moduledoc """
  A non-2xx HTTP response, normalized whatever error shape the server used:
  the standard envelope `{"error": {"code", "message", "details",
  "request_id"}}` (#45) or one of the legacy shapes
  (`packages/conformance/errors.json`).
  """

  defexception [:status, :code, :message, :details, :request_id, :retry_after, :body]

  @type t :: %__MODULE__{
          status: integer(),
          code: String.t(),
          message: String.t(),
          details: term(),
          request_id: String.t() | nil,
          retry_after: non_neg_integer() | nil,
          body: term()
        }

  @status_codes %{
    400 => "bad_request",
    401 => "unauthorized",
    403 => "forbidden",
    404 => "not_found",
    406 => "not_acceptable",
    409 => "conflict",
    413 => "payload_too_large",
    415 => "unsupported_media_type",
    422 => "validation_failed",
    429 => "rate_limited",
    500 => "internal",
    502 => "bad_gateway",
    503 => "unavailable"
  }

  @impl true
  def message(%__MODULE__{status: status, code: code, message: ""}), do: "#{status} #{code}"

  def message(%__MODULE__{status: status, code: code, message: msg}),
    do: "#{status} #{code}: #{msg}"

  @doc "Builds the error from a status, headers (`[{name, value}]` or a map) and the raw body."
  @spec from_response(integer(), Enumerable.t(), binary()) :: t()
  def from_response(status, headers, raw) do
    headers = normalize_headers(headers)

    {body, json?} = decode(raw)

    base = %__MODULE__{status: status, message: "", body: if(json?, do: body, else: raw)}

    err =
      case body do
        %{"error" => %{} = e} ->
          %{
            base
            | code: string_or_nil(e["code"]),
              message: string_or_nil(e["message"]) || "",
              details: e["details"],
              request_id: string_or_nil(e["request_id"])
          }

        %{"error" => e, "detail" => d} when is_binary(e) and is_binary(d) ->
          %{base | code: e, message: d}

        %{"error" => e} when is_binary(e) ->
          %{base | message: e}

        %{"errors" => %{"detail" => d}} when is_binary(d) ->
          %{base | message: d}

        %{"errors" => %{} = errors} ->
          %{base | message: "validation failed", details: errors}

        _ when not json? ->
          %{base | message: raw |> String.trim() |> String.slice(0, 200)}

        _ ->
          base
      end

    %{
      err
      | code: err.code || Map.get(@status_codes, status, "http_#{status}"),
        request_id: err.request_id || headers["x-request-id"],
        retry_after: retry_after(headers["retry-after"])
    }
  end

  defp decode(raw) do
    cond do
      String.trim(raw) == "" -> {nil, true}
      match?({:ok, _}, Jason.decode(raw)) -> {Jason.decode!(raw), true}
      true -> {nil, false}
    end
  end

  defp string_or_nil(v) when is_binary(v), do: v
  defp string_or_nil(_), do: nil

  defp retry_after(nil), do: nil

  defp retry_after(value) do
    v = String.trim(value)
    if v =~ ~r/^[0-9]+$/, do: String.to_integer(v), else: nil
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn
      {k, [v | _]} -> {String.downcase(to_string(k)), v}
      {k, v} -> {String.downcase(to_string(k)), v}
    end)
  end
end
