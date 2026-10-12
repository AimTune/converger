/**
 * The persistent outbox and resume state of one conversation.
 *
 * Every send is written to the outbox before it is put on the wire and
 * removed when its `ack` (or a non-retryable error) arrives. After a reconnect,
 * a reload or a process restart, whatever is still in the outbox is resent with
 * its original `clientId`; the server stores each clientId once (spec section
 * 7), so a message is persisted exactly once however often it is resent.
 *
 * @module
 */

import type { ClientMessageFrame } from "../protocol/frames.js";
import type { KeyValueStorage } from "./storage.js";

/** One unacknowledged send. */
export interface OutboxEntry {
  clientId: string;
  frame: ClientMessageFrame;
  /** ms since the epoch. */
  createdAt: number;
  /** How many times the frame was put on the wire. */
  attempts: number;
}

/** What `resume()` needs after a reload. */
export interface ResumeState {
  conversationId: string;
  /** The user id the server echoed (or minted) in `welcome`; resent in `hello` so clientIds keep their namespace. */
  userId?: string;
  /** The highest contiguous seq seen. */
  watermark: number;
}

interface Persisted {
  v: 1;
  state?: ResumeState;
  outbox: OutboxEntry[];
}

/** @internal */
export class ConversationStore {
  readonly #storage: KeyValueStorage;
  readonly #prefix: string;
  #key: string | null;
  #entries: OutboxEntry[] = [];
  #state: ResumeState | undefined;
  #writing: Promise<void> = Promise.resolve();
  #onError: (error: unknown) => void;

  constructor(
    storage: KeyValueStorage,
    prefix: string,
    conversationId: string | null,
    onError: (error: unknown) => void,
  ) {
    this.#storage = storage;
    this.#prefix = prefix;
    this.#key = conversationId === null ? null : this.#keyFor(conversationId);
    this.#onError = onError;
  }

  #keyFor(conversationId: string): string {
    return `${this.#prefix}:conversation:${conversationId}`;
  }

  /** Load the persisted outbox and state (no-op before the conversation id is known). */
  async load(): Promise<void> {
    if (this.#key === null) return;
    try {
      const raw = await this.#storage.getItem(this.#key);
      if (!raw) return;
      const parsed = JSON.parse(raw) as Partial<Persisted>;
      if (parsed && parsed.v === 1) {
        const known = new Set(this.#entries.map((e) => e.clientId));
        const loaded = (parsed.outbox ?? []).filter((e) => !known.has(e.clientId));
        this.#entries = [...loaded, ...this.#entries];
        this.#state = parsed.state ?? this.#state;
      }
    } catch (error) {
      this.#onError(error);
    }
  }

  /** Attach to a conversation id (after `welcome` of a new conversation), merging what was stored there. */
  async attach(conversationId: string): Promise<void> {
    const key = this.#keyFor(conversationId);
    if (this.#key === key) return;
    this.#key = key;
    await this.load();
    this.#persist();
  }

  get state(): ResumeState | undefined {
    return this.#state;
  }

  get entries(): readonly OutboxEntry[] {
    return this.#entries;
  }

  get(clientId: string): OutboxEntry | undefined {
    return this.#entries.find((e) => e.clientId === clientId);
  }

  add(entry: OutboxEntry): void {
    this.#entries.push(entry);
    this.#persist();
  }

  touch(clientId: string): void {
    const entry = this.get(clientId);
    if (entry) {
      entry.attempts += 1;
      this.#persist();
    }
  }

  remove(clientId: string): OutboxEntry | undefined {
    const index = this.#entries.findIndex((e) => e.clientId === clientId);
    if (index === -1) return undefined;
    const [entry] = this.#entries.splice(index, 1);
    this.#persist();
    return entry;
  }

  setState(state: ResumeState): void {
    const prev = this.#state;
    this.#state = state;
    if (
      !prev ||
      prev.conversationId !== state.conversationId ||
      prev.userId !== state.userId ||
      prev.watermark !== state.watermark
    ) {
      this.#persist();
    }
  }

  /** Forget everything stored for this conversation. */
  async clear(): Promise<void> {
    this.#entries = [];
    this.#state = undefined;
    if (this.#key === null) return;
    const key = this.#key;
    await this.#writing;
    try {
      await this.#storage.removeItem(key);
    } catch (error) {
      this.#onError(error);
    }
  }

  /** Resolves once every pending write has reached the storage. */
  flush(): Promise<void> {
    return this.#writing;
  }

  // Writes are serialised so an older snapshot never overwrites a newer one.
  #persist(): void {
    if (this.#key === null) return;
    const key = this.#key;
    const snapshot: Persisted = { v: 1, outbox: this.#entries };
    if (this.#state) snapshot.state = this.#state;
    const value = JSON.stringify(snapshot);
    this.#writing = this.#writing.then(async () => {
      try {
        await this.#storage.setItem(key, value);
      } catch (error) {
        this.#onError(error);
      }
    });
  }
}
