/**
 * Errors raised by the client.
 *
 * @module
 */

import type { ErrorFrame } from "./protocol/frames.js";

/** Base class of every error this package throws. */
export class ConvergerError extends Error {
  /** Stable, machine-readable code (protocol error code, REST error code or a client code). */
  readonly code: string;

  constructor(code: string, message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "ConvergerError";
    this.code = code;
  }
}

/** An `error` frame from the server (spec section 12). */
export class ConvergerProtocolError extends ConvergerError {
  readonly number: number | undefined;
  readonly retryable: boolean;
  readonly retryAfterMs: number | undefined;
  readonly details: Record<string, unknown> | undefined;
  readonly clientId: string | undefined;
  readonly frameType: string | undefined;

  constructor(frame: ErrorFrame) {
    super(frame.data.code, frame.data.message || frame.data.code);
    this.name = "ConvergerProtocolError";
    this.number = frame.data.number;
    this.retryable = frame.data.retryable === true;
    this.retryAfterMs = frame.data.retryAfterMs;
    this.details = frame.data.details;
    this.clientId = frame.data.clientId;
    this.frameType = frame.data.frameType;
  }
}

/**
 * A failed REST request. Understands the standard error envelope
 * `{"error": {"code", "message", "details", "request_id"}}` (#45) and the
 * shapes the server returns today: `{"error": "text"}`,
 * `{"error": "conversation_closed", "detail": "..."}`,
 * `{"errors": {"detail": "..."}}` and changeset errors `{"errors": {"field": ["..."]}}`.
 */
export class ConvergerApiError extends ConvergerError {
  /** HTTP status. */
  readonly status: number;
  readonly details: Record<string, unknown> | undefined;
  /** The server's request id, when the envelope carries one. */
  readonly requestId: string | undefined;
  /** From `Retry-After` (429, 503). */
  readonly retryAfterMs: number | undefined;
  /** The parsed response body (or text). */
  readonly body: unknown;

  constructor(init: {
    status: number;
    code: string;
    message: string;
    details?: Record<string, unknown> | undefined;
    requestId?: string | undefined;
    retryAfterMs?: number | undefined;
    body?: unknown;
  }) {
    super(init.code, init.message);
    this.name = "ConvergerApiError";
    this.status = init.status;
    this.details = init.details;
    this.requestId = init.requestId;
    this.retryAfterMs = init.retryAfterMs;
    this.body = init.body;
  }

  /** Whether retrying the same request later may succeed. */
  get retryable(): boolean {
    return this.status === 429 || this.status === 503 || this.status >= 500;
  }
}

/** The connection or session was closed for good (no more reconnects). */
export class ConvergerClosedError extends ConvergerError {
  constructor(message = "the conversation session is closed", code = "closed") {
    super(code, message);
    this.name = "ConvergerClosedError";
  }
}

const STATUS_CODES: Record<number, string> = {
  400: "bad_request",
  401: "unauthorized",
  403: "forbidden",
  404: "not_found",
  409: "conflict",
  413: "payload_too_large",
  415: "unsupported_media_type",
  422: "invalid_message",
  429: "rate_limited",
  502: "bad_gateway",
  503: "unavailable",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Parse `Retry-After` (seconds or an HTTP date) into milliseconds. */
export function parseRetryAfter(value: string | null | undefined, now = Date.now()): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, Math.round(seconds * 1000));
  const date = Date.parse(value);
  return Number.isNaN(date) ? undefined : Math.max(0, date - now);
}

/** Build a {@link ConvergerApiError} from a response status, headers and body. */
export function apiErrorFrom(status: number, body: unknown, retryAfter?: string | null): ConvergerApiError {
  const fallbackCode = STATUS_CODES[status] ?? (status >= 500 ? "internal" : "http_error");
  const retryAfterMs = parseRetryAfter(retryAfter);
  let code = fallbackCode;
  let message = `HTTP ${status}`;
  let details: Record<string, unknown> | undefined;
  let requestId: string | undefined;

  if (isRecord(body)) {
    const error = body["error"];
    const errors = body["errors"];

    if (isRecord(error)) {
      // Standard envelope (#45).
      if (typeof error["code"] === "string") code = error["code"];
      if (typeof error["message"] === "string") message = error["message"];
      if (isRecord(error["details"])) details = error["details"];
      if (typeof error["request_id"] === "string") requestId = error["request_id"];
    } else if (typeof error === "string") {
      // {"error": "text"} and {"error": "conversation_closed", "detail": "..."}.
      if (/^[a-z][a-z0-9_]*$/.test(error)) {
        code = error;
        message = typeof body["detail"] === "string" ? body["detail"] : error;
      } else {
        message = error;
      }
    } else if (isRecord(errors)) {
      if (typeof errors["detail"] === "string" && Object.keys(errors).length === 1) {
        message = errors["detail"];
      } else {
        // Changeset errors keyed by field (HTTP 422).
        details = errors;
        message = "validation failed";
      }
    }
  } else if (typeof body === "string" && body.trim() !== "") {
    message = body.trim().slice(0, 500);
  }

  return new ConvergerApiError({ status, code, message, details, requestId, retryAfterMs, body });
}
