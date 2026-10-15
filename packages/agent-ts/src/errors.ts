/**
 * Errors raised by the agent SDK. Every error is an {@link AgentError} with a
 * stable `code` (a protocol error code from section 12.2 of the spec, or one of
 * the SDK's own codes below) and `retryable`.
 *
 * SDK codes: `closed` (the agent was stopped), `aborted` (the turn was aborted
 * by the end user or by an `AbortSignal`), `timeout` (an `ask` or a send timed
 * out), `handler_error` (an `onTurn` handler threw), `connect_failed` (the first
 * connection could not be established), `token_error` (`getToken` failed),
 * `http_error` (a REST call failed).
 *
 * @module
 */

import type { ErrorData, ErrorFrame } from "./frames.js";

/** Codes that are retryable per section 12.2, for error frames that omit `retryable`. */
const RETRYABLE = new Set([
  "token_expired",
  "rate_limited",
  "too_many_in_flight",
  "slow_consumer",
  "busy",
  "bot_unavailable",
  "internal",
  "unavailable",
  "replay_unavailable",
]);

/** Base class of every error this package throws or emits. */
export class AgentError extends Error {
  /** Stable, machine-readable code. */
  readonly code: string;
  /** Whether the same operation may succeed later (for sends: with the same `clientId`). */
  readonly retryable: boolean;
  /** Wait at least this long before retrying, when the server said so. */
  readonly retryAfterMs: number | undefined;
  /** The conversation the error is about, when it is about one. */
  readonly conversationId: string | undefined;
  /** Numeric protocol code (section 12.2), for protocol errors. */
  readonly number: number | undefined;
  /** The `clientId` of the send the error answers. */
  readonly clientId: string | undefined;
  /** The `type` of the frame the error answers. */
  readonly frameType: string | undefined;
  /** Extra details (validation errors per field, ...). */
  readonly details: Record<string, unknown> | undefined;

  constructor(
    code: string,
    message: string,
    options: {
      retryable?: boolean;
      retryAfterMs?: number | undefined;
      conversationId?: string | undefined;
      number?: number | undefined;
      clientId?: string | undefined;
      frameType?: string | undefined;
      details?: Record<string, unknown> | undefined;
      cause?: unknown;
    } = {},
  ) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = "AgentError";
    this.code = code;
    this.retryable = options.retryable ?? RETRYABLE.has(code);
    this.retryAfterMs = options.retryAfterMs;
    this.conversationId = options.conversationId;
    this.number = options.number;
    this.clientId = options.clientId;
    this.frameType = options.frameType;
    this.details = options.details;
  }

  /** Map an `error` frame (bare or from an envelope) to an {@link AgentError}. */
  static fromFrame(frame: ErrorFrame | { data: ErrorData }, conversationId?: string): AgentError {
    const data = frame.data;
    return new AgentError(data.code, data.message || data.code, {
      retryable: typeof data.retryable === "boolean" ? data.retryable : RETRYABLE.has(data.code),
      retryAfterMs: data.retryAfterMs,
      conversationId,
      number: data.number,
      clientId: data.clientId,
      frameType: data.frameType,
      details: data.details,
    });
  }
}

/** Whether `error` is an {@link AgentError} with `code`. */
export function isAgentError(error: unknown, code?: string): error is AgentError {
  return error instanceof AgentError && (code === undefined || error.code === code);
}
