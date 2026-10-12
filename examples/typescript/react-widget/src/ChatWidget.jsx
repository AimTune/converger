import { useEffect, useState } from "react";
import { useConversation } from "./useConversation.js";

export function ChatWidget({ userId }) {
  const { messages, state, typing, send, setTyping, markRead } = useConversation({ userId });
  const [draft, setDraft] = useState("");

  // Mark what is on screen as read.
  useEffect(() => {
    if (state === "open" && messages.length > 0) markRead();
  }, [messages.length, state]);

  function submit(event) {
    event.preventDefault();
    const text = draft.trim();
    if (!text) return;
    setDraft("");
    setTyping(false);
    void send(text);
  }

  return (
    <div style={{ maxWidth: 420, margin: "2rem auto", fontFamily: "system-ui, sans-serif" }}>
      <header style={{ display: "flex", justifyContent: "space-between" }}>
        <strong>Support</strong>
        <small>{state}</small>
      </header>
      <ul style={{ listStyle: "none", padding: 0, minHeight: 240 }}>
        {messages.map((m) => (
          <li key={m.key} style={{ textAlign: m.from === "user" ? "right" : "left", margin: "0.25rem 0" }}>
            <span
              style={{ background: m.from === "user" ? "#dbeafe" : "#f3f4f6", padding: "0.3rem 0.6rem", borderRadius: 8 }}
            >
              {m.text}
            </span>
            <small style={{ marginLeft: 4, opacity: 0.6 }}>
              {m.failed ? `failed: ${m.failed}` : m.pending ? "sending" : m.read ? "read" : ""}
            </small>
          </li>
        ))}
      </ul>
      {typing && <p style={{ opacity: 0.6 }}>typing...</p>}
      <form onSubmit={submit} style={{ display: "flex", gap: 8 }}>
        <input
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value);
            setTyping(event.target.value !== "");
          }}
          placeholder="Type a message"
          style={{ flex: 1 }}
        />
        <button type="submit">Send</button>
      </form>
    </div>
  );
}
