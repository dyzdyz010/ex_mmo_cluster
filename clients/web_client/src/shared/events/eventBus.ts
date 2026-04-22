export type EventMap = Record<string, unknown>;

export type Listener<T> = (payload: T) => void;
export type Unsubscribe = () => void;

export interface ReadonlyEventBus<Events extends EventMap> {
  on<K extends keyof Events>(event: K, listener: Listener<Events[K]>): Unsubscribe;
  once<K extends keyof Events>(event: K, listener: Listener<Events[K]>): Unsubscribe;
  off<K extends keyof Events>(event: K, listener: Listener<Events[K]>): void;
}

export class EventBus<Events extends EventMap> implements ReadonlyEventBus<Events> {
  private readonly listeners = new Map<keyof Events, Set<Listener<unknown>>>();

  on<K extends keyof Events>(event: K, listener: Listener<Events[K]>): Unsubscribe {
    let bucket = this.listeners.get(event);
    if (!bucket) {
      bucket = new Set();
      this.listeners.set(event, bucket);
    }
    bucket.add(listener as Listener<unknown>);
    return () => this.off(event, listener);
  }

  once<K extends keyof Events>(event: K, listener: Listener<Events[K]>): Unsubscribe {
    const off = this.on(event, (payload) => {
      off();
      listener(payload);
    });
    return off;
  }

  off<K extends keyof Events>(event: K, listener: Listener<Events[K]>): void {
    const bucket = this.listeners.get(event);
    if (!bucket) return;
    bucket.delete(listener as Listener<unknown>);
    if (bucket.size === 0) this.listeners.delete(event);
  }

  emit<K extends keyof Events>(event: K, payload: Events[K]): void {
    const bucket = this.listeners.get(event);
    if (!bucket) return;
    for (const listener of [...bucket]) {
      try {
        (listener as Listener<Events[K]>)(payload);
      } catch (err) {
        // One broken listener must not silence the rest of the bus.
        console.error(`[EventBus] listener for ${String(event)} threw`, err);
      }
    }
  }

  listenerCount<K extends keyof Events>(event: K): number {
    return this.listeners.get(event)?.size ?? 0;
  }

  clear(): void {
    this.listeners.clear();
  }
}
