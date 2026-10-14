/**
 * GenUIComponentCache — the client half of the component-catalog handshake.
 *
 * A server-defined catalog is markup, not code, and it rarely changes: re-sending
 * every component on every reconnect wastes the first frames of every session. So
 * the catalog is versioned by an opaque hash the *server* mints — an ETag:
 *
 * 1. The client stores `{ hash, components }` after the first catalog.
 * 2. On the next connect it sends the stored hash in the handshake
 *    (`hello.componentsHash`).
 * 3. The server compares. Same hash → it answers `{ unchanged: true }` and sends
 *    no markup; different (or missing) → it sends the full catalog and its hash.
 *
 * The client never computes the hash, so the server is free to derive it however
 * it likes (SHA-256 of the serialized catalog, a build id, a content version).
 * The client only has to hand back exactly what it was given.
 *
 * Cached components are published as soon as the connector connects, so a
 * returning user's widgets render without waiting for a round trip.
 *
 * No external dependencies allowed in this file — storage is injected, and the
 * default is looked up lazily so this stays importable outside a browser.
 */

import type { GenUIComponentDefinition } from "./GenUI";

/** The slice of the Web Storage API the cache needs. */
export interface GenUIComponentCacheStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

/** What one cache entry holds. */
export interface CachedGenUIComponents {
  /** The server-minted catalog hash this entry was stored under. */
  hash: string;
  components: GenUIComponentDefinition[];
}

export interface GenUIComponentCacheOptions {
  /**
   * Distinguishes catalogs that must not be mixed up — pass the server URL, so
   * staging and production don't hand each other's markup back.
   */
  namespace: string;
  /** Defaults to `globalThis.localStorage` when available. */
  storage?: GenUIComponentCacheStorage;
}

export interface GenUIComponentCache {
  /** The cached catalog, or null when there is none / it is unreadable. */
  load(): CachedGenUIComponents | null;
  /** The cached hash to send in the handshake, or undefined when nothing is cached. */
  hash(): string | undefined;
  /** Replace the cached catalog. A falsy hash clears the entry instead. */
  save(hash: string, components: GenUIComponentDefinition[]): void;
  /** Drop the entry. */
  clear(): void;
}

function defaultStorage(): GenUIComponentCacheStorage | null {
  try {
    const ls = (globalThis as { localStorage?: GenUIComponentCacheStorage }).localStorage;
    return ls ?? null;
  } catch {
    // Storage access can throw outright (blocked third-party cookies, some
    // privacy modes). No cache is a slow path, not a broken one.
    return null;
  }
}

/**
 * Create a catalog cache.
 *
 * Every operation swallows storage errors: a full quota or a blocked origin
 * costs a round trip, and must never break the connection.
 *
 * @example
 * ```ts
 * const cache = createGenUIComponentCache({ namespace: options.url });
 * // on connect
 * const cached = cache.load();
 * if (cached) onGenUIComponents(cached.components);
 * ws.send(JSON.stringify({ type: "hello", componentsHash: cache.hash() }));
 * // on { type: "genui_components", hash, components }
 * cache.save(hash, components);
 * ```
 */
export function createGenUIComponentCache(
  options: GenUIComponentCacheOptions
): GenUIComponentCache {
  const key = `chativa:genui-components:${options.namespace}`;
  const store = () => options.storage ?? defaultStorage();

  const load = (): CachedGenUIComponents | null => {
    try {
      const raw = store()?.getItem(key);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as Partial<CachedGenUIComponents>;
      if (typeof parsed?.hash !== "string" || !Array.isArray(parsed.components)) return null;
      // A stored entry is only as trustworthy as its shape — a half-written or
      // hand-edited entry must not reach the renderer.
      const components = parsed.components.filter(
        (d): d is GenUIComponentDefinition =>
          !!d && typeof d.name === "string" && typeof d.template === "string"
      );
      return { hash: parsed.hash, components };
    } catch {
      return null;
    }
  };

  return {
    load,
    hash: () => load()?.hash,
    save(hash, components) {
      try {
        if (!hash) return this.clear();
        store()?.setItem(key, JSON.stringify({ hash, components }));
      } catch {
        /* quota or blocked storage — the catalog just gets re-sent next time */
      }
    },
    clear() {
      try {
        store()?.removeItem(key);
      } catch {
        /* ignore */
      }
    },
  };
}
