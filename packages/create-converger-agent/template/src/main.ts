import { channelTokenProvider, createAgent } from "@converger/agent";
import { handleTurn } from "./handler.ts";

const url = process.env["CONVERGER_URL"] ?? "__CONVERGER_URL__";
const secret = process.env["CONVERGER_CHANNEL_SECRET"];
if (!secret) {
  console.error("Set CONVERGER_CHANNEL_SECRET in .env (the secret of the websocket channel this agent serves).");
  process.exit(1);
}

const agent = createAgent({
  url,
  // Channel-scoped tokens from the channel secret, renewed before they expire.
  getToken: channelTokenProvider({ url, secret }),
  group: process.env["CONVERGER_AGENT_GROUP"] ?? "__AGENT_GROUP__",
  logger: console,
});

agent.onTurn(handleTurn);
agent.on("error", (error) => console.error(`[agent] ${error.code}: ${error.message}`));

await agent.start();
console.log(`serving channel ${agent.channelId}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    void agent.stop().then(() => process.exit(0));
  });
}
