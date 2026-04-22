import { Vector3 } from "three";
import { INTERPOLATION_DELAY_SECS, RemotePlayerState } from "@domain/movement/remotePlayer";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import type { FrameSubscriber } from "../gameLoop";

const DEFAULT_REMOTE_POSITION = new Vector3(400, 650, 320);

/**
 * Owns the remote-player interpolation buffer. Ingests server snapshots via
 * bus events and samples the current visual position on every frame.
 */
export class RemotePlayerController implements FrameSubscriber {
  static readonly interpolationDelaySecs = INTERPOLATION_DELAY_SECS;

  private readonly state = new RemotePlayerState();
  private readonly renderedPosition = DEFAULT_REMOTE_POSITION.clone();

  constructor(private readonly bus: EventBus<AppEvents>) {
    this.bus.on("transport:snapshot-delivered", ({ snapshot }) => {
      this.state.pushSnapshot(snapshot, 0, performance.now() / 1000);
      this.bus.emit("movement:remote-snapshot-ingested", {
        cid: snapshot.cid,
        serverTick: snapshot.serverTick,
        position: snapshot.position,
      });
    });
    this.bus.on("transport:spawn", () => {
      this.renderedPosition.copy(DEFAULT_REMOTE_POSITION);
    });
  }

  onFrame(nowMs: number, _dtMs: number): void {
    const sample = this.state.sampleMotion(nowMs / 1000);
    this.renderedPosition.copy(sample.position);
  }

  getRenderedPosition(): Vector3 {
    return this.renderedPosition;
  }
}
