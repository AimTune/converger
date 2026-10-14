---
title: Microsoft Teams
description: Azure Bot setup, Bot Framework JWT validation, OAuth client credentials, service URL allowlist, activity mapping, cards, files and typing of the teams channel adapter.
sidebar_position: 2.6
---

The `teams` adapter connects a Microsoft Teams bot to Converger through the
[Bot Framework](https://learn.microsoft.com/azure/bot-service/)
([`lib/converger/channels/adapters/teams.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/teams.ex),
authentication in
[`lib/converger/channels/teams/auth.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/teams/auth.ex)).
It supports the modes `inbound`, `outbound` and `duplex`. The Bot Connector posts Bot Framework Activities to the
channel's inbound URL; replies are posted to the Bot Connector's `serviceUrl`. Design:
[ADR-0048](../adr/0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md).

## Setup

1. In the Azure portal, create an **Azure Bot** resource. Choose **Multi Tenant** or **Single Tenant** and note the
   **Microsoft App ID**; create a **client secret** for the app registration (Configuration > Manage Password).
2. Create the channel:

   ```json
   {
     "name": "Teams support bot",
     "type": "teams",
     "mode": "duplex",
     "config": {
       "app_id": "6d3c8a2e-1f4b-4c7a-9e2d-0b5a7c9e1f3d",
       "app_password": "client-secret-value",
       "app_tenant_id": ""
     }
   }
   ```

   Set `app_tenant_id` to your Microsoft Entra tenant id only for a single-tenant bot.
3. In the Azure Bot's **Configuration**, set the **Messaging endpoint** to
   `https://<PHX_HOST>/api/v1/channels/<channel id>/inbound`.
4. Under **Channels**, add **Microsoft Teams**. Install the bot in Teams with an app manifest whose `botId` is the
   App ID (Teams Developer Portal), then message it.

## Configuration

| Key | Required | Description |
| --- | --- | --- |
| `app_id` | yes | The Microsoft App ID (a GUID). Inbound tokens must be issued for it (`aud`). |
| `app_password` | yes (secret) | The app registration's client secret, for the outbound OAuth token. |
| `app_tenant_id` | no | Tenant id or domain of a single-tenant bot. Empty: the multi-tenant `botframework.com` token endpoint. |
| `download_media` | no | `false` keeps inbound files as references. Default `true`. |
| `conversation_idle_timeout_seconds`, `unsupported_activities` | no | As for every channel. |

Operator settings (all optional), for every Teams channel:

```elixir
config :converger, Converger.Channels.Adapters.Teams,
  # Bot Framework OpenID metadata, whose jwks_uri lists the signing keys.
  openid_metadata_url: "https://login.botframework.com/v1/.well-known/openidconfiguration",
  # Accepted token issuers.
  issuers: ["https://api.botframework.com"],
  # Token endpoint base (https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token).
  login_base_url: "https://login.microsoftonline.com",
  # Hosts replies may be posted to ("*." matches any subdomain).
  service_url_hosts: ["smba.trafficmanager.net", "*.trafficmanager.net", "*.botframework.com",
                      "*.botframework.us", "*.botframework.azure.us", "*.teams.microsoft.com",
                      "*.teams.microsoft.us"]
```

## Inbound

### JWT validation

The Bot Connector sends every Activity with `Authorization: Bearer <JWT>`. Converger accepts the request only when
all of these hold (otherwise `401`, whatever `require_signature` says):

1. the token is signed (RS256) by a key from the Bot Framework OpenID metadata's `jwks_uri`, matched by `kid`;
2. that key is endorsed for the Activity's `channelId` (`msteams`) when it lists `endorsements`;
3. `iss` is `https://api.botframework.com`, `aud` is the channel's `app_id`;
4. `exp` and `nbf` hold, with five minutes of clock skew;
5. the `serviceurl` claim equals the Activity's `serviceUrl`, so a valid token cannot carry a forged reply address.

The metadata and keys are cached per node for 24 hours (`Converger.Channels.TokenCache`). A token with an unknown
`kid` refetches them, at most once every five minutes, so Microsoft's key rotation is picked up without letting forged
tokens hammer the endpoint. Emulator tokens (other issuers) are not accepted.

### Activity mapping

| Activity | Converger activity | Notes |
| --- | --- | --- |
| `message` | `message` | The bot's `<at>...</at>` mention (channels, group chats) is removed from the text. |
| `message` with an Adaptive Card `value` and no text (`Action.Submit`) | `event`, `metadata.name` = `teams.card_action`, `metadata.value` | |
| `invoke` `adaptiveCard/action` (`Action.Execute`) | `event` `teams.card_action` with `text` = the verb | Answered with the Universal Action invoke response (`statusCode` 200). |
| `messageReaction` | one `messageReaction` per added (`text` = `like`, `heart`, ...) or removed (`text` "") reaction | |
| `messageUpdate` | `messageUpdate` of the original | |
| `messageDelete` | `messageDelete` of the original | |
| `conversationUpdate`, `installationUpdate`, `typing`, other invokes | none | Answered `200`. |

- **Participant and sender**: the Teams user id (`from.id`), with `from.name` as display name. The participant's
  metadata keeps `service_url`, `conversation_id`, `bot_id` and `tenant_id` of the user's latest message, updated on
  every message: replies go to the Teams conversation (personal chat, group chat or channel thread) the user last
  wrote in.
- **Message ids**: Teams activity ids are unique only within a conversation, so a message is named
  `"<first 16 hex of sha256(conversation id)>:<activity id>"`. It is the idempotency key of inbound messages and the
  provider message id of outbound ones; replies, reactions, edits and deletes find their target by it.
- **Metadata**: `teams_activity_id`, `teams_conversation_id`, `teams_conversation_type`, `teams_tenant_id`,
  `teams_team_id`, `teams_channel_id`, `aad_object_id`, `bot_framework_channel`, `locale`, `timestamp`.

### Files

A file shared in a personal chat (`application/vnd.microsoft.teams.file.download.info`) is downloaded from its
pre-authenticated `downloadUrl` (checked by the [SSRF guard](../webhooks.md#ssrf-protection)). An inline image is
downloaded from the Bot Connector with the bot's token, and only from an allowed service URL host, so the token is
never sent anywhere else. Both are stored as Converger uploads; a failed download keeps the reference. The `text/html`
copy of the message is dropped, and other attachments (cards) are kept as they are.

## Outbound

**Target.** The participant's stored conversation and service URL, or the activity metadata keys
`target_conversation_id` and `target_service_url` together (proactive messages to a known conversation).

**Service URL check.** Before every request the service URL must be `https`, on a host in `service_url_hosts`, and
accepted by the [SSRF guard](../webhooks.md#ssrf-protection) (not resolving to a private, loopback or link-local
address). Anything else fails the delivery permanently.

**Token.** Converger gets an OAuth access token with the client-credentials grant
(`scope=https://api.botframework.com/.default`) from `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`,
where the tenant is `botframework.com` or `app_tenant_id`, and caches it per node until five minutes before it
expires. A changed `app_password` gets a new token.

**What is sent:** one Bot Framework `message` to `POST <serviceUrl>/v3/conversations/<id>/activities` with `from` =
the bot (`28:<app_id>`), the text as markdown (the activity `text`, else the card texts), and attachments:

- media with an absolute `contentUrl` as `{contentType, contentUrl, name}` attachments (Teams fetches them; files
  stored in Converger cannot be sent and fail permanently; the Teams file consent flow is not implemented);
- `application/vnd.microsoft.card.*` attachments (Adaptive Cards, hero cards) as they are;
- the buttons of Converger card attachments as a hero card: `imBack` buttons (the user's click comes back as a
  message with the button value) and `openUrl` buttons.

The delivery's `provider_message_id` is the message key of the returned id. The Bot Framework reports no delivery or
read receipts to bots, so deliveries stay `sent`.

**Typing.** A typing signal from a WebSocket participant posts a `typing` activity to the participant's conversation.

### Errors

| Answer | Retried |
| --- | --- |
| token endpoint `400` / `401` / `403` (wrong app id, secret or tenant) | no |
| Bot Connector `401` | yes: the cached token is dropped and the next attempt gets a new one |
| Bot Connector `403`, `404` (bot not in the conversation, conversation gone) and other `4xx` | no |
| `429` (with `Retry-After`), `5xx`, transport errors | yes |

The default outbound rate limit is `50/s`; Teams also throttles to about 7 messages per second per conversation.

### Health probe

The probe requests an access token, which catches a wrong or expired client secret.

## Typed messages

The adapter declares `message_types: image file video audio` ([#68](https://github.com/AimTune/converger/issues/68),
[ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)): typed media arrive as
file attachments and are sent as described above. Every other typed message is sent as its text rendering
([messages.md section 5](../protocol/messages.md)): the prompt with its actions as a numbered list
(`1. Track an order`), links as `label: url`, cards as text blocks; native quick replies or buttons for typed
messages are a follow-up. A reply that is only a number (`2`) within 24 hours of the conversation's most recent
actionable message becomes the normalised answer, with `metadata.action` (`source: "numeric"`) and `reply_to_id`
([messages.md section 6](../protocol/messages.md)).

## Testing

[`teams_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/teams_test.exs)
signs tokens with a generated RSA key, serves it as the OpenID keys and stubs the token endpoint and the Bot
Connector through `config :converger, :teams_req_options`.
