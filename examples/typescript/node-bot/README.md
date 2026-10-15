# Node bot example

A Node participant built on [`@converger/client`](../../../packages/client-ts). It answers every text message from
someone else, and keeps working across server restarts: it reconnects, replays what it missed, and resends unacknowledged
replies once.

```sh
pnpm install                                   # at the repository root
pnpm --filter @converger/client build
CONVERGER_URL=http://localhost:4000 CHANNEL_SECRET=<channel secret> pnpm --filter @converger/example-node-bot start
# resume a conversation instead of starting one:
CHANNEL_SECRET=... pnpm --filter @converger/example-node-bot start -- <conversationId>
```

The bot holds the channel secret, so it must run server side. Bots that serve every conversation of a channel should use
the channel-scoped `@converger/agent` SDK ([#67](https://github.com/AimTune/converger/issues/67)).
