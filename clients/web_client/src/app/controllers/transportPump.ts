import type { Vector3 } from "three";
import type { MoveInputFrame } from "@domain/movement/types";
import type { MovementTransport } from "@domain/movement/transport";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FrameSubscriber } from "../gameLoop";

/**
 * Owns the MovementTransport and bridges its frame-level API to the event bus.
 *
 * Discrete outputs (acks, remote snapshots, spawn, mode changes) are fanned out
 * as events. Inputs go through `sendInput`. Per-frame state (readiness, mode,
 * debug snapshot) is exposed via typed providers for HUD/CLI consumption.
 */
export class TransportPump implements FrameSubscriber {
  private lastMode: string;

  constructor(
    private readonly transport: MovementTransport,
    private readonly bus: EventBus<AppEvents>,
  ) {
    this.lastMode = transport.mode;
  }

  getMode(): string {
    return this.transport.mode;
  }

  isReady(): boolean {
    return this.transport.isReady();
  }

  debugSnapshot(): Record<string, unknown> {
    return this.transport.debugSnapshot();
  }

  sendInput(frame: MoveInputFrame, nowMs: number): void {
    this.transport.sendInput(frame, nowMs);
  }

  reset(position: Vector3): void {
    this.transport.reset(position);
    this.publishModeIfChanged();
  }

  onFrame(nowMs: number, dtMs: number): void {
    const result = this.transport.tick(nowMs, dtMs);
    this.publishModeIfChanged();

    if (result.spawn) {
      this.bus.emit("transport:spawn", {
        position: result.spawn.position,
        expectedSeq: result.spawn.expectedSeq,
      });
    }
    for (const delivered of result.acknowledgements) {
      this.bus.emit("transport:ack-delivered", {
        ack: delivered.ack,
        sentAtMs: delivered.sentAtMs,
      });
    }
    for (const snapshot of result.remoteSnapshots) {
      this.bus.emit("transport:snapshot-delivered", { snapshot });
    }
  }

  private publishModeIfChanged(): void {
    const current = this.transport.mode;
    if (current !== this.lastMode) {
      this.lastMode = current;
      this.bus.emit("transport:mode-changed", { mode: current });
    }
  }
}
