import { afterEach, beforeEach, expect, it } from "vitest";
import { createAgent, type Agent } from "@converger/agent";
import { FakeConvergerServer } from "@converger/agent/testing";
import { handleTurn } from "../src/handler.ts";

let server: FakeConvergerServer;
let agent: Agent;

beforeEach(async () => {
  // An in-process fake of the Converger endpoint: no server, no secret needed.
  server = await FakeConvergerServer.start();
  agent = createAgent({ url: server.url, token: "test" });
  agent.onTurn(handleTurn);
  await agent.start();
});

afterEach(async () => {
  await agent.stop();
  await server.stop();
});

it("echoes the user's text with a Help chip", async () => {
  const result = await server.turn("conversation-1", "hello");
  expect(result.texts).toEqual(["You said: hello"]);
  expect(result.messages[0]?.["actions"]).toEqual([{ label: "Help", value: "help" }]);
});

it("asks a question and continues with the answer", async () => {
  const asked = await server.turn("conversation-2", "help");
  expect(asked.status).toBe("interrupted");
  const interrupt = asked.interrupts[0]!;

  const from = server.received.length;
  server.resume("conversation-2", { [String(interrupt["id"])]: "track" });
  const answered = await server.collect("conversation-2", from, { until: ["finished"] });
  expect(answered.texts).toEqual(["Send me your order number."]);
});
