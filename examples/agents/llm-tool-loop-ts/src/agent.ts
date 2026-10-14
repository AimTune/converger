/**
 * Entry point: serve every conversation of a Converger channel with a Claude
 * tool loop. See README.md.
 *
 *   CONVERGER_URL=... CONVERGER_CHANNEL_SECRET=... ANTHROPIC_API_KEY=... npm start
 */
import Anthropic from "@anthropic-ai/sdk";
import { channelTokenProvider, createAgent } from "@converger/agent";
import { anthropicStream, runToolLoop } from "./loop.ts";

const url = process.env["CONVERGER_URL"] ?? "http://localhost:4000";
const secret = process.env["CONVERGER_CHANNEL_SECRET"];
if (!secret) {
  console.error("Set CONVERGER_CHANNEL_SECRET (the secret of the websocket channel this agent serves).");
  process.exit(1);
}

const client = new Anthropic(); // ANTHROPIC_API_KEY, or `ant auth login`
const createStream = anthropicStream(client);

// The conversation so far, per Converger conversation (in memory; bounded).
const conversations = new Map<string, Anthropic.Beta.BetaMessageParam[]>();
const MAX_CONVERSATIONS = 1000;

const agent = createAgent({
  url,
  getToken: channelTokenProvider({ url, secret, userId: "llm-tool-loop" }),
  group: process.env["CONVERGER_AGENT_GROUP"] ?? "llm-tool-loop",
  logger: console,
});

agent.onTurn(async (turn, reply) => {
  if (!turn.text) return;
  let messages = conversations.get(turn.conversationId);
  if (!messages) {
    messages = [];
    if (conversations.size >= MAX_CONVERSATIONS) conversations.delete(conversations.keys().next().value as string);
    conversations.set(turn.conversationId, messages);
  }
  messages.push({ role: "user", content: turn.text });
  try {
    await runToolLoop({ messages, reply, createStream, signal: turn.signal });
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) await reply.text("I'm busy right now, please try again in a minute.");
    else if (error instanceof Anthropic.APIError) await reply.text("Something went wrong on my side.");
    // Drop the broken turn so the next one starts from a valid history.
    conversations.delete(turn.conversationId);
    throw error;
  }
});

agent.on("error", (error) => console.error(`[agent] ${error.code}: ${error.message}`));
await agent.start();
console.log(`serving channel ${agent.channelId}`);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    void agent.stop().then(() => process.exit(0));
  });
}
