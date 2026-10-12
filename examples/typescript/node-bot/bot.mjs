// A Node participant on @converger/client: joins (or resumes) a conversation
// and answers every text message from someone else. It survives server
// restarts: the client reconnects, replays what it missed and resends its
// unacknowledged replies once.
//
//   CONVERGER_URL=http://localhost:4000 CHANNEL_SECRET=... node bot.mjs [conversationId]
//
// The bot holds the channel secret, so it runs server side and mints its own
// tokens. For a full bot/agent SDK (channel-scoped sockets) see #67.
import { ConvergerClient, generateToken } from "@converger/client";

const baseUrl = process.env.CONVERGER_URL ?? "http://localhost:4000";
const secret = process.env.CHANNEL_SECRET;
const userId = process.env.BOT_USER_ID ?? "node-bot";
if (!secret) {
  console.error("Set CHANNEL_SECRET (the secret of a Converger channel).");
  process.exit(1);
}

const client = await ConvergerClient.connect({
  baseUrl,
  tokenProvider: async ({ reason }) => {
    const { token, expires_in } = await generateToken({ baseUrl, secret, userId });
    console.log(`[token] ${reason}`);
    return { token, expiresIn: expires_in };
  },
  // Node 22+ has a global WebSocket; on Node 20 pass `WebSocket` from the `ws` package.
});

const conversationId = process.argv[2];
const conversation = client.conversation(conversationId);

// Only answer live messages, not the transcript replayed on start/resume.
let liveAfter = Number.POSITIVE_INFINITY;
conversation.once("welcome", (data) => {
  liveAfter = data.watermark ?? 0;
});

conversation.on("connectionState", ({ state, attempt, delayMs }) => {
  console.log(`[state] ${state}${delayMs ? ` (attempt ${attempt}, retry in ${delayMs} ms)` : ""}`);
});
conversation.on("activity", async (frame) => {
  if (frame.type !== "text") return;
  console.log(`[${frame.seq}] ${frame.sender?.id ?? frame.from}: ${frame.data.text}`);
  if (frame.from === "user" || frame.seq <= liveAfter) return; // own turns and history
  try {
    const ack = await conversation.send(`You said: ${frame.data.text}`);
    console.log(`[sent] seq ${ack.seq}${ack.duplicate ? " (duplicate)" : ""}`);
  } catch (error) {
    console.error("[send failed]", error);
  }
});
conversation.on("error", (error) => console.warn("[error]", error.code, error.message));

const welcome = conversationId ? await conversation.resume() : await conversation.start();
console.log(`[welcome] conversation ${welcome.conversationId}, head seq ${welcome.watermark}`);
console.log("Post a message to this conversation (REST, a widget, another channel) and watch the reply.");

process.on("SIGINT", async () => {
  await client.close();
  process.exit(0);
});
