defmodule ConvergerWeb.Plugs.Deprecated do
  @moduledoc """
  Marks responses of a deprecated endpoint, per the API versioning policy
  (docs/api/versioning.md, ADR-0050):

    * `Deprecation: @<unix time>` (RFC 9745) - since when it is deprecated;
    * `Sunset: <HTTP-date>` (RFC 8594) - when it stops working, if decided;
    * `Link: <url>; rel="deprecation"` (and `rel="sunset"`) - the migration
      guide.

  As a plug, in a controller or pipeline:

      plug ConvergerWeb.Plugs.Deprecated,
           [deprecated_at: ~U[2026-10-09 00:00:00Z],
            sunset_at: ~U[2027-10-09 00:00:00Z],
            link: "https://converger.aimtune.dev/api/migrating-from-legacy"]
           when action in [:create]

  or `put_headers/2` from code that decides per request
  (`ConvergerWeb.Deprecation.mark/3`). Mark the operation `deprecated: true`
  in its OpenAPI `operation` as well.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    if not match?(%DateTime{}, opts[:deprecated_at]) or
         not (is_nil(opts[:sunset_at]) or match?(%DateTime{}, opts[:sunset_at])) do
      raise ArgumentError, ":deprecated_at (and :sunset_at, if given) must be DateTimes"
    end

    opts
  end

  @impl true
  def call(conn, opts), do: put_headers(conn, opts)

  @doc """
  Adds the deprecation headers. Options: `:deprecated_at` (required,
  `DateTime`), `:sunset_at` (`DateTime`), `:link` (migration guide URL,
  sent as `rel="deprecation"` and, with `:sunset_at`, `rel="sunset"`).
  """
  @spec put_headers(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def put_headers(conn, opts) do
    deprecated_at = Keyword.fetch!(opts, :deprecated_at)
    sunset_at = Keyword.get(opts, :sunset_at)
    link = Keyword.get(opts, :link)

    conn
    |> put_resp_header("deprecation", "@#{DateTime.to_unix(deprecated_at)}")
    |> then(fn conn ->
      if sunset_at, do: put_resp_header(conn, "sunset", http_date(sunset_at)), else: conn
    end)
    |> then(fn conn ->
      if link, do: put_resp_header(conn, "link", link_header(link, sunset_at)), else: conn
    end)
  end

  @doc "An RFC 9110 HTTP-date (IMF-fixdate), e.g. `Sat, 09 Oct 2027 00:00:00 GMT`."
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp link_header(link, nil), do: ~s(<#{link}>; rel="deprecation")
  defp link_header(link, _sunset), do: ~s(<#{link}>; rel="deprecation", <#{link}>; rel="sunset")
end
