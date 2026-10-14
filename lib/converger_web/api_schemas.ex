defmodule ConvergerWeb.ApiSchemas do
  @moduledoc """
  Named component schemas and shared responses of the OpenAPI description
  (`ConvergerWeb.ApiSpec`, ADR-0050).

  Every schema here is published under `#/components/schemas/<name>`, so the
  SDKs generated from `priv/static/openapi.json` (#46, #47) get one named type
  per resource. Controllers reference them with `ref/1` and the shared error
  responses with `errors/1`.

  Schemas use OpenAPI 3.0 `nullable` internally (open_api_spex validates
  with it in tests); `ConvergerWeb.ApiSpec.to_json/0` rewrites them to
  OpenAPI 3.1 / JSON Schema 2020-12 `type: [..., "null"]` on export.
  """

  alias Converger.Activities.Activity
  alias Converger.Auth.ConvergerToken
  alias Converger.Deliveries.Delivery
  alias Converger.Tenants.Tenant
  alias Converger.Webhooks.{Catalog, Event}
  alias OpenApiSpex.{Header, MediaType, Reference, Response, Schema}

  @uuid %Schema{type: :string, format: :uuid}
  @datetime %Schema{type: :string, format: :"date-time"}
  @object %Schema{type: :object, additionalProperties: true}

  @doc "A reference to the component schema `name`."
  @spec ref(String.t()) :: Reference.t()
  def ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}

  @doc "A JSON response or request body entry: `{description, \"application/json\", schema}`."
  def json_schema(description, schema), do: {description, "application/json", schema}

  @doc "A UUID path parameter."
  def path_id(description),
    do: [in: :path, schema: @uuid, required: true, description: description]

  @doc "A query parameter."
  def query(schema, description), do: [in: :query, schema: schema, description: description]

  @doc "The `x-idempotency-key` header parameter."
  def idempotency_key do
    [
      in: :header,
      schema: %Schema{type: :string},
      description:
        "Makes the request idempotent per conversation: a repeat returns the original activity"
    ]
  end

  @doc "`limit` query parameter."
  def limit_param,
    do: query(%Schema{type: :integer, minimum: 1}, "Page size (clamped to the max)")

  @doc "A reference to the shared response `name` (`responses/0`)."
  def response_ref(name), do: %Reference{"$ref": "#/components/responses/#{name}"}

  @doc """
  The shared error responses for `statuses`, plus `500`, as an operation's
  `responses` entries.
  """
  def errors(statuses) do
    Map.new(Enum.uniq(statuses ++ [500]), fn status ->
      {status, response_ref(error_name(status))}
    end)
  end

  @doc "`responses` merged with the shared error responses for `statuses` (and `500`)."
  def with_errors(responses, statuses), do: Map.merge(errors(statuses), Map.new(responses))

  @error_responses %{
    400 => {"BadRequest", "Malformed request (`bad_request`, `invalid_watermark`, ...)"},
    401 => {"Unauthorized", "Missing or invalid credential (`unauthorized`, `token_expired`)"},
    403 => {"Forbidden", "Not allowed (`forbidden`, `insufficient_scope`, `channel_inactive`)"},
    404 => {"NotFound", "Unknown resource, or one of another tenant or channel (`not_found`)"},
    409 =>
      {"Conflict", "Conflicts with the resource state (`conversation_closed`, `not_failed`)"},
    412 =>
      {"PreconditionFailed",
       "The If-Match ETag is stale (`precondition_failed`); fetch the resource and retry"},
    413 => {"PayloadTooLarge", "A size limit was exceeded (`payload_too_large`)"},
    415 => {"UnsupportedMediaType", "File type not allowed (`unsupported_media_type`)"},
    422 =>
      {"UnprocessableEntity",
       "Validation failed (`invalid_message`, `validation_failed`, `unsupported_channel_type`, `invalid_channel_config`); `details` has the errors per field"},
    429 => {"TooManyRequests", "Rate limit hit (`rate_limited`); retry after `Retry-After`"},
    500 => {"InternalError", "Unexpected server error (`internal`)"},
    502 => {"BadGateway", "A provider or storage call failed (`upstream_unavailable`)"},
    503 =>
      {"ServiceUnavailable",
       "Retry later (`unavailable`): draining, database unavailable or delivery enqueue failure"}
  }

  defp error_name(status), do: @error_responses |> Map.fetch!(status) |> elem(0)

  @retry_after %Header{
    description: "Seconds to wait before retrying",
    schema: %Schema{type: :integer, minimum: 1}
  }

  @doc "The shared responses (`#/components/responses`)."
  def responses do
    Map.new(@error_responses, fn {status, {name, description}} ->
      headers = if status in [429, 503], do: %{"retry-after" => @retry_after}, else: nil

      {name,
       %Response{
         description: description,
         headers: headers,
         content: %{"application/json" => %MediaType{schema: ref("ErrorResponse")}}
       }}
    end)
  end

  @doc "The component schemas (`#/components/schemas`)."
  def schemas do
    common_schemas()
    |> Map.merge(tenant_schemas())
    |> Map.merge(webhook_schemas())
    |> Map.merge(management_schemas())
    |> Map.merge(client_schemas())
  end

  defp nullable(%Schema{} = schema), do: %{schema | nullable: true}
  defp nullable(%Reference{} = ref), do: %Schema{allOf: [ref], nullable: true}

  defp object(title, description, properties, required, opts \\ [])

  defp object(title, description, properties, :all, opts),
    do: object(title, description, properties, properties |> Map.keys() |> Enum.sort(), opts)

  defp object(title, description, properties, required, opts) do
    struct!(
      Schema,
      [
        title: title,
        description: description,
        type: :object,
        properties: properties,
        required: required
      ] ++ opts
    )
  end

  defp data(title, description, schema),
    do: object(title, description, %{data: schema}, [:data])

  ## Errors

  defp common_schemas do
    %{
      "ErrorCode" => %Schema{
        title: "ErrorCode",
        description:
          "Stable machine-readable error code. Codes shared with Converger Protocol v1 are spelled the same.",
        type: :string,
        enum: ConvergerWeb.APIError.code_names()
      },
      "Error" =>
        object(
          "Error",
          "An API error. Every key is always present.",
          %{
            code: ref("ErrorCode"),
            message: %Schema{
              type: :string,
              description: "Human-readable message; may change, never parse it"
            },
            details:
              nullable(%Schema{
                type: :object,
                additionalProperties: true,
                description:
                  "Code-specific data: errors per field for validation codes, `retry_after_ms`, `supported`, `reason`, ..."
              }),
            request_id:
              nullable(%Schema{
                type: :string,
                description: "The request's `x-request-id`, also on the server log lines"
              })
          },
          [:code, :message, :details, :request_id]
        ),
      "ErrorResponse" =>
        object(
          "ErrorResponse",
          "The error envelope of every API error response.",
          %{error: ref("Error")},
          [:error],
          example: %{
            error: %{
              code: "conversation_closed",
              message: "Conversation is closed",
              details: nil,
              request_id: "GBHDfGZ0bW5Sl2YAAAEB"
            }
          }
        )
    }
  end

  ## Tenant API

  defp tenant_schemas do
    %{
      "Participant" =>
        object(
          "Participant",
          "The external party of a conversation (for example a WhatsApp number).",
          %{
            id: @uuid,
            external_id: %Schema{type: :string},
            display_name: nullable(%Schema{type: :string}),
            opted_out_at: nullable(@datetime)
          },
          [:id, :external_id, :display_name, :opted_out_at]
        ),
      "ConversationChannel" =>
        object(
          "ConversationChannel",
          "A channel a conversation spans.",
          %{
            channel_id: @uuid,
            role: %Schema{type: :string, enum: ~w(origin target member)},
            participant_id: nullable(@uuid),
            inserted_at: @datetime
          },
          [:channel_id, :role, :participant_id, :inserted_at]
        ),
      "Conversation" =>
        object(
          "Conversation",
          "A conversation (tenant API).",
          %{
            id: @uuid,
            status: %Schema{type: :string, enum: ~w(active closed)},
            metadata: @object,
            channel_id: @uuid,
            origin_channel_id: nullable(@uuid),
            tenant_id: @uuid,
            participant_id: nullable(@uuid),
            participant: nullable(ref("Participant")),
            channels: %Schema{
              type: :array,
              items: ref("ConversationChannel"),
              description: "Only on `GET /api/v1/conversations/{id}`"
            },
            inserted_at: @datetime,
            updated_at: @datetime
          },
          [
            :id,
            :status,
            :metadata,
            :channel_id,
            :origin_channel_id,
            :tenant_id,
            :participant_id,
            :participant,
            :inserted_at,
            :updated_at
          ]
        ),
      "CursorPageMeta" =>
        object(
          "CursorPageMeta",
          "Keyset pagination: pass `next_cursor` back as `cursor`.",
          %{
            next_cursor: nullable(%Schema{type: :string}),
            has_more: %Schema{type: :boolean},
            limit: %Schema{type: :integer}
          },
          [:next_cursor, :has_more, :limit]
        ),
      "WatermarkPageMeta" =>
        object(
          "WatermarkPageMeta",
          "Watermark pagination: pass `watermark` back to continue.",
          %{
            watermark: nullable(%Schema{type: :string}),
            has_more: %Schema{type: :boolean},
            limit: %Schema{type: :integer}
          },
          [:watermark, :has_more, :limit]
        ),
      "ConversationResponse" =>
        data("ConversationResponse", "One conversation.", ref("Conversation")),
      "ConversationList" =>
        object(
          "ConversationList",
          "A page of conversations, newest first.",
          %{
            data: %Schema{type: :array, items: ref("Conversation")},
            meta: ref("CursorPageMeta")
          },
          [:data, :meta]
        ),
      "CreateConversationRequest" =>
        object(
          "CreateConversationRequest",
          "Body of the deprecated `POST /api/v1/conversations`.",
          %{metadata: @object},
          []
        ),
      "ActivityType" => %Schema{
        title: "ActivityType",
        description: "Activity type. `deliveryReceipt` is created by the server only.",
        type: :string,
        enum: Activity.types()
      },
      "ActivityAttachment" =>
        object(
          "ActivityAttachment",
          "An attachment of an activity. Keys other than these are dropped.",
          %{
            contentType: %Schema{type: :string},
            contentUrl: %Schema{type: :string},
            name: %Schema{type: :string},
            size: %Schema{type: :integer},
            thumbnailUrl: %Schema{type: :string},
            content: %Schema{description: "Inline content (cards and the like)"},
            channelData: @object
          },
          [:contentType]
        ),
      "Activity" =>
        object(
          "Activity",
          "The canonical activity (tenant API, outbound webhooks, legacy socket).",
          activity_properties(),
          :all
        ),
      "DryRunActivity" =>
        object(
          "DryRunActivity",
          "The activity a dry-run plans for: never stored, so `id`, `seq` and `conversation_id` (for a conversation that does not exist yet) may be null.",
          %{activity_properties() | id: nullable(@uuid), conversation_id: nullable(@uuid)},
          :all
        ),
      "ActivityResponse" => data("ActivityResponse", "One activity.", ref("Activity")),
      "ActivityList" =>
        object(
          "ActivityList",
          "A page of activities, oldest first.",
          %{
            data: %Schema{type: :array, items: ref("Activity")},
            meta: ref("WatermarkPageMeta")
          },
          [:data, :meta]
        ),
      "CreateActivityRequest" =>
        object(
          "CreateActivityRequest",
          "An activity posted with the tenant API key. Server fields in the body are ignored.",
          %{
            type: ref("ActivityType"),
            text: %Schema{type: :string, description: "At most 65,536 bytes"},
            attachments: %Schema{
              type: :array,
              items: ref("ActivityAttachment"),
              maxItems: 10
            },
            metadata: @object,
            reply_to_id: @uuid,
            sender: %Schema{type: :string, description: "Defaults to `user`"},
            message_type: %Schema{
              type: :string,
              description:
                "A Protocol v1 message type (`card`, `buttons`, `tool_call`, ...); needs `payload` and `type: message`"
            },
            payload: %Schema{
              type: :object,
              additionalProperties: true,
              description:
                "The typed message: the frame body without `type` and `seq`, validated against the Protocol v1 schemas"
            }
          },
          []
        ),
      "RoutingRuleInput" =>
        object(
          "RoutingRuleInput",
          "Writable fields of a routing rule.",
          %{
            name: %Schema{type: :string},
            source_channel_id: @uuid,
            target_channel_ids: %Schema{type: :array, items: @uuid},
            enabled: %Schema{type: :boolean},
            conditions: @object,
            transformations: %Schema{type: :array, items: @object},
            priority: %Schema{type: :integer},
            stop_processing: %Schema{type: :boolean}
          },
          []
        ),
      "RoutingRuleRequest" =>
        object(
          "RoutingRuleRequest",
          "Create or update a routing rule.",
          %{routing_rule: ref("RoutingRuleInput")},
          [:routing_rule]
        ),
      "RoutingRule" =>
        object(
          "RoutingRule",
          "A routing rule.",
          %{
            id: @uuid,
            name: %Schema{type: :string},
            source_channel_id: @uuid,
            target_channel_ids: %Schema{type: :array, items: @uuid},
            enabled: %Schema{type: :boolean},
            conditions: @object,
            transformations: %Schema{type: :array, items: @object},
            priority: %Schema{type: :integer},
            stop_processing: %Schema{type: :boolean},
            tenant_id: @uuid,
            inserted_at: @datetime,
            updated_at: @datetime
          },
          [
            :id,
            :name,
            :source_channel_id,
            :target_channel_ids,
            :enabled,
            :conditions,
            :transformations,
            :priority,
            :stop_processing,
            :tenant_id,
            :inserted_at,
            :updated_at
          ]
        ),
      "RoutingRuleResponse" =>
        data("RoutingRuleResponse", "One routing rule.", ref("RoutingRule")),
      "RoutingRuleList" =>
        data(
          "RoutingRuleList",
          "Every routing rule of the tenant, sorted by name.",
          %Schema{type: :array, items: ref("RoutingRule")}
        ),
      "DryRunRequest" =>
        object(
          "DryRunRequest",
          "What to dry-run.",
          %{
            activity:
              object(
                nil,
                "The activity: `type`, `text`, `sender`, `metadata`, `attachments`, `reply_to_id`",
                %{},
                [],
                additionalProperties: true
              ),
            source_channel_id: @uuid,
            conversation_id: @uuid,
            origin_channel_id: @uuid,
            conversation: @object,
            participant: @object,
            at: @datetime
          },
          []
        ),
      "DryRunRuleEvaluation" =>
        object(
          "DryRunRuleEvaluation",
          "A routing rule that was evaluated and its result.",
          %{
            id: @uuid,
            name: %Schema{type: :string},
            priority: %Schema{type: :integer},
            stop_processing: %Schema{type: :boolean},
            conditions: @object,
            target_channel_ids: %Schema{type: :array, items: @uuid},
            transformations: %Schema{type: :array, items: @object},
            result: %Schema{type: :string}
          },
          :all
        ),
      "DryRunTarget" =>
        object(
          "DryRunTarget",
          "A candidate channel and what it would get.",
          %{
            channel_id: @uuid,
            channel_name: %Schema{type: :string},
            channel_type: %Schema{type: :string},
            reason: %Schema{type: :string},
            rule_ids: %Schema{type: :array, items: @uuid},
            excluded:
              nullable(%Schema{
                type: :string,
                description:
                  "Why the channel gets nothing (`echo`, `inactive`, `inbound_only`, `not_deliverable`, `unsupported_activity`), `null` when it is a target"
              }),
            outcome: %Schema{type: :string, enum: ~w(deliver excluded halted skipped)},
            detail: nullable(%Schema{type: :string}),
            payload: nullable(ref("DryRunActivity"))
          },
          :all
        ),
      "DryRunResult" =>
        object(
          "DryRunResult",
          "The routing plan for the activity; nothing is stored or sent.",
          %{
            direction: %Schema{type: :string},
            origin_channel_id: nullable(@uuid),
            source_channel_id: nullable(@uuid),
            rule_source_channel_id: nullable(@uuid),
            at: @datetime,
            activity: ref("DryRunActivity"),
            rules: %Schema{type: :array, items: ref("DryRunRuleEvaluation")},
            matched_rule_ids: %Schema{type: :array, items: @uuid},
            targets: %Schema{type: :array, items: ref("DryRunTarget")}
          },
          :all
        ),
      "DryRunResponse" => data("DryRunResponse", "A routing dry-run.", ref("DryRunResult")),
      "DeliveryStatus" => %Schema{
        title: "DeliveryStatus",
        type: :string,
        enum: Delivery.statuses()
      },
      "Delivery" =>
        object(
          "Delivery",
          "One activity's delivery to one channel.",
          %{
            id: @uuid,
            activity_id: @uuid,
            channel_id: @uuid,
            status: ref("DeliveryStatus"),
            attempts: %Schema{type: :integer},
            last_error: nullable(%Schema{type: :string}),
            provider_message_id: nullable(%Schema{type: :string}),
            sent_at: nullable(@datetime),
            delivered_at: nullable(@datetime),
            read_at: nullable(@datetime),
            retry_count: %Schema{type: :integer},
            retried_by: nullable(%Schema{type: :string}),
            retried_at: nullable(@datetime),
            payload:
              nullable(%Schema{
                allOf: [ref("Activity")],
                description: "The canonical activity, sensitive keys redacted"
              }),
            inserted_at: @datetime,
            updated_at: @datetime
          },
          :all
        ),
      "DeliveryResponse" => data("DeliveryResponse", "One delivery.", ref("Delivery")),
      "DeliveryList" =>
        object(
          "DeliveryList",
          "A page of deliveries, most recently changed first.",
          %{
            data: %Schema{type: :array, items: ref("Delivery")},
            meta: ref("CursorPageMeta")
          },
          [:data, :meta]
        ),
      "BulkRetryResult" =>
        object(
          "BulkRetryResult",
          "Dead letters re-enqueued by a bulk retry.",
          %{
            retried: %Schema{type: :integer},
            has_more: %Schema{type: :boolean, description: "More dead letters remain; call again"}
          },
          [:retried, :has_more]
        ),
      "BulkRetryResponse" => data("BulkRetryResponse", "A bulk retry.", ref("BulkRetryResult")),
      "ChannelDeliveryState" =>
        object(
          "ChannelDeliveryState",
          "A channel's circuit breaker, pause and rate limit.",
          %{
            channel_id: @uuid,
            circuit_state: %Schema{type: :string, enum: ~w(closed open half_open paused)},
            circuit_changed_at: nullable(@datetime),
            consecutive_failures: %Schema{type: :integer},
            rate_limit:
              nullable(
                object(
                  nil,
                  "Effective outbound rate limit",
                  %{limit: %Schema{type: :integer}, scale_ms: %Schema{type: :integer}},
                  [:limit, :scale_ms]
                )
              ),
            parked_deliveries: %Schema{type: :integer}
          },
          [
            :channel_id,
            :circuit_state,
            :circuit_changed_at,
            :consecutive_failures,
            :rate_limit,
            :parked_deliveries
          ]
        ),
      "ChannelDeliveryStateResponse" =>
        data(
          "ChannelDeliveryStateResponse",
          "A channel's delivery state.",
          ref("ChannelDeliveryState")
        ),
      "OutboxItem" =>
        object(
          "OutboxItem",
          "A delivery waiting in an `http_pull` channel's outbox.",
          %{
            delivery_id: @uuid,
            activity: %Schema{
              type: :object,
              additionalProperties: true,
              description: "The payload as the channel would receive it (the canonical activity)"
            },
            queued_at: @datetime,
            served_before: %Schema{type: :boolean}
          },
          [:delivery_id, :activity, :queued_at, :served_before]
        ),
      "OutboxPage" =>
        object(
          "OutboxPage",
          "The next page of the outbox.",
          %{
            data: %Schema{type: :array, items: ref("OutboxItem")},
            watermark: nullable(%Schema{type: :string}),
            has_more: %Schema{type: :boolean},
            acknowledged: %Schema{type: :integer}
          },
          [:data, :watermark, :has_more, :acknowledged]
        ),
      "OutboxAckRequest" =>
        object(
          "OutboxAckRequest",
          "Acknowledge the outbox up to a watermark.",
          %{watermark: %Schema{type: :string}},
          [:watermark]
        ),
      "OutboxAckResponse" =>
        object(
          "OutboxAckResponse",
          "Deliveries acknowledged.",
          %{acknowledged: %Schema{type: :integer}},
          [:acknowledged]
        ),
      "MessageTemplate" =>
        object(
          "MessageTemplate",
          "A provider message template (WhatsApp HSM), with the provider's own fields.",
          %{
            id: %Schema{type: :string},
            name: %Schema{type: :string},
            language: %Schema{type: :string},
            status: %Schema{type: :string},
            category: %Schema{type: :string}
          },
          [],
          additionalProperties: true
        ),
      "MessageTemplateList" =>
        object(
          "MessageTemplateList",
          "A channel's message templates.",
          %{
            data: %Schema{type: :array, items: ref("MessageTemplate")},
            cached: %Schema{type: :boolean},
            fetched_at: @datetime
          },
          [:data, :cached, :fetched_at]
        ),
      "LegacyTokenRequest" =>
        object(
          "LegacyTokenRequest",
          "Body of the deprecated `POST /api/v1/tokens`.",
          %{conversation_id: @uuid, user_id: %Schema{type: :string}},
          [:conversation_id, :user_id]
        ),
      "LegacyTokenResponse" =>
        object(
          "LegacyTokenResponse",
          "A legacy conversation token.",
          %{token: %Schema{type: :string}, expires_in: %Schema{type: :integer}},
          [:token, :expires_in]
        ),
      "GenericInboundMessage" =>
        object(
          "GenericInboundMessage",
          "Generic webhook message (`webhook` channels). Provider channel types post their provider's own payload.",
          %{
            text: %Schema{type: :string, description: "Aliases: `message`, `body`"},
            sender: %Schema{type: :string, description: "Alias: `from`; default `external`"},
            type: ref("ActivityType"),
            attachments: %Schema{type: :array, items: ref("ActivityAttachment")},
            reply_to_id: @uuid,
            metadata: @object,
            idempotency_key: %Schema{type: :string},
            conversation_id: @uuid,
            external_id: %Schema{type: :string},
            display_name: %Schema{type: :string}
          },
          [],
          additionalProperties: true
        ),
      "GenericStatusUpdate" =>
        object(
          "GenericStatusUpdate",
          "Generic delivery receipt. Provider channel types post their provider's own payload.",
          %{
            status: %Schema{type: :string, enum: ~w(sent delivered read failed)},
            provider_message_id: %Schema{type: :string},
            delivery_id: @uuid,
            timestamp: %Schema{description: "ISO 8601 or Unix seconds"},
            error: %Schema{type: :string}
          },
          [:status],
          additionalProperties: true
        ),
      "InboundAccepted" =>
        object(
          "InboundAccepted",
          "Summary of a handled inbound request.",
          %{
            status: %Schema{type: :string, enum: ["accepted"]},
            activity_id: nullable(@uuid),
            activity_ids: %Schema{type: :array, items: @uuid},
            duplicates: %Schema{type: :integer},
            rejected: %Schema{type: :integer},
            receipts_processed: %Schema{type: :integer}
          },
          [:status, :receipts_processed]
        )
    }
  end

  defp activity_properties do
    %{
      id: @uuid,
      type: ref("ActivityType"),
      sender: %Schema{type: :string},
      text: nullable(%Schema{type: :string}),
      attachments: %Schema{type: :array, items: ref("ActivityAttachment")},
      metadata: @object,
      idempotency_key: nullable(%Schema{type: :string}),
      seq: nullable(%Schema{type: :integer, description: "Per-conversation sequence number"}),
      reply_to_id: nullable(@uuid),
      message_type:
        nullable(%Schema{
          type: :string,
          description:
            "Protocol v1 message type of a typed message (docs/protocol/messages.md), else null"
        }),
      payload:
        nullable(%Schema{
          type: :object,
          additionalProperties: true,
          description: "The typed message: the frame body without the server envelope, else null"
        }),
      source_channel_id:
        nullable(%Schema{
          type: :string,
          format: :uuid,
          description:
            "The channel the activity came in on; null for the tenant API and system events"
        }),
      edited_at: nullable(@datetime),
      deleted_at: nullable(@datetime),
      conversation_id: @uuid,
      tenant_id: @uuid,
      inserted_at: nullable(@datetime)
    }
  end

  ## Platform event webhooks (ADR-0053)

  ## Management and admin API (ADR-0061)

  defp channel_properties do
    %{
      id: @uuid,
      tenant_id: @uuid,
      name: %Schema{type: :string},
      type: %Schema{type: :string, description: "Channel type (adapter), e.g. `webhook`"},
      mode: %Schema{type: :string, enum: ~w(inbound outbound duplex)},
      status: %Schema{type: :string, enum: ~w(active inactive)},
      require_signature: %Schema{type: :boolean},
      config: %Schema{
        type: :object,
        additionalProperties: true,
        description:
          "Adapter configuration. Secret fields come back as `[REDACTED]`; sending `[REDACTED]` back keeps the stored value."
      },
      transformations: %Schema{type: :array, items: @object},
      retry_policy: @object,
      rate_limit: nullable(%Schema{type: :string, description: "e.g. `80/s`, `1000/m`"}),
      circuit_state: %Schema{type: :string, description: "Delivery circuit breaker state"},
      inserted_at: @datetime,
      updated_at: @datetime
    }
  end

  defp tenant_user_properties do
    %{
      id: @uuid,
      tenant_id: @uuid,
      email: %Schema{type: :string},
      name: %Schema{type: :string},
      role: %Schema{type: :string, enum: ~w(owner admin member viewer)},
      status: %Schema{type: :string, enum: ~w(active inactive)},
      totp_enabled: %Schema{type: :boolean, description: "Whether two-factor login is on"},
      inserted_at: @datetime,
      updated_at: @datetime
    }
  end

  defp tenant_properties do
    %{
      id: @uuid,
      name: %Schema{type: :string},
      status: %Schema{type: :string, enum: ~w(active inactive)},
      tier: %Schema{type: :string, enum: Tenant.tiers()},
      retention_days: %Schema{type: :integer},
      alert_webhook_url: nullable(%Schema{type: :string}),
      allowed_upload_types: nullable(%Schema{type: :array, items: %Schema{type: :string}}),
      limits: %Schema{
        type: :object,
        additionalProperties: true,
        description: "Rate-limit overrides: bucket => `{limit, scale_ms}`"
      },
      api_key_prefix:
        nullable(%Schema{type: :string, description: "Start of the primary API key, for display"}),
      inserted_at: @datetime,
      updated_at: @datetime
    }
  end

  defp api_key_properties do
    %{
      id: @uuid,
      tenant_id: @uuid,
      name: %Schema{type: :string},
      prefix: %Schema{type: :string, description: "Start of the key, for display"},
      scopes: %Schema{type: :array, items: ref("ApiKeyScope")},
      expires_at: nullable(@datetime),
      last_used_at: nullable(%{@datetime | description: "Updated at most once a minute"}),
      revoked_at: nullable(@datetime),
      created_by: nullable(%Schema{type: :string, description: "`<actor type>:<actor id>`"}),
      inserted_at: @datetime,
      updated_at: @datetime
    }
  end

  defp with_secret(properties, field, description),
    do: Map.put(properties, field, %Schema{type: :string, description: description})

  defp management_schemas do
    %{
      "Channel" =>
        object(
          "Channel",
          "A channel. The secret is only returned by create and rotate_secret.",
          channel_properties(),
          :all
        ),
      "ChannelWithSecret" =>
        object(
          "ChannelWithSecret",
          "A channel with its secret: only the create and rotate_secret responses carry it.",
          with_secret(
            channel_properties(),
            :secret,
            "The channel secret; store it, it is not returned again"
          ),
          :all
        ),
      "ChannelResponse" => data("ChannelResponse", "One channel.", ref("Channel")),
      "ChannelWithSecretResponse" =>
        data(
          "ChannelWithSecretResponse",
          "One channel with its secret.",
          ref("ChannelWithSecret")
        ),
      "ChannelList" =>
        data("ChannelList", "Every channel of the tenant, sorted by name.", %Schema{
          type: :array,
          items: ref("Channel")
        }),
      "ChannelInput" =>
        object(
          "ChannelInput",
          "Writable fields of a channel (`name` is required on create). `config` replaces the stored one.",
          %{
            name: %Schema{type: :string},
            type: %Schema{type: :string},
            mode: %Schema{type: :string, enum: ~w(inbound outbound duplex)},
            status: %Schema{type: :string, enum: ~w(active inactive)},
            require_signature: %Schema{type: :boolean},
            config: @object,
            transformations: %Schema{type: :array, items: @object},
            retry_policy: @object,
            rate_limit: nullable(%Schema{type: :string})
          },
          []
        ),
      "ChannelRequest" =>
        object(
          "ChannelRequest",
          "Create or update a channel.",
          %{channel: ref("ChannelInput")},
          [:channel]
        ),
      "TenantUser" =>
        object("TenantUser", "A tenant portal user.", tenant_user_properties(), :all),
      "TenantUserResponse" => data("TenantUserResponse", "One user.", ref("TenantUser")),
      "TenantUserList" =>
        data("TenantUserList", "The tenant's portal users, newest first.", %Schema{
          type: :array,
          items: ref("TenantUser")
        }),
      "TenantUserInput" =>
        object(
          "TenantUserInput",
          "Writable fields of a portal user. `email`, `name` and `password` are required on create; `password` is ignored on update.",
          %{
            email: %Schema{type: :string},
            name: %Schema{type: :string},
            password: %Schema{type: :string, writeOnly: true},
            role: %Schema{type: :string, enum: ~w(owner admin member viewer)},
            status: %Schema{type: :string, enum: ~w(active inactive)}
          },
          []
        ),
      "TenantUserRequest" =>
        object(
          "TenantUserRequest",
          "Create or update a portal user.",
          %{user: ref("TenantUserInput")},
          [:user]
        ),
      "Tenant" => object("Tenant", "A tenant and its settings.", tenant_properties(), :all),
      "TenantWithApiKey" =>
        object(
          "TenantWithApiKey",
          "A tenant with its primary API key: only the create and rotate_api_key responses carry it.",
          with_secret(
            tenant_properties(),
            :api_key,
            "The primary API key (every scope); store it, it is not returned again"
          ),
          :all
        ),
      "TenantResponse" => data("TenantResponse", "One tenant.", ref("Tenant")),
      "TenantWithApiKeyResponse" =>
        data(
          "TenantWithApiKeyResponse",
          "One tenant with its primary API key.",
          ref("TenantWithApiKey")
        ),
      "TenantList" =>
        data("TenantList", "Every tenant, sorted by name.", %Schema{
          type: :array,
          items: ref("Tenant")
        }),
      "TenantSettingsInput" =>
        object(
          "TenantSettingsInput",
          "Settings a tenant manages itself. `limits` replaces every override.",
          %{
            retention_days: %Schema{type: :integer},
            alert_webhook_url: nullable(%Schema{type: :string}),
            allowed_upload_types: nullable(%Schema{type: :array, items: %Schema{type: :string}}),
            limits: @object
          },
          []
        ),
      "TenantSettingsRequest" =>
        object(
          "TenantSettingsRequest",
          "Change the tenant's settings.",
          %{settings: ref("TenantSettingsInput")},
          [:settings]
        ),
      "TenantInput" =>
        object(
          "TenantInput",
          "Writable fields of a tenant (`name` is required on create). `limits` replaces every override.",
          %{
            name: %Schema{type: :string},
            status: %Schema{type: :string, enum: ~w(active inactive)},
            tier: %Schema{type: :string, enum: Tenant.tiers()},
            retention_days: %Schema{type: :integer},
            alert_webhook_url: nullable(%Schema{type: :string}),
            allowed_upload_types: nullable(%Schema{type: :array, items: %Schema{type: :string}}),
            limits: @object
          },
          []
        ),
      "TenantRequest" =>
        object(
          "TenantRequest",
          "Create or update a tenant.",
          %{tenant: ref("TenantInput")},
          [:tenant]
        ),
      "ApiKeyScope" => %Schema{
        title: "ApiKeyScope",
        description:
          "`read`: GET the tenant API; `write`: change conversation data; `manage`: configuration (`/api/v1/manage`, routing rules, webhook subscriptions, channel pause/resume).",
        type: :string,
        enum: Converger.ApiKeys.scopes()
      },
      "ApiKey" =>
        object(
          "ApiKey",
          "A scoped tenant API key. The key itself is only returned on create.",
          api_key_properties(),
          :all
        ),
      "ApiKeyWithKey" =>
        object(
          "ApiKeyWithKey",
          "A scoped API key with the key: only the create response carries it.",
          with_secret(
            api_key_properties(),
            :key,
            "The API key, sent in `x-api-key`; store it, it is not returned again"
          ),
          :all
        ),
      "ApiKeyResponse" => data("ApiKeyResponse", "One API key.", ref("ApiKey")),
      "ApiKeyWithKeyResponse" =>
        data("ApiKeyWithKeyResponse", "One API key with the key.", ref("ApiKeyWithKey")),
      "ApiKeyList" =>
        data(
          "ApiKeyList",
          "The tenant's scoped API keys, revoked ones included, newest first.",
          %Schema{type: :array, items: ref("ApiKey")}
        ),
      "CreateApiKeyRequest" =>
        object(
          "CreateApiKeyRequest",
          "Issue a scoped API key.",
          %{
            api_key:
              object(
                "ApiKeyInput",
                "The key's name, scopes and optional expiry.",
                %{
                  name: %Schema{type: :string},
                  scopes: %Schema{type: :array, items: ref("ApiKeyScope"), minItems: 1},
                  expires_at: @datetime
                },
                [:name, :scopes]
              )
          },
          [:api_key]
        )
    }
  end

  defp webhook_schemas do
    %{
      "WebhookEventType" => %Schema{
        title: "WebhookEventType",
        description: "A platform event type of the catalog.",
        type: :string,
        enum: Catalog.types()
      },
      "WebhookEventTypeList" =>
        data("WebhookEventTypeList", "The platform event catalog.", %Schema{
          type: :array,
          items: ref("WebhookEventType")
        }),
      "WebhookSubscription" =>
        object(
          "WebhookSubscription",
          "A platform event webhook subscription. Header values are never returned, only their names; the signing secret only by create and rotate_secret.",
          webhook_subscription_properties(),
          :all
        ),
      "WebhookSubscriptionWithSecret" =>
        object(
          "WebhookSubscriptionWithSecret",
          "A subscription with its signing secret: only the create and rotate_secret responses carry it.",
          Map.put(webhook_subscription_properties(), :secret, %Schema{
            type: :string,
            description: "The signing secret (`whsec_...`); store it, it is not returned again"
          }),
          :all
        ),
      "WebhookSubscriptionResponse" =>
        data("WebhookSubscriptionResponse", "One subscription.", ref("WebhookSubscription")),
      "WebhookSubscriptionWithSecretResponse" =>
        data(
          "WebhookSubscriptionWithSecretResponse",
          "One subscription with its signing secret.",
          ref("WebhookSubscriptionWithSecret")
        ),
      "WebhookSubscriptionList" =>
        data(
          "WebhookSubscriptionList",
          "Every platform webhook subscription of the tenant.",
          %Schema{type: :array, items: ref("WebhookSubscription")}
        ),
      "CreateWebhookSubscriptionRequest" =>
        object(
          "CreateWebhookSubscriptionRequest",
          "Create a subscription.",
          %{
            webhook_subscription:
              object(
                nil,
                "The subscription",
                Map.put(webhook_subscription_input(), :secret, %Schema{
                  type: :string,
                  minLength: 16,
                  maxLength: 255,
                  description: "Signing secret; generated (`whsec_...`) when omitted"
                }),
                [:url, :events]
              )
          },
          [:webhook_subscription]
        ),
      "UpdateWebhookSubscriptionRequest" =>
        object(
          "UpdateWebhookSubscriptionRequest",
          "Fields to change. A `secret` is ignored: use rotate_secret.",
          %{
            webhook_subscription:
              object(nil, "Fields to change", webhook_subscription_input(), [])
          },
          [:webhook_subscription]
        ),
      "WebhookEventStatus" => %Schema{
        title: "WebhookEventStatus",
        type: :string,
        enum: Event.statuses()
      },
      "WebhookEvent" =>
        object(
          "WebhookEvent",
          "One event sent (or to be sent) to one subscription.",
          %{
            id: @uuid,
            event_id: %Schema{
              type: :string,
              format: :uuid,
              description: "The event's id, the same for every subscription it went to"
            },
            subscription_id: @uuid,
            type: %Schema{type: :string, description: "The event type (`WebhookEventType`)"},
            status: ref("WebhookEventStatus"),
            attempts: %Schema{type: :integer},
            last_error: nullable(%Schema{type: :string}),
            response_status: nullable(%Schema{type: :integer}),
            payload: %Schema{
              type: :object,
              additionalProperties: true,
              description: "The event's `data`"
            },
            delivered_at: nullable(@datetime),
            redelivered_at: nullable(@datetime),
            inserted_at: @datetime,
            updated_at: @datetime
          },
          :all
        ),
      "WebhookEventResponse" => data("WebhookEventResponse", "One event.", ref("WebhookEvent")),
      "WebhookEventList" =>
        object(
          "WebhookEventList",
          "A page of the webhook event log, newest first.",
          %{
            data: %Schema{type: :array, items: ref("WebhookEvent")},
            meta: ref("CursorPageMeta")
          },
          [:data, :meta]
        )
    }
  end

  defp webhook_subscription_properties do
    %{
      id: @uuid,
      tenant_id: @uuid,
      url: %Schema{type: :string},
      description: nullable(%Schema{type: :string}),
      events: webhook_events_schema(),
      enabled: %Schema{type: :boolean},
      header_names: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Names of the extra request headers; their values are never returned"
      },
      managed_by:
        nullable(%Schema{
          type: :string,
          description:
            "Set when the platform maintains the subscription (`alert_webhook_url`), else `null`"
        }),
      inserted_at: @datetime,
      updated_at: @datetime
    }
  end

  defp webhook_subscription_input do
    %{
      url: %Schema{type: :string, description: "Public `https` URL"},
      description: %Schema{type: :string, maxLength: 255},
      events: webhook_events_schema(),
      enabled: %Schema{type: :boolean},
      headers: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string},
        description: "Extra request headers (encrypted at rest, never returned)"
      }
    }
  end

  defp webhook_events_schema do
    %Schema{
      type: :array,
      items: %Schema{type: :string},
      maxItems: 50,
      description: "Event types (`WebhookEventType`), or `[\"*\"]` for every type"
    }
  end

  ## Client API

  defp client_schemas do
    %{
      "ClientTokenRequest" =>
        object(
          "ClientTokenRequest",
          "Token generation options.",
          %{
            user: object(nil, "The end user", %{id: %Schema{type: :string}}, []),
            scope: %Schema{type: :string, enum: ConvergerToken.scopes()},
            permissions: %Schema{
              type: :array,
              minItems: 1,
              items: %Schema{type: :string, enum: ConvergerToken.permissions()},
              description:
                "Restricts the token (and every token derived or refreshed from it). Omitted: all permissions."
            }
          },
          []
        ),
      "ClientTokenRevokeRequest" =>
        object(
          "ClientTokenRevokeRequest",
          "What to revoke. With the channel secret: `token` (a token of the channel, with its family) or `user.id` (every token of that end user issued so far). With a token: nothing, the token revokes itself and its family.",
          %{
            token: %Schema{type: :string},
            user: object(nil, "The end user", %{id: %Schema{type: :string}}, [])
          },
          []
        ),
      "ClientTokenRevoked" =>
        object(
          "ClientTokenRevoked",
          "The revocation, effective on every node within a second.",
          %{revoked: %Schema{type: :string, enum: ~w(token user)}},
          [:revoked]
        ),
      "ClientToken" =>
        object(
          "ClientToken",
          "A Converger token.",
          %{
            conversationId: nullable(@uuid),
            token: %Schema{type: :string},
            expires_in: %Schema{type: :integer, description: "Seconds"},
            permissions:
              nullable(%Schema{
                type: :array,
                items: %Schema{type: :string, enum: ConvergerToken.permissions()}
              })
          },
          [:conversationId, :token, :expires_in]
        ),
      "ClientConversation" =>
        object(
          "ClientConversation",
          "A conversation and a token bound to it.",
          %{
            conversationId: @uuid,
            token: %Schema{type: :string},
            expires_in: %Schema{type: :integer},
            streamUrl: %Schema{type: :string, description: "WebSocket URL to receive activities"}
          },
          [:conversationId, :token, :expires_in, :streamUrl]
        ),
      "ClientConversationStatus" =>
        object(
          "ClientConversationStatus",
          "A conversation's status after close or reopen.",
          %{conversationId: @uuid, status: %Schema{type: :string, enum: ~w(active closed)}},
          [:conversationId, :status]
        ),
      "ClientActivity" =>
        object(
          "ClientActivity",
          "An activity as the client API renders it.",
          %{
            id: @uuid,
            type: ref("ActivityType"),
            from: object(nil, "The sender", %{id: %Schema{type: :string}}, [:id]),
            text: nullable(%Schema{type: :string}),
            timestamp: nullable(@datetime),
            attachments: %Schema{type: :array, items: ref("ActivityAttachment")},
            conversationId: @uuid,
            channelData: @object,
            replyToId: nullable(@uuid),
            messageType:
              nullable(%Schema{
                type: :string,
                description:
                  "Protocol v1 message type of a typed message (docs/protocol/messages.md), else null"
              }),
            payload:
              nullable(%Schema{
                type: :object,
                additionalProperties: true,
                description:
                  "The typed message: the frame body without the server envelope, else null"
              }),
            editedAt: nullable(@datetime),
            deletedAt: nullable(@datetime)
          },
          [
            :id,
            :type,
            :from,
            :text,
            :timestamp,
            :attachments,
            :conversationId,
            :channelData,
            :replyToId,
            :messageType,
            :payload,
            :editedAt,
            :deletedAt
          ]
        ),
      "ClientActivityRequest" =>
        object(
          "ClientActivityRequest",
          "An activity posted by a client.",
          %{
            type: ref("ActivityType"),
            text: %Schema{type: :string},
            attachments: %Schema{type: :array, items: ref("ActivityAttachment"), maxItems: 10},
            channelData: @object,
            metadata: %Schema{
              type: :object,
              additionalProperties: true,
              description: "Alias of `channelData`"
            },
            replyToId: @uuid,
            messageType: %Schema{
              type: :string,
              description:
                "A Protocol v1 message type (`card`, `buttons`, `tool_call`, ...); needs `payload`"
            },
            payload: %Schema{
              type: :object,
              additionalProperties: true,
              description:
                "The typed message: the frame body without `type` and `seq`, validated against the Protocol v1 schemas"
            },
            from: object(nil, "The sender; defaults to `user`", %{id: %Schema{type: :string}}, [])
          },
          []
        ),
      "ResourceResponse" =>
        object("ResourceResponse", "The id of the created activity.", %{id: @uuid}, [:id]),
      "ActivitySet" =>
        object(
          "ActivitySet",
          "A page of activities and the watermark to resume after them.",
          %{
            activities: %Schema{type: :array, items: ref("ClientActivity")},
            watermark: nullable(%Schema{type: :string}),
            has_more: %Schema{type: :boolean}
          },
          [:activities, :watermark, :has_more]
        ),
      "UploadRequest" =>
        object(
          "UploadRequest",
          "A file and, optionally, the activity that carries it.",
          %{
            file: %Schema{type: :string, format: :binary},
            activity: %Schema{
              type: :string,
              description: "JSON: `type`, `text`, `from`, `channelData`, `replyToId`"
            }
          },
          [:file]
        ),
      "UploadedAttachment" =>
        object(
          "UploadedAttachment",
          "A stored attachment.",
          %{
            id: @uuid,
            contentType: %Schema{type: :string},
            contentUrl: %Schema{type: :string},
            size: %Schema{type: :integer}
          },
          [:id, :contentType, :contentUrl, :size]
        ),
      "UploadResponse" =>
        object(
          "UploadResponse",
          "The activity created for the upload and its attachment.",
          %{id: @uuid, attachments: %Schema{type: :array, items: ref("UploadedAttachment")}},
          [:id, :attachments]
        )
    }
  end
end
