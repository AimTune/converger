/**
 * The demo tools: a read-only order lookup and a refund that needs the end
 * user's approval. Replace them with your own; the loop in loop.ts does not
 * care what they do.
 */
import type Anthropic from "@anthropic-ai/sdk";

export interface ToolSpec {
  definition: Anthropic.Beta.BetaTool;
  /** Ask the end user before running it (reply.ask). */
  needsApproval: boolean;
  /** Validate the (possibly truncated, see eager_input_streaming) input. */
  parse(input: unknown): Record<string, unknown> | undefined;
  run(input: Record<string, unknown>): Promise<unknown>;
}

const ORDERS: Record<string, { id: string; item: string; total: number; currency: string; status: string }> = {
  "ORD-42": { id: "ORD-42", item: "Espresso machine", total: 249.9, currency: "TRY", status: "delivered" },
  "ORD-43": { id: "ORD-43", item: "Grinder", total: 89.5, currency: "TRY", status: "shipped" },
};

function orderId(input: unknown): Record<string, unknown> | undefined {
  if (typeof input !== "object" || input === null) return undefined;
  const id = (input as { order_id?: unknown }).order_id;
  return typeof id === "string" && /^ORD-\d+$/.test(id) ? { order_id: id } : undefined;
}

export const TOOLS: Record<string, ToolSpec> = {
  lookup_order: {
    definition: {
      name: "lookup_order",
      description: "Look up an order by id (ORD-<digits>): item, total, currency and delivery status.",
      eager_input_streaming: true,
      input_schema: {
        type: "object",
        properties: { order_id: { type: "string", description: "Order id, e.g. ORD-42" } },
        required: ["order_id"],
      },
    },
    needsApproval: false,
    parse: orderId,
    run: async (input) => ORDERS[String(input["order_id"])] ?? { error: "order not found" },
  },
  refund_order: {
    definition: {
      name: "refund_order",
      description: "Refund an order in full. The end user is asked to approve before it runs.",
      eager_input_streaming: true,
      input_schema: {
        type: "object",
        properties: { order_id: { type: "string", description: "Order id, e.g. ORD-42" } },
        required: ["order_id"],
      },
    },
    needsApproval: true,
    parse: orderId,
    run: async (input) => {
      const order = ORDERS[String(input["order_id"])];
      return order ? { refunded: true, order_id: order.id, amount: order.total, currency: order.currency } : { error: "order not found" };
    },
  },
};
