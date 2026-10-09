import { Socket } from "phoenix";

// Client for the Converger API socket (/socket/converger, topic
// `converger:conversation:<id>`). Tokens come from
// POST /api/v1/converger/tokens/generate (your backend, with the channel
// secret) or POST /api/v1/converger/conversations.
export class ConvergerClient {
  constructor(baseUrl = "ws://localhost:4000/socket/converger") {
    this.baseUrl = baseUrl;
    this.socket = null;
    this.channel = null;
    this.watermark = null;
    this.onActivityCallback = null;
  }

  connect(token) {
    this.socket = new Socket(this.baseUrl, { params: { token: token } });
    this.socket.connect();
    return this.socket;
  }

  // `watermark` (optional) resumes after the last activity seen; every
  // rejoin after a reconnect sends the latest watermark, so nothing is
  // missed.
  joinConversation(conversationId, { watermark = null } = {}) {
    if (!this.socket) {
      throw new Error("Socket not connected");
    }

    this.watermark = watermark;
    const params = () => (this.watermark ? { watermark: this.watermark } : {});
    this.channel = this.socket.channel(`converger:conversation:${conversationId}`, params);

    this.channel.join()
      .receive("ok", resp => { console.log("Joined successfully", resp) })
      .receive("error", resp => { console.log("Unable to join", resp) });

    this.channel.on("activitySet", ({ activities, watermark }) => {
      if (watermark) this.watermark = watermark;
      if (this.onActivityCallback) activities.forEach(this.onActivityCallback);
    });

    return this.channel;
  }

  // Resolves with `{id, seq, watermark}` once the activity is stored.
  // Re-sending with the same `clientId` (e.g. after a timeout) never stores
  // it twice.
  sendMessage(text, { clientId = crypto.randomUUID() } = {}) {
    if (!this.channel) {
      throw new Error("Channel not joined");
    }

    return new Promise((resolve, reject) => {
      this.channel.push("postActivity", { type: "message", text: text, clientId: clientId })
        .receive("ok", resolve)
        .receive("error", reject)
        .receive("timeout", () => reject({ reason: "timeout", clientId: clientId }));
    });
  }

  onActivity(callback) {
    this.onActivityCallback = callback;
  }
}
