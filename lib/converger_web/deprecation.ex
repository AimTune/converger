defmodule ConvergerWeb.Deprecation do
  @moduledoc """
  Warnings for the pre-Protocol v1 surfaces deprecated by #23.

  Every use of a deprecated surface logs a warning (per connection for the
  legacy socket, per request for HTTP) and emits the telemetry event
  `[:converger, :deprecated, :use]` with `%{count: 1}` and the metadata
  `%{surface: surface}` plus the caller's metadata, so operators can find the
  integrations still on them before they are removed.

  HTTP responses also carry the RFC 9745 `Deprecation` header and a
  `Link: <migration guide>; rel="deprecation"` header.

  Surfaces:

    * `:legacy_socket` - `/socket` (`ConvergerWeb.UserSocket`, topic
      `conversation:<id>`).
    * `:token_endpoint` - `POST /api/v1/tokens` (legacy conversation tokens).
    * `:channel_token` - any other `x-channel-token` authentication
      (`POST /api/v1/conversations`, the tenant API).
    * `:opaque_watermark` - a pre-v1 base64url watermark (`seq:<n>` or a
      legacy activity id) sent to a surface that emits the integer seq
      (Converger REST, the tenant API, Protocol v1 frames, SSE). Logged
      only, no response headers: the endpoint itself is not deprecated
      (#63, docs/protocol/v1.md section 6.5).
  """

  require Logger

  @migration_guide "https://converger.aimtune.dev/api/migrating-from-legacy"

  # When these surfaces were deprecated (RFC 9745 `Deprecation: @<unix time>`).
  # No `Sunset` yet: the removal date is not decided (docs/api/versioning.md).
  @deprecated_at ~U[2026-10-09 00:00:00Z]

  @replacements %{
    legacy_socket:
      "connect to /socket/converger with a Converger token and join converger:conversation:<id>",
    token_endpoint:
      "issue Converger tokens with POST /api/v1/converger/tokens/generate (channel secret)",
    channel_token:
      "use the tenant API key (x-api-key) server side, or the Converger API with a Converger token",
    opaque_watermark:
      "send the integer seq the server now returns as the watermark (docs/protocol/v1.md section 6.5)"
  }

  @type surface :: :legacy_socket | :token_endpoint | :channel_token | :opaque_watermark

  @doc "URL of the migration guide."
  def migration_guide, do: @migration_guide

  @doc "Log and count one use of a deprecated surface."
  @spec warn(surface(), keyword()) :: :ok
  def warn(surface, metadata \\ []) when is_map_key(@replacements, surface) do
    Logger.warning(
      "Deprecated #{surface} used; #{Map.fetch!(@replacements, surface)}. " <>
        "It will be removed. See #{@migration_guide}",
      Keyword.put(metadata, :deprecated, surface)
    )

    :telemetry.execute(
      [:converger, :deprecated, :use],
      %{count: 1},
      metadata |> Map.new() |> Map.put(:surface, surface)
    )
  end

  @doc "`warn/2` for an HTTP request, adding the deprecation response headers."
  @spec mark(Plug.Conn.t(), surface(), keyword()) :: Plug.Conn.t()
  def mark(conn, surface, metadata \\ []) do
    warn(surface, metadata)

    ConvergerWeb.Plugs.Deprecated.put_headers(conn,
      deprecated_at: @deprecated_at,
      link: @migration_guide
    )
  end
end
