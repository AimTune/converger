defmodule ConvergerWeb.DeliveryExportController do
  @moduledoc """
  CSV export of the Deliveries pages (`/admin/deliveries/export`,
  `/portal/deliveries/export`), with the same filters as the page.

  The portal export is always scoped to the logged-in user's tenant. Rows are
  read in keyset pages and streamed as a chunked response, capped at
  `config :converger, :dead_letters, export_limit:` (default 10 000).
  Payloads are not exported, only delivery metadata and the last error.
  """
  use ConvergerWeb, :controller

  alias Converger.Deliveries

  @columns ~w(id tenant_id channel_id channel_name activity_id status attempts last_error
              retry_count retried_by retried_at inserted_at updated_at)

  @page_size 500

  def admin(conn, params) do
    tenant_id =
      case Ecto.UUID.cast(params["tenant_id"] || "") do
        {:ok, id} -> id
        :error -> nil
      end

    export(conn, params, tenant_id)
  end

  def portal(conn, params) do
    export(conn, params, conn.assigns.current_tenant.id)
  end

  defp export(conn, params, tenant_id) do
    case Deliveries.cast_filters(params) do
      {:ok, filters} ->
        filters = if tenant_id, do: Map.put(filters, :tenant_id, tenant_id), else: filters
        stream_csv(conn, filters)

      {:error, message} ->
        conn |> put_status(:bad_request) |> text(message)
    end
  end

  defp stream_csv(conn, filters) do
    filename = "deliveries-#{Date.utc_today()}.csv"

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, csv_line(@columns))
    send_pages(conn, filters, nil, export_limit())
  end

  defp send_pages(conn, _filters, _cursor, remaining) when remaining <= 0, do: conn

  defp send_pages(conn, filters, cursor, remaining) do
    {:ok, page} =
      Deliveries.search_deliveries(filters,
        limit: min(@page_size, remaining),
        cursor: cursor,
        preload: [:channel]
      )

    case chunk(conn, Enum.map_join(page.entries, &csv_line(row(&1)))) do
      {:ok, conn} ->
        if page.has_more,
          do: send_pages(conn, filters, page.next_cursor, remaining - length(page.entries)),
          else: conn

      {:error, _closed} ->
        conn
    end
  end

  defp row(delivery) do
    [
      delivery.id,
      delivery.channel && delivery.channel.tenant_id,
      delivery.channel_id,
      delivery.channel && delivery.channel.name,
      delivery.activity_id,
      delivery.status,
      delivery.attempts,
      delivery.last_error,
      delivery.retry_count,
      delivery.retried_by,
      delivery.retried_at,
      delivery.inserted_at,
      delivery.updated_at
    ]
  end

  defp export_limit do
    :converger
    |> Application.get_env(:dead_letters, [])
    |> Keyword.get(:export_limit, 10_000)
  end

  @doc false
  def csv_line(fields), do: Enum.map_join(fields, ",", &csv_field/1) <> "\r\n"

  defp csv_field(nil), do: ""
  defp csv_field(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp csv_field(value) when not is_binary(value), do: csv_field(to_string(value))

  # Quote every text field; a leading =, +, - or @ is prefixed with ' so a
  # spreadsheet does not evaluate provider error text as a formula.
  defp csv_field(value) do
    value = if String.match?(value, ~r/\A[=+\-@\t\r]/), do: "'" <> value, else: value
    ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")
  end
end
