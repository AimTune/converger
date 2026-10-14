/**
 * A minimal typed event emitter, so the SDK has no runtime dependencies
 * and works the same in browsers, Node and React Native.
 *
 * @module
 */

/** A map of event name to listener argument. */
export type EventMap = Record<string, unknown>;

/** A listener for one event. */
export type Listener<T> = (payload: T) => void;

/** Typed `on` / `once` / `off` / `emit`. Listener errors never break the emitter. */
export class TypedEmitter<Events extends EventMap> {
  readonly #listeners = new Map<keyof Events, Set<Listener<never>>>();
  #onListenerError: ((error: unknown) => void) | undefined;

  /** Subscribe; returns a function that unsubscribes. */
  on<K extends keyof Events>(event: K, listener: Listener<Events[K]>): () => void {
    let set = this.#listeners.get(event);
    if (!set) {
      set = new Set();
      this.#listeners.set(event, set);
    }
    set.add(listener as Listener<never>);
    return () => this.off(event, listener);
  }

  /** Subscribe for the next event only. */
  once<K extends keyof Events>(event: K, listener: Listener<Events[K]>): () => void {
    const off = this.on(event, (payload) => {
      off();
      listener(payload);
    });
    return off;
  }

  off<K extends keyof Events>(event: K, listener: Listener<Events[K]>): void {
    this.#listeners.get(event)?.delete(listener as Listener<never>);
  }

  /** Remove every listener (of one event, or all). */
  removeAllListeners(event?: keyof Events): void {
    if (event === undefined) this.#listeners.clear();
    else this.#listeners.delete(event);
  }

  /** @internal */
  protected setListenerErrorHandler(handler: (error: unknown) => void): void {
    this.#onListenerError = handler;
  }

  /** @internal */
  protected emit<K extends keyof Events>(event: K, payload: Events[K]): void {
    const set = this.#listeners.get(event);
    if (!set) return;
    for (const listener of [...set]) {
      try {
        (listener as Listener<Events[K]>)(payload);
      } catch (error) {
        // A throwing listener must not stop the agent; report it instead.
        if (this.#onListenerError) this.#onListenerError(error);
        else queueMicrotask(() => {
          throw error;
        });
      }
    }
  }
}
