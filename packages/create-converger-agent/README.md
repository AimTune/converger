# create-converger-agent

Scaffold a TypeScript agent for [Converger](https://converger.aimtune.dev) built on
[`@converger/agent`](../agent-ts):

```sh
npx create-converger-agent my-agent
cd my-agent && npm install
cp .env.example .env   # set CONVERGER_CHANNEL_SECRET
npm test               # against the SDK's fake server
npm start
```

The project has a sample `onTurn` handler (`src/handler.ts`: a text reply with a chip, and an `ask` with
actions), the entry point (`src/main.ts`), `.env.example` and a vitest test that runs the handler against
`FakeConvergerServer` from `@converger/agent/testing`, so it needs neither a server nor a secret.

The CLI is non-interactive; every option is a flag:

| flag | default |
| --- | --- |
| `--name <name>` | the directory name |
| `--url <url>` | `http://localhost:4000` (written to `.env.example`) |
| `--group <group>` | the package name (`hello.group`: processes of a group share the channel's conversations) |
| `--sdk-version <spec>` | `^0.1.0` (any npm spec: a range, `file:../agent.tgz`, `workspace:*`) |
| `-f`, `--force` | refuse a non-empty directory |

It is also importable: `import { scaffold } from "create-converger-agent"`.

Docs: [Agent SDK](https://converger.aimtune.dev/sdk/agent).
