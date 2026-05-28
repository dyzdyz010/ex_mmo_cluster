import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Vector3 } from "three";
import { LocalPlayerController } from "./localPlayerController";
import { EventBus } from "../../shared/events/eventBus";
import { MovementMode, CorrectionFlag, type MovementAck } from "@domain/movement/types";
import { MAX_REMOTE_EXTRAPOLATION_SECS } from "@domain/movement/remotePlayer";

/**
 * 回归测试（bug: 服务端/权威方块匀速时越拉越远、异常快）。
 *
 * 根因：authority 方块（authorityAvatar）的渲染原先走 LocalPlayerController 自制的
 * 无约束运动学外推（pos + v·dt + ½a·dt²，dt = now − 最近 ack 到达时刻，上限 1.5s、
 * 无 maxSpeed 钳制）。一旦后端 ack 流抖动/中断（dt 增大），authority 方块就按旧速度
 * 持续前冲，最多漂移 maxSpeed × 1.5s = 900cm（9 米），而 local 方块静止/正常 —— 即
 * "匀速也越拉越远"。
 *
 * 修复：authority 渲染改用与"显示其他玩家"完全相同的 RemotePlayerState 管线
 * （服务端 tick 时间轴 + Hermite 插值 + 限幅 0.6s 外推），喂入 ack 原始权威态。
 *
 * 本测试锁死修复后的契约：ack 中断时外推被限幅在 maxSpeed × 0.6s = 360cm 内，
 * 不允许退回到无约束的 1.5s/900cm 失控。
 */

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
    serverSendMs: 0,
    position: new Vector3(0, 0, 0),
    velocity: new Vector3(velocityX, 0, 0),
    acceleration: new Vector3(0, 0, 0),
    movementMode: MovementMode.Grounded,
    groundY: 0,
    correctionFlags: CorrectionFlag.Teleport,
    serverFixedDtMs: 100,
  };
}

describe("LocalPlayerController authority-render 外推限幅（回归：服务端方块不再越拉越远）", () => {
  let now = 0;

  beforeEach(() => {
    now = 10_000;
    vi.spyOn(performance, "now").mockImplementation(() => now);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("ack 流中断时 authority 外推被限幅在 maxSpeed×0.6s=360cm 内（不再无约束冲 9 米）", () => {
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

    const samples = [0, 100, 500, 600, 1000, 1500, 3000].map((delayMs) => ({
      delayMs,
      authorityX: ctrl.getAuthoritativeRenderPosition(ackArrivalMs + delayMs).x,
    }));
    console.log(
      "[authority-render after fix]",
      JSON.stringify(samples.map((s) => ({ ...s, authorityX: Math.round(s.authorityX) }))),
    );

    const at = (ms: number) => samples.find((s) => s.delayMs === ms)!.authorityX;

    // 0.6s 之内线性外推
    expect(at(100)).toBeCloseTo(60, 0);
    expect(at(600)).toBeCloseTo(360, 0);
    // 0.6s 之后封顶，不再继续前冲（关键：旧实现这里会冲到 600/900cm）
    expect(at(1000)).toBeCloseTo(360, 0);
    expect(at(3000)).toBeCloseTo(360, 0);

    // 回归保护：authority 最大漂移绝不能超过 maxSpeed × MAX_REMOTE_EXTRAPOLATION_SECS。
    const cap = 600 * MAX_REMOTE_EXTRAPOLATION_SECS; // 360cm
    const maxDrift = Math.max(...samples.map((s) => s.authorityX));
    expect(maxDrift).toBeLessThanOrEqual(cap + 1e-6);
  });

  it("稳态 ack 准时（100ms 内）时 authority 外推量很小（≤60cm，半拍量级）", () => {
    const bus = new EventBus<Record<string, unknown>>();
    const ctrl = new LocalPlayerController(
      bus as never,
      makeStillInput() as never,
      makeReadyTransport() as never,
      new Vector3(0, 0, 0),
    );
    const ackArrivalMs = now;
    bus.emit("transport:ack-delivered", { ack: makeMovingAck(600), sentAtMs: ackArrivalMs });

    expect(ctrl.getAuthoritativeRenderPosition(ackArrivalMs + 100).x).toBeLessThanOrEqual(60.001);
  });
});
