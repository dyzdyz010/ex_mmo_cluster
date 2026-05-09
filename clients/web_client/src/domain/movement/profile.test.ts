import { DEFAULT_MOVEMENT_PROFILE } from "./profile";

describe("DEFAULT_MOVEMENT_PROFILE", () => {
  it("matches the authoritative SceneServer movement defaults (Phase A2)", () => {
    // 必须跟 apps/scene_server/lib/scene_server/movement/profile.ex
    // 跟 apps/scene_server/native/movement_core/src/profile.rs 三处保持一致。
    // 任何一处不同步都会让 client predict / server authoritative 跑出
    // 跟 fixed_dt_ms 同周期的 reconcile snap(每 100ms 一次玩家被向前/
    // 向后拽),用户体感 = "网络延迟"。
    expect(DEFAULT_MOVEMENT_PROFILE).toEqual({
      fixedDtMs: 100,
      maxSpeed: 600,
      maxAccel: 3300,
      maxDecel: 3800,
      maxJerk: 24_500,
      jumpImpulse: 485,
      gravity: 980,
      airControl: 0.35,
      airAccel: 1140,
      maxFallSpeed: 5300,
    });
  });
});
