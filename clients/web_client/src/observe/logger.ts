export type ObserveFieldValue = string | number | boolean | null;

export interface ObserveEvent {
  seq: number;
  tsMs: number;
  category: string;
  event: string;
  fields: Record<string, ObserveFieldValue>;
}

const OBSERVE_PERSIST_KEY = "ex_mmo_web_client.observe";

function normalizeFields(fields: Record<string, ObserveFieldValue>): Record<string, ObserveFieldValue> {
  const entries = Object.entries(fields).sort(([a], [b]) => a.localeCompare(b));
  return Object.fromEntries(entries);
}

export function formatObserveEvent(entry: ObserveEvent): string {
  const head = `voxel_observe seq=${entry.seq} ts_ms=${entry.tsMs} category=${entry.category} event=${entry.event}`;
  const parts = Object.entries(entry.fields).map(([key, value]) => `${key}=${JSON.stringify(value)}`);
  return [head, ...parts].join(" ");
}

export class ObserveLog {
  private readonly events: ObserveEvent[] = [];
  private nextSeq = 1;

  constructor(private readonly capacity: number = 800) {}

  emit(category: string, event: string, fields: Record<string, ObserveFieldValue> = {}): ObserveEvent {
    const entry: ObserveEvent = {
      seq: this.nextSeq,
      tsMs: Math.round(performance.now()),
      category,
      event,
      fields: normalizeFields(fields),
    };
    this.nextSeq += 1;

    this.events.push(entry);
    if (this.events.length > this.capacity) {
      this.events.splice(0, this.events.length - this.capacity);
    }

    console.info(formatObserveEvent(entry));
    this.persist();
    return entry;
  }

  recent(limit: number = 40): ObserveEvent[] {
    return this.events.slice(-Math.max(0, limit));
  }

  snapshot(): ObserveEvent[] {
    return [...this.events];
  }

  clear(): void {
    this.events.splice(0, this.events.length);
    this.persist();
  }

  private persist(): void {
    try {
      localStorage.setItem(OBSERVE_PERSIST_KEY, JSON.stringify(this.events.slice(-200)));
    } catch {
      // 浏览器存储不是主流程，不让它影响运行时。
    }
  }
}
