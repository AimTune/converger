/**
 * `@converger/agent`: serve every conversation of a Converger channel from one
 * WebSocket (Protocol v1 channel-scoped sockets) with one handler:
 *
 * ```ts
 * import { createAgent, channelTokenProvider } from "@converger/agent";
 *
 * const agent = createAgent({
 *   url: "https://converger.example.com",
 *   getToken: channelTokenProvider({ url: "https://converger.example.com", secret: process.env.CHANNEL_SECRET! }),
 * });
 * agent.onTurn(async (turn, reply) => {
 *   await reply.text(`You said: ${turn.text}`);
 * });
 * await agent.start();
 * ```
 *
 * The same `onTurn(turn, reply)` API exists in the Python, Go, .NET and Elixir
 * agent SDKs ([ADR-0067](https://converger.aimtune.dev/adr/0067-agent-sdk-api-and-wire-mapping)).
 *
 * @packageDocumentation
 */

export { Agent, createAgent } from "./agent.js";
export type { AgentEvents, AgentOptions, DisconnectInfo, FrameHandler, Logger, ResumeInfo, TurnHandler } from "./agent.js";

export type { AskOptions, Reply, ReplyStream, SendOptions, StreamMode, StreamOptions, ToolCallOptions } from "./reply.js";
export type { HistoryOptions, Turn, TurnChannel } from "./turn.js";

export { AgentError, isAgentError } from "./errors.js";

export { channelTokenProvider, generateChannelToken } from "./token.js";
export type { ChannelToken, ChannelTokenOptions, FetchLike, TokenRequest } from "./token.js";

export { backoffDelay, resolveReconnect } from "./backoff.js";
export type { ReconnectOptions, ResolvedReconnect } from "./backoff.js";

export { TypedEmitter } from "./emitter.js";
export type { EventMap, Listener } from "./emitter.js";

export { CLIENT_IDLE_CLOSE } from "./socket.js";
export type { SocketClose, WebSocketConstructor, WebSocketLike } from "./socket.js";

export * from "./frames.js";
