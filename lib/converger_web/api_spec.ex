defmodule ConvergerWeb.ApiSpec do
  @moduledoc """
  The OpenAPI description of the HTTP API (issue #45, ADR-0050).

  Operations come from the controllers (`use OpenApiSpex.ControllerSpecs`),
  collected from the router; component schemas and the shared error
  responses from `ConvergerWeb.ApiSchemas`.

    * `spec/0` - the `%OpenApiSpex.OpenApi{}` struct, used by
      `OpenApiSpex.TestAssertions` in the controller tests;
    * `to_json/0` - the published OpenAPI 3.1 document: `mix openapi.spec.json`
      writes it to `priv/static/openapi.json` (committed; CI fails on drift)
      and `GET /api/openapi.json` serves it.

  open_api_spex models OpenAPI 3.0, so `to_map/0` rewrites the exported
  document to 3.1: `nullable: true` becomes a `"null"` member of `type`
  (or an `anyOf` with `{"type": "null"}` for a referenced schema).
  """

  @behaviour OpenApiSpex.OpenApi

  alias ConvergerWeb.ApiSchemas
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server, Tag}

  @description """
  Converger's HTTP API. Four families share the `/api/v1` prefix:

  * **Tenant API** (`/api/v1/...`): server to server, authenticated with a tenant API key (`x-api-key`) whose
    scopes (`read`, `write`, `manage`) gate each operation; `/api/v1/manage/...` holds the tenant's configuration.
  * **Admin API** (`/api/v1/admin/...`): platform operators, authenticated with `ADMIN_API_TOKEN`.
  * **Client API** (`/api/v1/converger/...`): end-user clients, authenticated with a Converger token
    (`Authorization: Bearer`), issued from a channel secret.
  * **Inbound webhooks** (`/api/v1/channels/{channel_id}/inbound|status`): called by providers, verified by signature.

  Every error response uses one envelope:
  `{"error": {"code", "message", "details", "request_id"}}` (schema `ErrorResponse`). See
  [errors](https://converger.aimtune.dev/api/errors) and the
  [versioning policy](https://converger.aimtune.dev/api/versioning).
  """

  @tags [
    {"Tokens (legacy)", "Deprecated legacy conversation tokens"},
    {"Conversations", "Tenant API: conversations"},
    {"Activities", "Tenant API: activities"},
    {"Routing rules", "Tenant API: routing rules and dry-run"},
    {"Deliveries", "Tenant API: dead-letter inspection and replay"},
    {"Channels", "Tenant API: delivery state, templates, pull outbox"},
    {"Webhooks", "Tenant API: platform event webhook subscriptions, event log and redelivery"},
    {"Management",
     "Management API (`/api/v1/manage`): channels, portal users, API keys and settings; `manage` scope"},
    {"Admin",
     "Platform admin API (`/api/v1/admin`): tenants and API key issuance; `ADMIN_API_TOKEN`"},
    {"Inbound", "Provider webhooks"},
    {"Client: Tokens", "Client API: Converger tokens"},
    {"Client: Conversations", "Client API: conversations"},
    {"Client: Activities", "Client API: activities"},
    {"Client: Uploads", "Client API: file uploads"},
    {"Client: Attachments", "Client API: attachment downloads"},
    {"Client: Events", "Client API: Server-Sent Events stream"}
  ]

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Converger API",
        version: to_string(Application.spec(:converger, :vsn) || "0.0.0"),
        description: @description
      },
      servers: [%Server{url: "/", description: "This Converger instance"}],
      tags:
        Enum.map(@tags, fn {name, description} -> %Tag{name: name, description: description} end),
      paths:
        ConvergerWeb.Router
        |> Paths.from_router()
        |> distinct_put_operation_ids()
        |> scope_errors(),
      components: %Components{
        schemas: ApiSchemas.schemas(),
        responses: ApiSchemas.responses(),
        securitySchemes: security_schemes()
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  # `resources` routes `update` as both PATCH and PUT; open_api_spex would
  # suffix the second operation id with " (2)". The PUT gets `<id>Put`.
  defp distinct_put_operation_ids(paths) do
    Map.new(paths, fn
      {path,
       %{put: %OpenApiSpex.Operation{} = put, patch: %OpenApiSpex.Operation{} = patch} = item} ->
        base = String.replace(patch.operationId, ~r/ \(\d+\)$/, "")

        {path,
         %{item | patch: %{patch | operationId: base}, put: %{put | operationId: base <> "Put"}}}

      other ->
        other
    end)
  end

  # Every operation behind a tenant API key can answer 403
  # `insufficient_scope` (ADR-0061).
  defp scope_errors(paths) do
    Map.new(paths, fn {path, item} ->
      {path,
       Map.new(Map.from_struct(item), fn
         {method, %OpenApiSpex.Operation{} = op} ->
           if api_key_operation?(op),
             do: {method, %{op | responses: Map.put_new(op.responses, 403, forbidden())}},
             else: {method, op}

         other ->
           other
       end)
       |> then(&struct!(OpenApiSpex.PathItem, &1))}
    end)
  end

  defp api_key_operation?(%OpenApiSpex.Operation{security: security}) when is_list(security),
    do: Enum.any?(security, &Map.has_key?(&1, "apiKey"))

  defp api_key_operation?(_op), do: false

  defp forbidden, do: ApiSchemas.response_ref("Forbidden")

  defp security_schemes do
    %{
      "apiKey" => %SecurityScheme{
        type: "apiKey",
        in: "header",
        name: "x-api-key",
        description: "Tenant API key (server side only)"
      },
      "adminToken" => %SecurityScheme{
        type: "http",
        scheme: "bearer",
        description: "`ADMIN_API_TOKEN` (platform admin API only), behind the admin IP allowlist"
      },
      "channelToken" => %SecurityScheme{
        type: "apiKey",
        in: "header",
        name: "x-channel-token",
        description: "Deprecated channel token (#23); use the tenant API key or a Converger token"
      },
      "channelSecret" => %SecurityScheme{
        type: "http",
        scheme: "bearer",
        description:
          "Channel secret (server side only); only for `POST /api/v1/converger/tokens/generate`"
      },
      "publishableKey" => %SecurityScheme{
        type: "http",
        scheme: "bearer",
        description:
          "Publishable key (`cvg_pk_...`, safe in page source); only for `POST /api/v1/converger/tokens/publishable` from an allowed origin"
      },
      "convergerToken" => %SecurityScheme{
        type: "http",
        scheme: "bearer",
        bearerFormat: "JWT",
        description:
          "Converger token from `/api/v1/converger/tokens/generate` or `/conversations`"
      },
      "convergerTokenQuery" => %SecurityScheme{
        type: "apiKey",
        in: "query",
        name: "token",
        description:
          "Converger token as a query parameter (Server-Sent Events: EventSource cannot set headers)"
      },
      "inboundSignature" => %SecurityScheme{
        type: "apiKey",
        in: "header",
        name: "x-converger-signature",
        description:
          "Generic inbound signature `t=<unix>,v1=<hex HMAC-SHA256>`; provider channel types use their provider's scheme"
      }
    }
  end

  @doc "The published document (OpenAPI 3.1), as a map with string keys."
  @spec to_map() :: map()
  def to_map do
    spec()
    |> OpenApi.to_map(vendor_extensions: false)
    |> openapi_31()
    |> Map.put("openapi", "3.1.0")
  end

  @doc "The published document as pretty JSON with sorted keys (stable diffs)."
  @spec to_json() :: String.t()
  def to_json do
    to_map() |> ordered() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")
  end

  # OpenAPI 3.0 `nullable` to OpenAPI 3.1 (JSON Schema 2020-12).
  defp openapi_31(%{"nullable" => true} = schema) do
    schema = schema |> Map.delete("nullable") |> openapi_31()

    case schema do
      %{"type" => type} when is_binary(type) ->
        schema
        |> Map.put("type", [type, "null"])
        |> then(fn s ->
          if is_list(s["enum"]), do: Map.update!(s, "enum", &(&1 ++ [nil])), else: s
        end)

      %{"allOf" => [single]} ->
        schema |> Map.delete("allOf") |> Map.put("anyOf", [single, %{"type" => "null"}])

      _ ->
        %{"anyOf" => [schema, %{"type" => "null"}]}
    end
  end

  defp openapi_31(%{} = map) do
    map |> Map.delete("nullable") |> Map.new(fn {k, v} -> {k, openapi_31(v)} end)
  end

  defp openapi_31(list) when is_list(list), do: Enum.map(list, &openapi_31/1)
  defp openapi_31(value), do: value

  defp ordered(%{} = map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
