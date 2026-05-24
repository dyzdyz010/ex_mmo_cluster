export interface MovementProfile {
  fixedDtMs: number;
  maxSpeed: number;
  maxAccel: number;
  maxDecel: number;
  maxJerk: number;
  jumpImpulse: number;
  gravity: number;
  airControl: number;
  airAccel: number;
  maxFallSpeed: number;
}

// Phase A2 (real-world scale) 同步:client predictor 必须跟 server 端
// SceneServer.Movement.Profile.default/0 / movement_core profile.rs 完全一致,
// 否则 client predict 跟 server authoritative state 跑出不同步度,
// 每个 ack(100ms)触发 reconcile correction snap,视觉上看到角色被
// "拉着走",误以为是网络延迟。
//
// 任何这里数值改动都必须同步:
//   - apps/scene_server/lib/scene_server/movement/profile.ex
//   - apps/scene_server/native/movement_core/src/profile.rs
export const DEFAULT_MOVEMENT_PROFILE: MovementProfile = {
  fixedDtMs: 100,
  maxSpeed: 600,
  maxAccel: 3300,
  maxDecel: 3800,
  maxJerk: 24_500,
  jumpImpulse: 900,
  gravity: 980,
  airControl: 0.35,
  airAccel: 1140,
  maxFallSpeed: 5300,
};
