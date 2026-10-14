import type { TurnHandler } from "@converger/agent";

/**
 * Your agent. It gets every user turn of the conversations routed to its
 * channel (web widget, WhatsApp, Telegram, ...) and answers with `reply`:
 * text, stream(), message(type, data), toolCall(...), ui(...), ask(...).
 */
export const handleTurn: TurnHandler = async (turn, reply) => {
  if (turn.text.toLowerCase() === "help") {
    const choice = await reply.ask<string>("What do you need?", {
      actions: [
        { label: "Track an order", value: "track" },
        { label: "Talk to a human", value: "human" },
      ],
    });
    await reply.text(choice === "track" ? "Send me your order number." : "A colleague will join shortly.");
    return;
  }
  await reply.typing();
  await reply.text(`You said: ${turn.text}`, { actions: [{ label: "Help", value: "help" }] });
};
