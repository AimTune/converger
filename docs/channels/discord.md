---
title: Discord
description: Configuration, Interactions Endpoint setup, Ed25519 signature verification, interaction mapping and responses, Gateway mode for plain messages, outbound messages, buttons, files and threads of the discord channel adapter.
sidebar_position: 2.55
---

The `discord` adapter connects a Discord application (bot) to Converger
([`lib/converger/channels/adapters/discord.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/discord.ex)).
It supports the modes `inbound`, `outbound` and `duplex`. Inbound traffic is the application's
**Interactions Endpoint** (slash commands, buttons, select menus, modals) and, in [Gateway mode](#gateway-mode), plain
channel and direct messages over the Discord Gateway WebSocket; outbound messages are posted with the bot token to
`POST /channels/{channel.id}/messages`.

## Setup

1. In the [Discord developer portal](https://discord.com/developers/applications), create an application and a bot.
   Copy the **Application ID** and **Public Key** (General Information) and the **bot token** (Bot).
2. Invite the bot to your server with the `bot` and `applications.commands` scopes and the **Send Messages**,
   **Send Messages in Threads**, **Create Public Threads** and **Attach Files** permissions.
3. Create the channel:

   ```json
   {
     "name": "Discord support",
     "type": "discord",
     "mode": "duplex",
     "config": {
       "application_id": "1234567890123456789",
       "public_key": "5f0e...64 hex characters...",
       "bot_token": "MTIz..."
     }
   }
   ```

4. Click **Register webhook** next to the channel in the admin channel list. It sets the application's
   **Interactions Endpoint URL** to `https://<PHX_HOST>/api/v1/channels/<id>/inbound`
   (`PATCH /applications/@me`). Discord validates the URL by sending a signed `PING` and a request with an invalid
   signature; Converger answers the first with `PONG` and the second with `401`. You can also paste the URL into the
   portal yourself.
5. Register slash commands for the application (for example `/support question:<text>`) with Discord's command API.

## Configuration

| Key | Required | Description |
| --- | --- | --- |
| `application_id` | yes | Numeric application id. |
| `public_key` | yes, unless `gateway` is true | The application's Ed25519 public key, 64 hex characters. Verifies every interaction. A channel without one rejects every interaction. |
| `bot_token` | yes (secret) | Sent as `Authorization: Bot <token>`. |
| `command_ack_text` | no | Ephemeral reply to slash commands and modal submits. Default `Got it, a reply is on its way.` |
| `gateway` | no | `true` receives plain messages over the Gateway ([Gateway mode](#gateway-mode)), in modes `inbound` and `duplex`. Default `false`. |
| `gateway_intents` | no | Gateway intents bitfield. Default `37376`: `GUILD_MESSAGES` (512), `DIRECT_MESSAGES` (4096) and `MESSAGE_CONTENT` (32768). |
| `conversation_idle_timeout_seconds`, `unsupported_activities` | no | As for every channel. |

The operator can point all Discord channels at another API base (`config :converger,
Converger.Channels.Adapters.Discord, api_base_url: "..."`, default `https://discord.com/api/v10`).

## Inbound

### Signature

Every request carries `X-Signature-Ed25519` (hex) and `X-Signature-Timestamp`. Converger verifies the Ed25519
signature of the timestamp followed by the raw body with the channel's `public_key` (`:crypto`, no extra
dependency), and rejects a timestamp outside the inbound signature tolerance (300 seconds by default). A missing,
malformed, stale or wrong signature is a `401`, whatever `require_signature` says: Discord signs everything.

### Interactions

Discord requires an interaction response within three seconds. Converger stores the activity and answers in the
same request:

| Interaction | Activity | Response |
| --- | --- | --- |
| `PING` (1) | none | `{"type": 1}` (`PONG`), before anything is stored |
| `APPLICATION_COMMAND` (2) | `message` with `text` = `/<name> <option values>` | ephemeral message (`type` 4, flag 64) with `command_ack_text` |
| `MESSAGE_COMPONENT` (3), a button or select | `event` with `text` = the `custom_id`, `metadata.name` = `discord.component` | deferred update (`type` 6): no visible change |
| `MODAL_SUBMIT` (5) | `message` with the submitted values, one per line | ephemeral message with `command_ack_text` |
| `APPLICATION_COMMAND_AUTOCOMPLETE` (4) | none | no choices (`type` 8) |

- **Participant and sender**: the Discord user id. The channel (or thread) of the interaction is stored in the
  participant's metadata (`discord_channel_id`) and updated on every interaction, so replies go to where the user last
  interacted.
- **Idempotency**: `interaction:<id>`.
- **Metadata**: `discord_interaction_id`, `discord_channel_id`, `discord_guild_id`, `discord_user_id`, `username`,
  `locale`, `discord_thread_id` (when the interaction came from a thread), `discord_command` (`name`, flattened
  `options`), `discord_component` (`custom_id`, `component_type`, `values`) or `discord_modal`.
- A component press names the message that carried it: its id resolves `reply_to_id` when that message was sent by
  Converger.

The interaction token (valid for 15 minutes) is not stored: replies are bot messages, not interaction follow-ups.

## Gateway mode

With `gateway: true`, the channel also receives **plain messages**: what users type in the channels the bot can read
and in direct messages to the bot, without a slash command. Discord delivers them only over the
[Gateway](https://discord.com/developers/docs/events/gateway), a WebSocket the bot keeps open.

Setup: in the developer portal, enable the **Message Content Intent** (Bot page; a privileged intent, which Discord
reviews for bots in 100 servers or more), give the bot the **View Channels** and **Read Message History** permissions
where it should listen, and set `gateway: true` on the channel. The Interactions Endpoint keeps working alongside;
`public_key` may be left out if you use only the Gateway.

**One connection per channel in the cluster.** The Gateway connection (`Converger.Channels.Discord.Gateway`) is run by
the same machinery as broker consumers ([consumers in a cluster](brokers.md#consumers-in-a-cluster)): one per channel,
on the node that owns it, restarted when the channel's config changes, stopped when it is disabled, deleted or
`gateway` is turned off. `BROKER_CONSUMERS=false` keeps Gateway connections off a node too. Do not enable the Gateway
on two channels with the same bot token, or run the same bot elsewhere: each session receives every message.

**Connection handling:**

| Situation | What Converger does |
| --- | --- |
| `HELLO` | Sends the first heartbeat after `heartbeat_interval` times a random jitter (0 to 1), then every `heartbeat_interval`; sends `IDENTIFY` (token, intents) or, for a known session, `RESUME` (`session_id`, last sequence number) |
| `READY` | Keeps `session_id`, `resume_gateway_url` and the bot's user id |
| Heartbeat requested (op 1) | Heartbeats at once |
| No `HEARTBEAT_ACK` since the last heartbeat | Zombie connection: closes it and resumes |
| Reconnect (op 7), socket closed, close codes other than below | Reconnects to `resume_gateway_url` and resumes: Discord replays the events missed in between |
| Invalid session (op 9) | Resumes when `d` is true; otherwise identifies again after 1 to 5 seconds |
| Close 4007, 4009 | Identifies again (session invalid or timed out) |
| Close 4004 (authentication failed), 4010 to 4014 (shard, API version, invalid or disallowed intents) | Logs an error and tries again only after 5 minutes: fix the token or enable the intent |

Failed connection attempts back off exponentially (1 s doubling, at most 60 s). The Gateway URL comes from
`GET /gateway/bot`; the operator can override it (`config :converger, Converger.Channels.Adapters.Discord,
gateway_url: "..."`, used by the tests).

**Messages.** Each `MESSAGE_CREATE` event becomes a `message` activity, unless it comes from the bot itself or another
bot, from a webhook, is a system message (only types `DEFAULT` and `REPLY` are taken), or has neither text nor
attachments (a guild message without the Message Content Intent):

- **Participant and sender**: the author's user id; display name the server nickname, else the global name, else the
  user name. The Discord channel is stored in the participant's metadata (`discord_channel_id`), so replies go back to
  where the user wrote, as for interactions.
- **Idempotency**: `message:<message id>`: an event replayed by a resume is a duplicate.
- **Metadata**: `discord_message_id`, `discord_channel_id`, `discord_guild_id` (none for direct messages),
  `discord_user_id`, `username`, `discord_source: "gateway"`.
- **Replies**: a reply to a message Converger sent resolves `reply_to_id` from `message_reference`.
- **Attachments**: downloaded from the Discord CDN (its URLs expire) and stored in Converger like other inbound media
  (the SSRF guard and the upload size limit apply); `download_media: false` keeps the stubs.

Events are stored one at a time, in order, beside the connection (so a slow database never delays heartbeats). A
transient failure is retried in place (`inbound_max_attempts`, see [broker channels](brokers.md#poison-messages-and-retries));
the Gateway has no acknowledgements and no dead-letter destination, so a message that still cannot be stored is
dropped and logged (`Inbound message dropped`, `converger.broker.dead_lettered.count`). Messages sent while no
connection is open are recovered only by a resume within Discord's window. One shard is used: bots in 2500 servers or
more need sharding, which is not supported. See [ADR-0055](../adr/0055-mqtt-channel-and-discord-gateway.md).

## Outbound

**Target.** The activity metadata key `target_channel_id` (a channel or thread id), else the channel the
conversation's participant last interacted in. The inbound metadata keys `discord_channel_id` and
`discord_thread_id` are deliberately not used, so an interaction routed to another Discord channel is never posted
by the wrong bot.

**What is sent:**

1. the text (the activity `text`, else the card texts; links of URL attachments appended), split into messages of at
   most 2000 characters;
2. files stored in Converger are uploaded with the first message (`multipart/form-data`, `files[n]`, at most 10);
3. the buttons of card attachments become button components on the last message, in action rows of five (at most
   25): primary buttons whose `custom_id` is the button `id` or `value` (pressing one comes back as a
   `discord.component` event), and link buttons for `openUrl`.

**Threads.** A reply to an interaction that came from a thread goes to that thread. With `metadata.thread_name`, a
public thread (auto-archived after 24 hours) is started from the first message and the remaining messages are
posted into it; its id is in the delivery metadata (`discord_thread_id`).

The delivery's `provider_message_id` is the id of the last message (all of them in `discord_message_ids`). Discord
has no delivery or read receipts for bots, so deliveries stay `sent`. Native activity types: `message`.

### Errors

| Status | Example | Retried |
| --- | --- | --- |
| `429` | rate limited | yes, after the body's `retry_after` (or `Retry-After`) |
| `400`, `401`, `403`, `404` | invalid form body, invalid token, `Missing Permissions` (50013), unknown channel | no |
| `5xx`, transport errors | | yes |

The default outbound rate limit is `50/s` (Discord's global limit per bot).

### Health probe

`GET /users/@me` with the bot token (5 seconds, no retry).

## Testing

[`discord_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/discord_test.exs)
signs interactions with a generated Ed25519 key and stubs the API through `config :converger, :discord_req_options`.
[`gateway_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/discord/gateway_test.exs)
runs the Gateway connection against a fake Gateway (a local WebSocket server): identify, heartbeats, resume after a
reconnect request, zombie detection, invalid sessions, close codes and `MESSAGE_CREATE` handling.
