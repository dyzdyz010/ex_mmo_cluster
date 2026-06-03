import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Vector3 } from "three";
import { LocalPlayerController } from "./localPlayerController";
import { EventBus } from "../../shared/events/eventBus";
import { MovementMode, CorrectionFlag, type MovementAck } from "@domain/movement/types";
import { DEFAULT_MOVEMENT_PROFILE } from "@domain/movement/profile";

const AUTHORITY_PROJECTION_CLAMP_MS = DEFAULT_MOVEMENT_PROFILE.fixedDtMs * 2;

function makeStillInput() {
  return {
    getMovementKeys: () => ({ forward: false, backward: false, left: false, right: false }),
    getVirtualMovement: () => ({ x: 0, y: 0 }),
    hasPendingJump: () => false,
    consumeJumpPressed: () => false,
    requestJump: () => {},
  };
}

function makeReadyTransport() {
  return { isReady: () => true, sendInput: () => {} };
}

/** 模拟服务端最后一次 ack：玩家以 velocityX cm/s 沿 +x 移动。Teleport flag 让权威
 *  快照立即生效（清空旧缓冲后入队）。*/
function makeMovingAck(velocityX: number): MovementAck {
  return {
    ackSeq: 1,
    authTick: 1,
    serverStateMs: 0,
    serverSendMs: 0,
    position: new Vector3(0, 0, 0),
    velocity: new Vector3(velocityX, 0, 0),
    acceleration: new Vector3(0, 0, 0),
    movementMode: MovementMode.Grounded,
    groundY: 0,
    correctionFlags: CorrectionFlag.Teleport,
    serverFixedDtMs: DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
  };
}

function makeAuthorityAck(
  authTick: number,
  serverStateMs: number,
  positionX: number,
  velocityX = 1_000,
): MovementAck {
  return {
    ackSeq: authTick,
    authTick,
    serverStateMs,
    serverSendMs: serverStateMs + 20,
    position: new Vector3(positionX, 0, 0),
    velocity: new Vector3(velocityX, 0, 0),
    acceleration: new Vector3(0, 0, 0),
    movementMode: MovementMode.Grounded,
    groundY: 0,
    correctionFlags: authTick === 1_000 ? CorrectionFlag.Teleport : CorrectionFlag.None,
    serverFixedDtMs: DEFAULT_MOVEMENT_PROFILE.fixedDtMs,
  };
}

describe("LocalPlayerController latest-ack authority projection", () => {
  let now = 0;

  beforeEach(() => {
    now = 10_000;
    vi.spyOn(performance, "now").mockImplementation(() => now);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("clamps authority projection to roughly 2 server fixed ticks", () => {
    const bus = new EventBus<Record<string, unknown>>();
    const ctrl = new LocalPlayerController(
      bus as never,
      makeStillInput() as never,
      makeReadyTransport() as never,
      new Vector3(0, 0, 0),
    );

    // 服务端最后一次 ack：600 cm/s（= maxSpeed）沿 +x。此后 ack 中断。
    const ackArrivalMs = now;
    bus.emit("transport:ack-delivered", {
      ack: makeMovingAck(600),
      sentAtMs: ackArrivalMs,
    });

    // local 方块：没有持续输入 → 静止。
    expect(ctrl.getRenderedPosition().x).toBeCloseTo(0, 1);

    const samples = [0, 8, 16, 32, 64, 250].map((delayMs) => ({
      delayMs,
      authorityX: ctrl.getAuthoritativeProjectedPosition(ackArrivalMs + delayMs).x,
    }));

    const at = (ms: number) => samples.find((s) => s.delayMs === ms)!.authorityX;

    expect(at(8)).toBeCloseTo(4.8, 4);
    expect(at(16)).toBeCloseTo(9.6, 4);
    expect(at(32)).toBeCloseTo(19.2, 4);
    expect(at(64)).toBeCloseTo(19.2, 4);
    expect(at(250)).toBeCloseTo(19.2, 4);

    const cap = 600 * (AUTHORITY_PROJECTION_CLAMP_MS / 1000);
    const maxDrift = Math.max(...samples.map((s) => s.authorityX));
    expect(maxDrift).toBeLessThanOrEqual(cap + 1e-6);
  });

  it("uses ack acceleration in the projected authority sample", () => {
    const bus = new EventBus<Record<string, unknown>>();
    const ctrl = new LocalPlayerController(
      bus as never,
      makeStillInput() as never,
      makeReadyTransport() as never,
      new Vector3(0, 0, 0),
    );
    const ackArrivalMs = now;
    bus.emit("transport:ack-delivered", {
      ack: {
        ...makeMovingAck(0),
        acceleration: new Vector3(1_000, 0, 0),
      },
      sentAtMs: ackArrivalMs,
    });

    expect(ctrl.getAuthoritativeProjectedPosition(ackArrivalMs + 16).x).toBeCloseTo(0.128, 4);
  });

  it("projects local authority on the synced server_state_ms clock when TimeSync is available", () => {
    vi.spyOn(Date, "now").mockReturnValue(1_999_700);
    const bus = new EventBus<Record<string, unknown>>();
    const ctrl = new LocalPlayerController(
      bus as never,
      makeStillInput() as never,
      makeReadyTransport() as never,
      new Vector3(0, 0, 0),
    );

    bus.emit("transport:time-sync", {
      requestId: 1,
      clientSendTs: 1_999_600,
      serverRecvTs: 2_000_100,
      serverSendTs: 2_000_200,
    });
    bus.emit("transport:ack-delivered", {
      ack: makeAuthorityAck(1_000, 2_000_000, 0, 600),
      sentAtMs: now,
    });

    expect(ctrl.getAuthoritativeProjectedPosition(now).x).toBeCloseTo(120, 4);
    expect(ctrl.getAuthorityRenderDebugSnapshot()).toMatchObject({
      interpolationTimeAxis: "server_state_ms",
      playbackServerTimeMs: 2_000_200,
      serverClockOffsetMs: 500,
    });
  });

  it("keeps raw authoritative ack position separate from projected authority", () => {
    now = 10_000;
    const bus = new EventBus<Record<string, unknown>>();
    const ctrl = new LocalPlayerController(
      bus as never,
      makeStillInput() as never,
      makeReadyTransport() as never,
      new Vector3(0, 0, 0),
    );

    bus.emit("transport:ack-delivered", {
      ack: makeAuthorityAck(1_000, 2_000_000, 0, 600),
      sentAtMs: now,
    });
    now = 10_250;

    expect(ctrl.getAuthoritativePosition().x).toBe(0);
    expect(ctrl.getAuthoritativeProjectedPosition(now).x).toBeGreaterThan(0);
    expect(ctrl.getAuthorityRenderDebugSnapshot()).toMatchObject({
      bufferedSnapshots: 1,
      interpolationMode: "extrapolated",
    });
  });
});
