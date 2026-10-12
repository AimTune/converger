/**
 * Pluggable key-value storage for the outbox and the resume state.
 *
 * Browsers default to `localStorage`; Node, React Native and anything without
 * a usable `localStorage` fall back to memory. Pass your own adapter (for
 * example over React Native's AsyncStorage or a file) to persist elsewhere;
 * every method may return a promise.
 *
 * @module
 */

/** A string key-value store. Methods may be synchronous or asynchronous. */
export interface KeyValueStorage {
  getItem(key: string): string | null | Promise<string | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem(key: string): void | Promise<void>;
}

/** In-memory storage: survives reconnects, not process restarts or reloads. */
export class MemoryStorage implements KeyValueStorage {
  readonly #items = new Map<string, string>();

  getItem(key: string): string | null {
    return this.#items.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.#items.set(key, value);
  }

  removeItem(key: string): void {
    this.#items.delete(key);
  }
}

/** The part of the Web Storage API the {@link WebStorage} adapter uses. */
export interface WebStorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

/** Adapter over a Web Storage object (`localStorage`, `sessionStorage`). */
export class WebStorage implements KeyValueStorage {
  readonly #storage: WebStorageLike;

  constructor(storage: WebStorageLike) {
    this.#storage = storage;
  }

  getItem(key: string): string | null {
    return this.#storage.getItem(key);
  }

  setItem(key: string, value: string): void {
    this.#storage.setItem(key, value);
  }

  removeItem(key: string): void {
    this.#storage.removeItem(key);
  }
}

/**
 * `localStorage` when running in a browser and it works (private modes may
 * throw), otherwise a fresh {@link MemoryStorage}. Node is always memory:
 * its experimental `localStorage` needs a file and prints warnings.
 */
export function defaultStorage(): KeyValueStorage {
  const g = globalThis as { window?: unknown; document?: unknown; localStorage?: WebStorageLike };
  if (typeof g.window === "undefined" || typeof g.document === "undefined") {
    return new MemoryStorage();
  }
  try {
    const ls = g.localStorage;
    if (!ls) return new MemoryStorage();
    const probe = "__converger_probe__";
    ls.setItem(probe, "1");
    ls.removeItem(probe);
    return new WebStorage(ls);
  } catch {
    return new MemoryStorage();
  }
}
