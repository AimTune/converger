/**
 * The tool loop against the SDK's fake Converger server and a scripted fake
 * of the Anthropic stream: no network, no API key.
 */
import { afterEach, beforeEach, expect, it } from "vitest";
import type Anthropic from "@anthropic-ai/sdk";
import { createAgent, type Agent } from "@converger/agent";
import { FakeConvergerServer } from "@converger/agent/testing";
import { runToolLoop, type CreateStream } from "../src/loop.ts";

type Block = Anthropic.Beta.BetaContentBlock;

/** Replays scripted assistant turns: text deltas, then the final message. */
function scripted(turns: { text?: string; tools?: { id: string; name: string; input: unknown }[] }[]): CreateStream {
  let i = 0;
  return () => {
    const turn = turns[i++] ?? { text: "(no more turns)" };
    const listeners: ((delta: string) => void)[] = [];
    return {
      on(_event: "text", listener: (delta: string) => void) {
        listeners.push(listener);
        return this;
      },
      async finalMessage() {
        for (const word of (turn.text ?? "").split(/(?<= )/)) if (word) listeners.forEach((l) => l(word));
        const content = [
          ...(turn.text ? [{ type: "text", text: turn.text, citations: null }] : []),
          ...(turn.tools ?? []).map((t) => ({ type: "tool_use", id: t.id, name: t.name, input: t.input })),
        ] as unknown as Block[];
        return { content, stop_reason: turn.tools?.length ? "tool_use" : "end_turn" } as unknown as Anthropic.Beta.BetaMessage;
      },
    };
  };
}

let server: FakeConvergerServer;
let agent: Agent;

beforeEach(async () => {
  server = await FakeConvergerServer.start();
});

afterEach(async () => {
  await agent.stop({ timeoutMs: 200 });
  await server.stop();
});

function start(createStream: CreateStream): Promise<void> {
  agent = createAgent({ url: server.url, token: "test", streamFlushMs: 5 });
  agent.onTurn(async (turn, reply) => {
    await runToolLoop({ messages: [{ role: "user", content: turn.text }], reply, createStream, signal: turn.signal });
  });
  return agent.start();
}

it("streams the answer and shows the lookup as a tool call", async () => {
  await start(
    scripted([
      { text: "Let me check. ", tools: [{ id: "tu1", name: "lookup_order", input: { order_id: "ORD-42" } }] },
      { text: "ORD-42 was delivered." },
    ]),
  );
  const result = await server.turn("conv-1", "where is ORD-42?");
  expect(result.streamed).toBe("Let me check. ORD-42 was delivered.");
  expect(result.toolCalls.map((t) => [t["name"], t["status"]])).toEqual([
    ["lookup_order", "running"],
    ["lookup_order", "completed"],
  ]);
  expect(result.status).toBe("finished");
});

it("asks before refunding and continues with the answer", async () => {
  await start(
    scripted([
      { tools: [{ id: "tu2", name: "refund_order", input: { order_id: "ORD-42" } }] },
      { text: "Refunded 249.90 TRY." },
    ]),
  );
  const first = await server.turn("conv-2", "refund ORD-42");
  expect(first.status).toBe("interrupted");
  const interrupt = first.interrupts[0]!;
  expect((interrupt["data"] as { actions: unknown[] }).actions).toHaveLength(2);
  const from = server.received.length;
  server.resume("conv-2", { [String(interrupt["id"])]: { approved: true } });
  const second = await server.collect("conv-2", from, { until: ["finished"] });
  expect(second.toolCalls.map((t) => t["status"])).toEqual(["running", "completed"]);
  expect(second.streamed).toBe("Refunded 249.90 TRY.");
});
