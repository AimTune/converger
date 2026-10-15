/**
 * Jittered exponential reconnect delays (spec section 12.3: "reconnect with
 * jittered exponential backoff"; docs/operations/websocket-limits.md).
 *
 * @module
 */

/** Reconnect policy. All durations in milliseconds. */
export interface ReconnectOptions {
  /** Reconnect at all. Default `true`. */
  enabled?: boolean;
  /** Delay before the first retry. Default 1000. */
  initialDelayMs?: number;
  /**
   * Upper bound of the exponential delay. Default 10000: low enough that a client
   * that failed a few times while a node restarted is back soon after (#198); the
   * server slows clients down with `retryAfterMs` when it needs to.
   */
  maxDelayMs?: number;
  /** Growth factor per attempt. Default 2. */
  factor?: number;
  /**
   * Fraction of the delay that is randomised, 0..1. Default 0.5: the delay is
   * uniformly drawn from `[base * (1 - jitter), base]` ("equal jitter").
   */
  jitter?: number;
  /** Give up after this many consecutive failed attempts. Default `Infinity`. */
  maxAttempts?: number;
}

/** A {@link ReconnectOptions} with every default filled in. */
export type ResolvedReconnect = Required<ReconnectOptions>;

/** Fill in the defaults of a reconnect policy. */
export function resolveReconnect(options: ReconnectOptions | false | undefined): ResolvedReconnect {
  const o = options === false ? { enabled: false } : (options ?? {});
  return {
    enabled: o.enabled ?? true,
    initialDelayMs: o.initialDelayMs ?? 1000,
    maxDelayMs: o.maxDelayMs ?? 10_000,
    factor: o.factor ?? 2,
    jitter: Math.min(1, Math.max(0, o.jitter ?? 0.5)),
    maxAttempts: o.maxAttempts ?? Number.POSITIVE_INFINITY,
  };
}

/**
 * The delay before reconnect attempt `attempt` (1-based). A server-provided
 * `retryAfterMs` is a floor: the client never reconnects earlier than asked.
 */
export function backoffDelay(
  attempt: number,
  policy: ResolvedReconnect,
  retryAfterMs?: number,
  random: () => number = Math.random,
): number {
  const exp = policy.initialDelayMs * policy.factor ** Math.max(0, attempt - 1);
  const base = Math.min(policy.maxDelayMs, exp);
  const delay = base * (1 - policy.jitter) + random() * base * policy.jitter;
  const floor = typeof retryAfterMs === "number" && retryAfterMs > 0 ? retryAfterMs : 0;
  return Math.round(Math.max(delay, floor));
}
