// Not vendored: the Converger side of the chativa compatibility test
// (test/protocol/chativa_compat_test.exs, issue #65).
//
// Drives chativa's real MekikConnector (vendored in ./connector-mekik) and
// parseChatFrame (./core/ChatFrame.ts) from Node, and reports what chativa's
// ChatEngine would receive as one JSON object per stdout line. Needs a Node
// that runs TypeScript directly (type stripping: Node >= 22.18 or >= 23.6).
//
//   node harness.mjs connect '<json options>'
//     Connects a MekikConnector with { url, token, conversationId, userId?,
//     protocols?, routeInUrl?, resumeConversation?, storage? } and prints every
//     handler call. `storage` is a JSON file that keeps localStorage across
//     runs (a page reload); without it localStorage starts empty in memory.
//       {"event":"capabilities","value":{...},"identity":{...}|null}
//       {"event":"message","message":{...}}      onMessage
//       {"event":"typing","isTyping":true}        onTyping
//       {"event":"toolCall","toolCall":{...}}     onToolCall
//       {"event":"genui","streamId":"...","chunk":{...},"done":false}
//       {"event":"connected"} / {"event":"disconnected","reason":"..."}
//     Reads commands from stdin, one JSON object per line:
//       {"cmd":"send","message":{id,type,data}}   connector.sendMessage
//       {"cmd":"disconnect"}                       connector.disconnect, then
//                                                  {"event":"closed"}
//       {"cmd":"connect"}                          connector.connect again (the
//                                                  same instance, so its watermark):
//                                                  {"event":"connecting","watermark":n},
//                                                  then {"event":"connected"}
//       {"cmd":"exit"}                             disconnect and exit
//     Exits when stdin closes.
//
//   node harness.mjs parse <file>
//     Reads a JSON array of frames from <file> and prints the array of
//     parseChatFrame results (deterministic: idPrefix "rest", now = 0).

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { MekikConnector, TokenAuth } from "./connector-mekik/index.ts";
import { parseChatFrame } from "./core/ChatFrame.ts";

const emit = (event) => process.stdout.write(JSON.stringify(event) + "\n");

// The test closed its end (it is done with us): exit quietly.
process.stdout.on("error", () => process.exit(0));

// A browser profile's localStorage: empty and in memory, or kept in the JSON
// file `options.storage` so a second harness run is a page reload. (Node 22
// has none, Node 25 has one that warns without --localstorage-file.)
function installStorage(file) {
  const storage = new Map(
    file && existsSync(file) ? Object.entries(JSON.parse(readFileSync(file, "utf8"))) : [],
  );
  const save = () => file && writeFileSync(file, JSON.stringify(Object.fromEntries(storage)));
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (key) => (storage.has(key) ? storage.get(key) : null),
      setItem: (key, value) => (storage.set(key, String(value)), save()),
      removeItem: (key) => (storage.delete(key), save()),
    },
  });
}

async function connect(options) {
  installStorage(options.storage);
  const connector = new MekikConnector({
    url: options.url,
    auth: new TokenAuth({ token: options.token }),
    conversationId: options.conversationId,
    userId: options.userId,
    routeInUrl: options.routeInUrl ?? true,
    protocols: options.protocols ?? [],
    resumeConversation: options.resumeConversation ?? false,
    reconnect: false,
  });

  connector.onMessage((message) => emit({ event: "message", message }));
  connector.onTyping((isTyping) => emit({ event: "typing", isTyping }));
  connector.onToolCall((toolCall) => emit({ event: "toolCall", toolCall }));
  connector.onGenUIChunk((streamId, chunk, done) => emit({ event: "genui", streamId, chunk, done }));
  connector.onDisconnect((reason) => emit({ event: "disconnected", reason: reason ?? null }));
  connector.onCapabilities((value) =>
    emit({ event: "capabilities", value, identity: connector.identity }),
  );

  const lines = createInterface({ input: process.stdin });
  lines.on("line", async (line) => {
    if (!line.trim()) return;
    const command = JSON.parse(line);
    if (command.cmd === "send") {
      await connector.sendMessage(command.message);
      emit({ event: "sent", id: command.message.id });
    } else if (command.cmd === "disconnect") {
      await connector.disconnect();
      emit({ event: "closed" });
    } else if (command.cmd === "connect") {
      // The watermark the hello will carry (a TypeScript-private field).
      emit({ event: "connecting", watermark: connector.watermark });
      await connector.connect();
      emit({ event: "connected" });
    } else if (command.cmd === "exit") {
      await connector.disconnect();
      process.exit(0);
    }
  });
  lines.on("close", () => process.exit(0));

  await connector.connect();
  emit({ event: "connected" });
}

function parse(file) {
  const frames = JSON.parse(readFileSync(file, "utf8"));
  const parsed = frames.map((frame) => parseChatFrame(frame, { idPrefix: "rest", now: () => 0 }));
  process.stdout.write(JSON.stringify(parsed) + "\n");
}

const [mode, arg] = process.argv.slice(2);

try {
  if (mode === "connect") await connect(JSON.parse(arg));
  else if (mode === "parse") parse(arg);
  else throw new Error(`unknown mode ${mode}`);
} catch (error) {
  emit({ event: "error", message: String(error?.message ?? error) });
  process.exit(1);
}
