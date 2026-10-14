# @converger/agent e2e test

`agent.e2e.test.ts` runs the SDK against a real Converger server: an end user on a
`websocket` widget channel sends turns over the native endpoint, a routing rule
targets a `websocket` bot channel, and an agent built with `createAgent` answers
(text, tool call, GenUI stream, and an `ask` answered by a tapped button).

It is skipped unless these variables are set:

| variable | value |
| --- | --- |
| `CONVERGER_URL` | the server, e.g. `http://localhost:4000` |
| `CONVERGER_CHANNEL_SECRET` | secret of the bot channel the agent serves |
| `CONVERGER_USER_CHANNEL_SECRET` | secret of the widget channel the test user writes on |

Create the channels and the routing rule with the setup script, then run the test:

```sh
mix ecto.migrate
mix run packages/agent-ts/test/e2e/setup.exs   # prints the two secrets
mix phx.server &

export CONVERGER_URL=http://localhost:4000
export CONVERGER_CHANNEL_SECRET=...
export CONVERGER_USER_CHANNEL_SECRET=...
pnpm --filter @converger/agent test:e2e
```
