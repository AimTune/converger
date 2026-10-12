# React widget example

A minimal chat widget on [`@converger/client`](../../../packages/client-ts). It resumes the conversation stored in
`localStorage`, which replays only what was missed. Messages typed while offline wait in the persistent outbox and are
sent once the connection is back, also after a reload. It shows typing and read receipts.

```sh
pnpm install                                   # at the repository root
pnpm --filter @converger/client build
CONVERGER_URL=http://localhost:4000 CHANNEL_SECRET=<channel secret> pnpm --filter @converger/example-react-widget dev
```

The Vite dev server proxies `/api` and `/socket` to Converger and plays the role of your backend: `POST /demo/token`
mints a token with the channel secret, so the secret never reaches the browser. In production your own backend serves
the tokens.

For a production widget, use [chativa](https://github.com/AimTune/chativa) with `@chativa/connector-converger`. This
example shows the headless client API.
