import { useEffect, useRef, useState } from "react";
import { ConvergerClient } from "@converger/client";

const CONVERSATION_KEY = "converger-demo:conversationId";

/**
 * Connects to Converger and keeps one conversation open: resumes the stored
 * conversation (replaying only what was missed) or starts a new one.
 * Unacknowledged messages live in localStorage (the default outbox storage)
 * and are resent after a reconnect or a reload.
 */
export function useConversation({ userId }) {
  const [messages, setMessages] = useState([]);
  const [state, setState] = useState("idle");
  const [typing, setTyping] = useState(false);
  const conversationRef = useRef(null);

  useEffect(() => {
    let cancelled = false;
    let client;

    (async () => {
      client = await ConvergerClient.connect({
        baseUrl: window.location.origin, // the Vite dev server proxies to Converger
        tokenProvider: async () => {
          const response = await fetch(`/demo/token?userId=${encodeURIComponent(userId)}`, { method: "POST" });
          if (!response.ok) throw new Error(await response.text());
          const { token, expires_in } = await response.json();
          return { token, expiresIn: expires_in };
        },
      });
      if (cancelled) return client.close();

      const stored = localStorage.getItem(CONVERSATION_KEY);
      const conversation = client.conversation(stored ?? undefined);
      conversationRef.current = conversation;

      conversation.on("connectionState", ({ state }) => setState(state));
      conversation.on("activity", (frame) => {
        if (frame.type !== "text") return;
        setMessages((list) => [...list, { key: frame.id, seq: frame.seq, from: frame.from, text: frame.data.text }]);
      });
      conversation.on("typing", (frame) => setTyping(frame.isTyping));
      conversation.on("deliveryStatus", (frame) => {
        const upTo = frame.data.upToSeq;
        if (frame.data.status !== "read" || upTo === undefined) return;
        setMessages((list) => list.map((m) => (m.from === "user" && m.seq <= upTo ? { ...m, read: true } : m)));
      });

      const welcome = stored ? await conversation.resume() : await conversation.start();
      localStorage.setItem(CONVERSATION_KEY, welcome.conversationId);
    })().catch((error) => setState(`error: ${error.message}`));

    return () => {
      cancelled = true;
      void client?.close();
    };
  }, [userId]);

  async function send(text) {
    const conversation = conversationRef.current;
    if (!conversation) return;
    const key = `local-${Date.now()}`;
    setMessages((list) => [...list, { key, from: "user", text, pending: true }]);
    try {
      const ack = await conversation.send(text);
      setMessages((list) => list.map((m) => (m.key === key ? { ...m, key: ack.id, seq: ack.seq, pending: false } : m)));
    } catch (error) {
      setMessages((list) => list.map((m) => (m.key === key ? { ...m, pending: false, failed: error.message } : m)));
    }
  }

  return {
    messages,
    state,
    typing,
    send,
    setTyping: (value) => conversationRef.current?.typing(value),
    markRead: () => conversationRef.current?.markRead(),
  };
}
