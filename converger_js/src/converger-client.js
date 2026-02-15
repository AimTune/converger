import { Socket } from "phoenix";

export class ConvergerClient {
  constructor(baseUrl = "ws://localhost:4000/socket") {
    this.baseUrl = baseUrl;
    this.socket = null;
    this.channel = null;
    this.onActivityCallback = null;
  }

  connect(token) {
    this.socket = new Socket(this.baseUrl, { params: { token: token } });
    this.socket.connect();
    return this.socket;
  }

  joinConversation(conversationId) {
    if (!this.socket) {
      throw new Error("Socket not connected");
    }

    this.channel = this.socket.channel(`conversation:${conversationId}`, {});
    
    this.channel.join()
      .receive("ok", resp => { console.log("Joined successfully", resp) })
      .receive("error", resp => { console.log("Unable to join", resp) });

    this.channel.on("new_activity", payload => {
      if (this.onActivityCallback) {
        this.onActivityCallback(payload);
      }
    });

    return this.channel;
  }

  sendMessage(text) {
    if (!this.channel) {
      throw new Error("Channel not joined");
    }

    this.channel.push("new_activity", { text: text });
  }

  onActivity(callback) {
    this.onActivityCallback = callback;
  }
}
