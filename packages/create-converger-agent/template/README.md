# __PACKAGE_NAME__

A [Converger](https://converger.aimtune.dev) agent built with `@converger/agent`. One process serves every
conversation of a Converger `websocket` channel: users of the channels routed to it (web widget, WhatsApp,
Telegram, ...) all reach `src/handler.ts`.

```sh
npm install
cp .env.example .env   # set CONVERGER_CHANNEL_SECRET
npm test               # against the SDK's fake server; no Converger needed
npm start              # Node 22.9+
```

- Agent SDK guide: https://converger.aimtune.dev/sdk/agent
- Route conversations to the agent with a routing rule from the end-user channel to the agent's `websocket`
  channel: https://converger.aimtune.dev/channels/websocket
