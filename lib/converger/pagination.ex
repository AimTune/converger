defmodule Converger.Pagination do
  @moduledoc """
  Bounded list queries.

  Every user-facing list in Converger is bounded. Two strategies are used:

    * **Keyset (cursor) pagination** for tables that grow without limit
      (conversations, audit logs, deliveries, tenant users). Rows are ordered
      by `(inserted_at, id)` (or another timestamp column) and the next page
      starts strictly after the last row seen, so a page costs the same at
      row 10 and at row 10 million and rows inserted meanwhile never shift
      pages (which they do with `OFFSET`). The cursor is opaque to clients.

    * **Sequence pagination** for activities, on the per-conversation `seq`
      (see `Converger.Activities` and `Converger.ConvergerAPI.Watermark`).

  Small configuration tables (tenants, channels, routing rules, admin users)
  are listed with `bounded_all/2`, a hard safety cap rather than pages: they
  are only created by operators, are needed whole for dropdowns, and are
  orders of magnitude smaller than the cap.

  Limits are configured under `config :converger, :pagination` (see
  `config/config.exs`); request-supplied limits are clamped to the maximum.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Converger.Pagination.Page
  alias Converger.Repo

  @defaults [
    default_limit: 50,
    max_limit: 500,
    activity_default_limit: 100,
    activity_max_limit: 1000,
    ws_replay_limit: 100,
    lookup_limit: 1000
  ]

  @doc "A pagination setting from `config :converger, :pagination`."
  def config(key) when is_atom(key) do
    :converger
    |> Application.get_env(:pagination, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc """
  Clamp a requested page size.

  `kind` is `:default` or `:activity`. `nil`, non-numeric or non-positive
  values fall back to the configured default; values above the maximum are
  capped at the maximum. Accepts integers and strings (query params).
  """
  def clamp_limit(requested, kind \\ :default)

  def clamp_limit(requested, kind) when is_binary(requested) do
    case Integer.parse(String.trim(requested)) do
      {n, ""} -> clamp_limit(n, kind)
      _ -> clamp_limit(nil, kind)
    end
  end

  def clamp_limit(requested, kind) when is_integer(requested) and requested > 0 do
    min(requested, max_limit(kind))
  end

  def clamp_limit(_requested, kind), do: default_limit(kind)

  def default_limit(:activity), do: config(:activity_default_limit)
  def default_limit(_), do: config(:default_limit)

  def max_limit(:activity), do: config(:activity_max_limit)
  def max_limit(_), do: config(:max_limit)

  @doc """
  Run `query` with a hard cap of `lookup_limit` rows (or `opts[:limit]`).

  For small, operator-managed tables only. Logs a warning when the cap is
  reached, since that means a dropdown or table is silently incomplete.
  """
  def bounded_all(query, opts \\ []) do
    cap = Keyword.get(opts, :limit, config(:lookup_limit))
    rows = query |> limit(^(cap + 1)) |> Repo.all()

    if length(rows) > cap do
      Logger.warning("Bounded list query hit its cap; result truncated",
        cap: cap,
        source: inspect(source_of(query))
      )

      Enum.take(rows, cap)
    else
      rows
    end
  end

  defp source_of(%Ecto.Query{from: %{source: {_table, schema}}}), do: schema
  defp source_of(other), do: other

  @doc """
  Keyset-paginate `query` on `(field, id)`.

  `query` must not already have an `order_by` or `limit`.

  Options:

    * `:limit` - page size (clamped, see `clamp_limit/2`)
    * `:cursor` - opaque cursor from a previous page's `next_cursor`;
      `nil` or `""` starts from the beginning. An invalid cursor returns
      `{:error, :invalid_cursor}`.
    * `:direction` - `:desc` (newest first, default) or `:asc`
    * `:field` - timestamp column to order by (default `:inserted_at`)
    * `:preload` - preloads applied to the page entries

  Returns `{:ok, %Converger.Pagination.Page{}}`.
  """
  def keyset(query, opts \\ []) do
    limit = clamp_limit(Keyword.get(opts, :limit))
    direction = Keyword.get(opts, :direction, :desc)
    field = Keyword.get(opts, :field, :inserted_at)

    with {:ok, position} <- decode_cursor(Keyword.get(opts, :cursor)) do
      rows =
        query
        |> after_position(position, field, direction)
        |> order_by([r], [{^direction, field(r, ^field)}, {^direction, r.id}])
        |> limit(^(limit + 1))
        |> Repo.all()

      {entries, has_more} = split(rows, limit)
      entries = maybe_preload(entries, Keyword.get(opts, :preload))

      next_cursor =
        case {has_more, List.last(entries)} do
          {true, %{} = last} -> encode_cursor(Map.fetch!(last, field), last.id)
          _ -> nil
        end

      {:ok, %Page{entries: entries, next_cursor: next_cursor, has_more: has_more, limit: limit}}
    end
  end

  @doc "Like `keyset/2` but raises on an invalid cursor."
  def keyset!(query, opts \\ []) do
    case keyset(query, opts) do
      {:ok, page} -> page
      {:error, :invalid_cursor} -> raise ArgumentError, "invalid pagination cursor"
    end
  end

  @doc """
  Split rows fetched with `limit + 1` into `{page, has_more}`.
  """
  def split(rows, limit) do
    if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}
  end

  defp after_position(query, nil, _field, _direction), do: query

  defp after_position(query, {ts, id}, field, :desc) do
    where(
      query,
      [r],
      field(r, ^field) < ^ts or (field(r, ^field) == ^ts and r.id < ^id)
    )
  end

  defp after_position(query, {ts, id}, field, :asc) do
    where(
      query,
      [r],
      field(r, ^field) > ^ts or (field(r, ^field) == ^ts and r.id > ^id)
    )
  end

  defp maybe_preload(entries, nil), do: entries
  defp maybe_preload(entries, preloads), do: Repo.preload(entries, preloads)

  @doc "Encode a keyset position as an opaque cursor."
  def encode_cursor(%DateTime{} = ts, id) when is_binary(id) do
    Base.url_encode64("ts:" <> DateTime.to_iso8601(ts) <> "|" <> id, padding: false)
  end

  @doc """
  Decode a cursor. Returns `{:ok, nil}` for no cursor, `{:ok, {datetime, id}}`
  or `{:error, :invalid_cursor}`.
  """
  def decode_cursor(nil), do: {:ok, nil}
  def decode_cursor(""), do: {:ok, nil}

  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, "ts:" <> rest} <- Base.url_decode64(cursor, padding: false),
         [iso, raw_id] <- String.split(rest, "|", parts: 2),
         {:ok, ts, _offset} <- DateTime.from_iso8601(iso),
         {:ok, id} <- Ecto.UUID.cast(raw_id) do
      {:ok, {ts, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_), do: {:error, :invalid_cursor}
end
