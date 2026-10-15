---
title: Elixir client (converger_client)
description: The Elixir client library - Req-based REST client, a Mint.WebSocket Protocol v1 client with resume, and webhook signature verification for Plug and Phoenix apps.
sidebar_position: 5
---

`converger_client` is the Elixir library for apps that integrate with or embed Converger: a REST client built on
`Req`, a [Protocol v1](../protocol/v1.md) client process built on `Mint.WebSocket`, and webhook signature
verification. Source: [`packages/client-elixir`](https://github.com/AimTune/converger/tree/main/packages/client-elixir).
What all SDKs share is described in [Server-side SDKs](server-sdks.md).

```elixir
def deps do
  [{:converger_client, "~> 0.1"}]
end
```

Elixir 1.15 or later. The server has no protocol frame structs to share (frames are maps validated against the
JSON Schemas in `priv/protocol/v1`), so the client works with decoded maps for frames and with its own structs for
REST responses.

## Client

```elixir
client = ConvergerClient.new("https://chat.example.com", api_key: "cvg_live_...", channel_secret: "...")
```

Options: `:api_key`, `:channel_secret`, `:req_options` (merged into every `Req` request, for example
`receive_timeout:` or `plug:` in tests). Calls return `{:ok, struct}` or `{:error, %ConvergerClient.Error{}}`
(normalized as described in [Server-side SDKs](server-sdks.md#errors)), or `{:error, exception}` for transport
failures.

| `ConvergerClient.ClientAPI` | Returns |
| --- | --- |
| `generate_token(client, user_id: ..., scope: ...)` | `%TokenResponse{}` |
| `refresh_token(client, token)` | `%TokenResponse{}` |
| `create_conversation(client, token)` | `%ConversationToken{conversation_id, token, stream_url}` |
| `get_conversation(client, token, id, watermark: ...)` | `%ConversationToken{}` |
| `close_conversation/3`, `reopen_conversation/3` | `%ConversationStatus{}` |
| `post_activity(client, token, id, %{text:, type:, from_id:, attachments:, reply_to_id:, channel_data:}, idempotency_key: ...)` | `%ResourceResponse{id}` |
| `list_activities(client, token, id, watermark: ..., limit: ...)` | `%ClientActivityPage{activities, watermark, has_more}` |

| `ConvergerClient.TenantAPI` | Returns |
| --- | --- |
| `list_conversations(client, limit:, cursor:, status:, channel_id:, external_id:)` | `%Page{data, next_cursor, has_more}` |
| `get_conversation/2`, `close_conversation/2`, `reopen_conversation/2` | `%Conversation{}` |
| `post_activity(client, id, %{sender:, text:, type:, attachments:, metadata:, reply_to_id:}, idempotency_key: ...)` | `%Activity{seq: ...}` |
| `list_activities(client, id, watermark: ..., limit: ...)` | `%ActivityPage{data, watermark, has_more}` |

`watermark` on both page structs is the integer seq from v3.0 servers or an opaque string from older ones
([migration](../protocol/v1.md#65-the-watermark-and-its-migration)); pass it back unchanged as `watermark:`.

Every struct keeps unknown response keys in `:extra`. Timestamps are ISO 8601 strings.

## WebSocket (Protocol v1)

```elixir
{:ok, sock} =
  ConvergerClient.Socket.start_link(
    client: client,
    token: conv.token,
    conversation_id: conv.conversation_id,
    watermark: stored_watermark
  )

{:ok, %ConvergerClient.Ack{seq: seq}} = ConvergerClient.Socket.send_text(sock, "Where is my order?")

receive do
  {:converger, ^sock, %{"type" => "text", "data" => %{"text" => text}}} -> text
  {:converger_closed, ^sock, %{code: code, reason: reason}} -> {:closed, code, reason}
end
```

The socket is a `GenServer`: frames for the application arrive in the owner's mailbox (the caller of
`start_link/1`, or `:owner`) as `{:converger, sock, frame}`, persistent frames in `seq` order and exactly once.
When it ends for good the owner gets `{:converger_closed, sock, %{code, reason}}` and the process stops normally.

| Option | Default |
| --- | --- |
| `:client` or `:url` | required |
| `:token` | required: a string, or a 0-arity function returning a token (or `{:ok, token}`), called on every connect |
| `:conversation_id`, `:watermark` | resume position |
| `:reconnect`, `:max_retries`, `:backoff` | `true`, unlimited, `{500, 30_000}` ms |

`send_text/3` and `send_message/4` return `{:ok, %Ack{}}`, `{:error, error_data}` when the server refuses the
send, or `{:error, {:closed, code, reason}}`. `typing/2`, `read/2`, `watermark/1` and `close/1` complete the API.
`ConvergerClient.Protocol.Session` is the transport-independent resume state machine.

## Webhook signature verification

```elixir
case ConvergerClient.Webhook.verify_signature(conn.req_headers, raw_body, secret) do
  :ok -> handle(Jason.decode!(raw_body))
  {:error, reason} -> send_resp(conn, 401, Atom.to_string(reason))
end
```

Read the raw body before JSON parsing (for example with a `Plug.Parsers` `:body_reader` that keeps it in
`conn.assigns`). `secret` may be a list while rotating; options `tolerance:` (seconds, default 300) and `now:`.
Errors: `:missing_signature`, `:no_secret`, `:malformed_signature`, `:timestamp_out_of_tolerance`,
`:invalid_signature`.

## Development

```bash
cd packages/client-elixir
mix deps.get
mix test                     # unit, transport and conformance tests
```

Releases: push a tag `client-elixir/vX.Y.Z` (matching `@version` in `mix.exs`). A license must be added to the
package metadata before the first Hex release.
