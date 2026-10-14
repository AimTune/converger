/**
 * Per-conversation resume positions of a channel-scoped connection.
 *
 * For each conversation the tracker keeps the highest `seq` seen (from
 * delivered frames and from the acks of the agent's own sends) and a window of
 * recently seen seqs. The highest seq is what `hello.watermarks` sends on
 * reconnect, so the server replays exactly what was missed. The window answers
 * "was this frame already seen?": a frame below the highest seq is not
 * necessarily a duplicate (a user turn committed just before the agent's own
 * send may arrive after that send's ack), so only seqs actually seen, or older
 * than the window, count as duplicates.
 *
 * At most `capacity` conversations are tracked; the least recently active is
 * forgotten first (the server follows at most `maxConversations` per
 * connection anyway).
 *
 * @module
 */

interface Position {
  /** Highest seq seen. */
  high: number;
  /** Seqs at or below this are treated as seen. */
  floor: number;
  /** Seen seqs above `floor`. */
  seen: Set<number>;
}

const WINDOW = 512;

/** @internal */
export class WatermarkTracker {
  readonly #capacity: number;
  readonly #positions = new Map<string, Position>();

  constructor(capacity: number, initial: Record<string, number> = {}) {
    this.#capacity = Math.max(1, capacity);
    for (const [id, seq] of Object.entries(initial)) {
      if (Number.isInteger(seq) && seq >= 0) this.#touch(id, { high: seq, floor: seq, seen: new Set() });
    }
  }

  /** The highest seq seen of a conversation (0 when unknown). */
  get(conversationId: string): number {
    return this.#positions.get(conversationId)?.high ?? 0;
  }

  /** Whether the conversation is tracked. */
  has(conversationId: string): boolean {
    return this.#positions.has(conversationId);
  }

  /** Whether `seq` of the conversation was already seen. */
  seen(conversationId: string, seq: number): boolean {
    const position = this.#positions.get(conversationId);
    if (!position) return false;
    return seq <= position.floor || position.seen.has(seq);
  }

  /** Record `seq` as seen; returns false when it already was. */
  record(conversationId: string, seq: number): boolean {
    if (!Number.isInteger(seq) || seq < 1) return true;
    const position = this.#positions.get(conversationId) ?? { high: 0, floor: 0, seen: new Set<number>() };
    const fresh = !(seq <= position.floor || position.seen.has(seq));
    if (fresh) {
      position.seen.add(seq);
      if (seq > position.high) position.high = seq;
      if (position.seen.size > WINDOW) {
        // Forget the oldest seqs; everything up to them counts as seen.
        const sorted = [...position.seen].sort((a, b) => a - b);
        for (const old of sorted.slice(0, sorted.length - WINDOW)) {
          position.seen.delete(old);
          if (old > position.floor) position.floor = old;
        }
      }
    }
    this.#touch(conversationId, position);
    return fresh;
  }

  /** Every tracked conversation's highest seq, least recently active first. */
  snapshot(): Record<string, number> {
    const out: Record<string, number> = {};
    for (const [id, position] of this.#positions) out[id] = position.high;
    return out;
  }

  /** Mark a conversation as active without recording a seq. */
  touch(conversationId: string): void {
    const position = this.#positions.get(conversationId);
    if (position) this.#touch(conversationId, position);
  }

  #touch(id: string, position: Position): void {
    this.#positions.delete(id);
    this.#positions.set(id, position);
    while (this.#positions.size > this.#capacity) {
      const oldest = this.#positions.keys().next().value as string;
      this.#positions.delete(oldest);
    }
  }
}
