/**
 * A manual Claude tool loop mapped onto a Converger reply:
 *
 * - text deltas -> reply.stream() (genui text chunks, live in the web widget)
 * - each tool call -> reply.toolCall(id, "running" | "completed" | "error")
 * - a tool that needs approval -> reply.ask(...) with Approve / Reject chips,
 *   answered from any channel (a tapped WhatsApp button arrives as resume)
 */
import Anthropic from "@anthropic-ai/sdk";
import type { Reply } from "@converger/agent";
import { TOOLS, type ToolSpec } from "./tools.ts";

export const MODEL = "claude-sonnet-5-5";

export const SYSTEM =
  "You are the support agent of a small coffee equipment shop. Answer briefly. " +
  "Use lookup_order to check orders and refund_order to refund one; the user approves refunds themselves.";

/** What the loop needs from the Anthropic client (a fake in tests). */
export interface StreamLike {
  on(event: "text", listener: (delta: string) => void): unknown;
  finalMessage(): Promise<Anthropic.Beta.BetaMessage>;
}
export type CreateStream = (params: { messages: Anthropic.Beta.BetaMessageParam[]; signal: AbortSignal }) => StreamLike;

/** The real thing: streaming Messages API, with server-side fallback on refusals. */
export function anthropicStream(client: Anthropic): CreateStream {
  return ({ messages, signal }) =>
    client.beta.messages.stream(
      {
        model: MODEL,
        max_tokens: 64000,
        system: SYSTEM,
        tools: Object.values(TOOLS).map((t) => t.definition),
        messages,
        // Route refused requests to a fallback model chosen by the server.
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
      },
      { signal },
    );
}

const MAX_ITERATIONS = 8;

/**
 * Run the loop for one user turn. `messages` is the conversation so far
 * (ending with the user's message); the assistant turns and tool results are
 * appended to it.
 */
export async function runToolLoop(options: {
  messages: Anthropic.Beta.BetaMessageParam[];
  reply: Reply;
  createStream: CreateStream;
  signal: AbortSignal;
  tools?: Record<string, ToolSpec>;
}): Promise<void> {
  const { messages, reply, createStream, signal } = options;
  const tools = options.tools ?? TOOLS;

  for (let iteration = 0; iteration < MAX_ITERATIONS; iteration += 1) {
    await reply.typing();
    const out = reply.stream();
    const stream = createStream({ messages, signal });
    stream.on("text", (delta) => out.write(delta));
    let message: Anthropic.Beta.BetaMessage;
    try {
      message = await stream.finalMessage();
    } finally {
      await out.end();
    }

    if (message.stop_reason === "refusal") {
      await reply.text("Sorry, I can't help with that.");
      return;
    }
    if (message.stop_reason === "pause_turn") {
      messages.push({ role: "assistant", content: message.content });
      continue;
    }
    const uses = message.content.filter((b): b is Anthropic.Beta.BetaToolUseBlock => b.type === "tool_use");
    messages.push({ role: "assistant", content: message.content });
    if (uses.length === 0) return; // end_turn: the streamed text was the answer
    if (message.stop_reason === "max_tokens") throw new Error("tool input truncated at max_tokens");

    const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
    for (const use of uses) {
      const tool = tools[use.name];
      const input = tool?.parse(use.input);
      if (!tool || !input) {
        results.push({ type: "tool_result", tool_use_id: use.id, is_error: true, content: `invalid call to ${use.name}` });
        continue;
      }
      if (tool.needsApproval) {
        const answer = await reply.ask<{ approved?: boolean }>(
          { title: `${use.name.replace(/_/g, " ")} ${String(input["order_id"] ?? "")}?`, tool: use.name, input },
          {
            id: `approve-${use.id}`,
            actions: [
              { label: "Approve", value: { approved: true } },
              { label: "Reject", value: { approved: false } },
            ],
          },
        );
        if (answer?.approved !== true) {
          results.push({ type: "tool_result", tool_use_id: use.id, content: "The user rejected this action." });
          continue;
        }
      }
      await reply.toolCall(use.id, "running", { name: use.name, params: input });
      try {
        const result = await tool.run(input);
        await reply.toolCall(use.id, "completed", { result });
        results.push({ type: "tool_result", tool_use_id: use.id, content: JSON.stringify(result) });
      } catch (error) {
        const text = error instanceof Error ? error.message : String(error);
        await reply.toolCall(use.id, "error", { error: text });
        results.push({ type: "tool_result", tool_use_id: use.id, is_error: true, content: text });
      }
    }
    messages.push({ role: "user", content: results });
  }
  await reply.text("I stopped after too many steps; please rephrase your request.");
}
