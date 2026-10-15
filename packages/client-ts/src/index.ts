/**
 * `@converger/client`: a headless TypeScript client for Converger Protocol v1.
 *
 * - {@link ConvergerClient} and {@link Conversation}: connect, start or resume,
 *   send with acks, receive in order, reconnect with watermark resume.
 * - {@link RestClient}: tokens, conversations, history paging, uploads.
 * - Transports: {@link nativeTransport} (default), {@link phoenixTransport},
 *   {@link sseTransport}, or your own {@link TransportFactory}.
 * - Storage: {@link KeyValueStorage} adapters for the persistent outbox.
 *
 * @packageDocumentation
 */

export { ConvergerClient } from "./client.js";
export type { ClientEvents, ConversationOptions, ConvergerClientOptions, TransportOption } from "./client.js";

export { Conversation } from "./conversation.js";
export type {
  ConnectionState,
  ConnectionStateChange,
  ConversationEvents,
  SendFailure,
  SendMessage,
  SendResult,
} from "./conversation.js";

export { TypedEmitter } from "./emitter.js";
export type { EventMap, Listener } from "./emitter.js";

export {
  ConvergerApiError,
  ConvergerClosedError,
  ConvergerError,
  ConvergerProtocolError,
  apiErrorFrom,
  parseRetryAfter,
} from "./errors.js";

export { backoffDelay, resolveReconnect } from "./backoff.js";
export type { ReconnectOptions, ResolvedReconnect } from "./backoff.js";

export { createRefreshingTokenProvider, decodeToken } from "./token.js";
export type { TokenClaims, TokenInfo, TokenProvider, TokenRequestReason } from "./token.js";

export { RestClient, generateToken, refreshToken } from "./rest/client.js";
export type { FetchLike, HistoryOptions, RestClientOptions, UploadOptions } from "./rest/client.js";
export type * from "./rest/types.js";
export type { components as RestSchemaComponents } from "./rest/openapi.js";

export { MemoryStorage, WebStorage, defaultStorage } from "./storage/storage.js";
export type { KeyValueStorage, WebStorageLike } from "./storage/storage.js";
export type { OutboxEntry, ResumeState } from "./storage/outbox.js";

export { nativeTransport } from "./transport/native.js";
export type { NativeTransportOptions } from "./transport/native.js";
export { phoenixTransport } from "./transport/phoenix.js";
export type { PhoenixTransportOptions } from "./transport/phoenix.js";
export { sseTransport } from "./transport/sse.js";
export type { SseTransportOptions } from "./transport/sse.js";
export type {
  Transport,
  TransportCapabilities,
  TransportClose,
  TransportConnectParams,
  TransportEnvironment,
  TransportFactory,
  TransportHandlers,
  WebSocketConstructor,
  WebSocketLike,
} from "./transport/types.js";

export * from "./protocol/frames.js";
export { encodeOpaqueWatermark, parseWatermark } from "./protocol/watermark.js";
