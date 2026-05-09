# Phase A2 — 尺寸真实化 (real-world scale)

**起草日期**:2026-05-08。**状态**:决策稿(待用户审)。

阶段 A(可玩 demo 最低线)的第一子阶段。在 A1(移动 + 跳跃同步)/ A3(多客户端联调)之前先把世界尺度对齐到现实数值,后续物理调参不必重做一轮。

A1 / A3 决策稿等本稿落地后再起草。

## 阶段目标

让"角色 1.7m,1 macro = 1m"的尺度从注释里的口头约定变成代码里所有相关常量都对得上的约定。同时顺手修一个 latent 单位 bug(scene_ops collider)。

具体收益:

1. 路演 demo 里角色看起来不再像"小矮人"(从 1.2m 提到 1.7m)
2. 跳跃 / 跑速 / 终端速度 / 重力都是现实人体范围,A1 服务端跳跃同步 / 客户端预测的物理参数不会因 A2 重调而废
3. 移除 scene_ops `capsule_z(0.3, 0.15)` 米/cm 单位混用的 latent bug

## 范围

### 在范围

- web_client 角色 mesh 尺寸 / 半高常量
- web_client 相机距离 / LOOK_HEIGHT 调整
- scene_server `SceneServer.Movement.Profile.default/0` 物理参数(同步 movement_core `MovementProfile::default`)
- `scene_ops/character/physics_comp.rs` capsule 尺寸单位修正
- 受影响 tests 重生成 / 调整(主要是 movement integrator golden + spawn.test)

### 不在范围

- A1 跳跃同步 / 客户端垂直速度预测和解(下一个子阶段)
- A3 多客户端联调(再下一子阶段)
- 改世界单位语义(继续保持 1 unit = 1 cm,1 macro = 100 unit = 1m)
- scene_ops physics_comp.rs 路径替换 / 跟 movement_core 收敛(那是 Phase 5+ 范围)
- chunk mesher / chunkRenderer 尺度逻辑(都是 MacroWorldSize 相对量,不变)
- HUD / debris 粒子尺寸(粒子已经是 0.05m * MacroWorldSize 相对量,不变)

## 决策项

每项给推荐值。请用户审,可以全收 / 部分驳回 / 改细节,确认后才写代码。

### D1. 世界单位约定

**保 1 unit = 1 cm,MacroWorldSize = 100 不变**。

理由:
- 全代码已对齐 cm,改 SI(米)涉及 chunk render / chunk mesher / spawn / 物理 profile / debris / camera 全部数值,工作量是 A2 当前估算的 5-10 倍
- Unreal Engine 默认也是 1 unit = 1 cm,业界惯例
- 用户原文"尺寸真实化(1m=宏格,角色 1.7m)"两条都不要求改单位 — `1 macro = 100 unit = 100 cm = 1 m` 已经满足"1m=宏格"

**推荐:采纳**。

### D2. 角色尺寸常量集中

引入新常量,避免散落 magic number(60 / 70 / 120 / 50 / 90 / 170 / 190 等)。

新增到 `clients/web_client/src/voxel/core/constants.ts`:

```ts
export const AvatarConstants = {
  HeightCm: 170,        // 1.7m 全高
  HalfHeightCm: 85,
  WidthCm: 50,          // 0.5m 肩宽 / 厚度(box mesh)
  CapsuleRadiusCm: 30,  // 0.3m 直径(用于 collider / 远端 ring 半径推导)
} as const;
```

旧硬编码替换:

| 文件:行 | 旧值 | 新值 |
|---|---|---|
| `app/spawn.ts:4` `LOCAL_AVATAR_HALF_HEIGHT` | `60` | `AvatarConstants.HalfHeightCm` (= 85) |
| `app/controllers/renderOrchestrator.ts:62` localAvatar | `BoxGeometry(70, 120, 70)` | `BoxGeometry(50, 170, 50)` |
| 同上:65 authorityAvatar | `BoxGeometry(50, 90, 50)` | `BoxGeometry(35, 120, 35)` (透明 ghost,刻意比真身小一圈) |
| 同上:74 syncRing | `RingGeometry(170, 190, 48)` | `RingGeometry(120, 140, 48)` (压成 1.2m / 1.4m,刚好绕角色脚) |
| 同上:167-180 `groundActorPosition(..., 60, ...)` | `60` | `AvatarConstants.HalfHeightCm` |
| 同上:186 `syncRing.position.set(..., y - 59, ...)` | `59` | `AvatarConstants.HalfHeightCm - 1` |
| 同上:206 remote `groundActorPosition(..., 60, ...)` | `60` | `AvatarConstants.HalfHeightCm` |
| 同上:215 ensureRemoteAvatar | `BoxGeometry(70, 120, 70)` | `BoxGeometry(50, 170, 50)` |

**推荐:采纳**。所有 avatar 视觉元素从 1.2m 升到 1.7m。authorityAvatar(server-confirmed ghost)继续比 local 小一圈以保持视觉区分。

### D3. 相机参数

适配 1.7m 角色,LOOK_HEIGHT 从角色腰部上调到胸口高度,距离温和扩大让角色不挤镜头。

`clients/web_client/src/render/scene.ts`:

| 常量 | 旧 | 新 | 备注 |
|---|---|---|---|
| `CAMERA_LOOK_HEIGHT` | 110 (1.1m) | 145 (1.45m) | 1.7m 角色胸口 |
| `CAMERA_MIN_DISTANCE` | 180 (1.8m) | 200 (2m) | 防穿身 |
| `CAMERA_MAX_DISTANCE` | 620 (6.2m) | 800 (8m) | 远景拉宽,1.7m 角色才不会显得太空 |
| `CAMERA_SNAP_DISTANCE` | 600 | 700 | 跟 MAX 同步 |
| 第 80 行 `orbitDistance = 410` | 410 (4.1m) | 500 (5m) | 默认 follow 距离 |
| 第 73 行 `camera.position.set(..., 480, ...)` | 480 (4.8m) | 550 (5.5m) | 初始 y |
| 第 73-74 行 `camera.lookAt(0, 140, 0)` | 140 | 145 | 跟 LOOK_HEIGHT 同步 |

Fog 距离 / GridHelper 不动(都是 chunkExtent 相对量)。

**推荐:采纳**。如果 demo 实际看起来太远,后续微调 5%。

### D4. Movement profile 物理参数

把现实人体 / MMO 跑速参数对齐 1 cm 世界。这是 A2 改动里**唯一影响服务端 movement_engine 行为**的一组。

`apps/scene_server/lib/scene_server/movement/profile.ex` `default/0` + `apps/scene_server/native/movement_core/src/profile.rs` `Default for MovementProfile`(两处必须一致,有 golden test 在 `integrator_golden_test.exs`):

| 字段 | 旧 | 新 | 推导 |
|---|---|---|---|
| `max_speed` | 220 cm/s = 2.2 m/s | 600 cm/s = 6 m/s | MMO 跑速;Unreal CMC 默认 600(同单位) |
| `max_accel` | 1200 | 3300 | × (600/220) ≈ 2.7 |
| `max_decel` | 1400 | 3800 | × 2.7 |
| `max_jerk` | 9_000 | 24_500 | × 2.7 |
| `jump_impulse` | 420 | 485 | apex = v² / 2g = 485² / 1960 ≈ 120 cm = 1.2m |
| `gravity` | 980 (= 9.8 m/s²) | **不变** | 已符合现实 |
| `max_fall_speed` | 900 (= 9 m/s) | 5300 (= 53 m/s) | 人体 terminal velocity ≈ 53 m/s |
| `air_control` | 0.35 | **不变** | 现实人体 air control 比例,跟单位无关 |
| `air_accel` | 420 | 1140 | × 2.7,跟 max_accel 同比例 |
| `friction` | 0.0 | **不变** | 物理层处理 |
| `turn_response` | 1.0 | **不变** | 无量纲 |
| `fixed_dt_ms` | 100 | **不变** | tick 长度,跟尺度无关 |
| `max_speed_scale` | 1.0 | **不变** | scaler |

注释更新:profile.rs 第 28-30 行 "MMO walking baseline (7-8 m/s at 1 unit = 1 cm)" 现在应该说 "running baseline (6 m/s)"。第 51 行 "70 cm apex" 改 "120 cm apex"。

**推荐:整套采纳**。涉及 golden test 重生成 — `integrator_golden_test.exs` 几乎肯定要更新,接受。

**风险**:A1 真做服务端跳跃同步时,如果发现 1.2m apex 太高(看起来超人感),再调回 1.0m(`jump_impulse = 443`)。这是 A1 决策稿的事,A2 先用 1.2m。

### D5. scene_ops capsule 单位修正

`apps/scene_server/native/scene_ops/src/character/physics_comp.rs:23`:

```rust
// 旧
let collider = ColliderBuilder::capsule_z(0.3, 0.15)  // 米,与 cm 世界不对齐(latent bug)
// 新
let collider = ColliderBuilder::capsule_z(85.0, 30.0)  // cm,角色 1.7m 高、0.6m 直径
```

这条路径主 movement 不直接依赖 capsule 形状(走 movement_core 算位移),但 chunk 体素碰撞 / 未来重新启用 rapier character controller 时形状要对得上。

**推荐:采纳**。低风险,scene_ops 单测有几个会跑一次确认。

### D6. 测试影响范围与处理

| 测试 | 受影响 | 处理 |
|---|---|---|
| `apps/scene_server/test/scene_server/movement/integrator_golden_test.exs` | profile 数值改了,golden 几乎全废 | **重新生成 golden** |
| `apps/scene_server/test/scene_server/movement/integrator_test.exs` | 可能用硬编码速度 | 跟随 profile 默认值即可,看具体 assert |
| `apps/scene_server/native/movement_core/src/profile.rs::tests::default_matches_mmo_starter_tuning` | 旧值断言 | **更新为新值** |
| `apps/scene_server/bench/movement_bench.exs` / `bench/scene_load_bench.exs` | bench 不在 CI | 改不改都行,**推荐顺手改** |
| `clients/web_client/src/app/spawn.test.ts` | 用 `LOCAL_AVATAR_HALF_HEIGHT` 常量,自动跟随 | 不改 |
| `clients/web_client/src/render/chunkRenderer.test.ts` | 用 `MacroWorldSize` 相对量 | 不改 |
| `clients/web_client/src/voxel/meshing/chunkMesher.test.ts` | 同上 | 不改 |
| `clients/web_client/src/app/controllers/localPlayerController.test.ts:49-54` `spawn = Vector3(-350, 260, -280)` + `groundY: 260` | **已 verify(2026-05-09):260 跟 `LOCAL_AVATAR_HALF_HEIGHT` 无依赖**,只是测试自构造的随机 y;`-350` / `-280` 字面值跟 `DEFAULT_LOCAL_SPAWN_X/Z` 重复但没 import,属"看似耦合,实则解耦"反模式 | A2 不会因 half-height 改动失败 ✅;**Step A2-1 顺手清理**:第 49 行替换为 `new Vector3(0, 123, 0)`,显式跟源常量解耦,语义"任意 spawn,只验证 spawn.y → groundY 数据流" |

**推荐:接受 golden test 重生成**。重生成步骤就是把 fixture 跑一遍取 expected 值 commit。

## 风险

1. **Movement integrator 调参后 demo 体感变化**:跑速从 2.2 m/s 提到 6 m/s,可能感觉"飘";A1 阶段如果发现要回调,接受。
2. **Authority avatar 缩太小看不出 ghost 效果**:35×120×35 比 50×90×50 小;如果实测看不见,把 transparent opacity 从 0.35 提到 0.5。
3. **scene_ops capsule 改 cm 后 chunk 碰撞行为变化**:movement 主路径不依赖,但若有 npc / mob 路径依赖,可能出现卡墙;**A2 落地后跑一遍 scene_server 全量测试 verify**。
4. **远端 avatar 重构 BoxGeometry 时同时改尺寸**:test 里没断言尺寸,但视觉上联调时其它客户端立刻能看到对方变高。
5. **camera 距离扩大后 fog 远端 7800 可能切割角色**:Fog 起点 2200(2.2m),终点 7800(7.8m),角色 1.7m 不会被 fog 切;远景 fog 没动,OK。

## 步骤分解(commit 粒度)

每步独立 commit,Elixir 改前 `mix format`,web 改后 `npx tsc --noEmit && npx vitest run`。**不 push**。

| Step | 范围 | 验证 | 估时 |
|---|---|---|---|
| **A2-1** | web_client AvatarConstants 引入 + spawn.ts / renderOrchestrator avatar mesh 与 ring 尺寸更新(D2)+ 顺手清理 `localPlayerController.test.ts:49` 字面值耦合 | `npx tsc --noEmit && npx vitest run`(254 → 254,测试不变) | 0.5 天 |
| **A2-2** | web_client scene.ts 相机参数(D3) | 同上 | 0.5 天 |
| **A2-3** | scene_server profile.ex + movement_core profile.rs 默认值更新(D4) + 注释更新 | `mix test apps/scene_server/test`(整 359 套) — golden 失败先记录,Step A2-4 修 | 0.5 天 |
| **A2-4** | integrator_golden_test 重生成 + movement_core profile.rs 单测更新 + bench 顺手改 | `mix test apps/scene_server/test` 全绿 | 0.5 天 |
| **A2-5** | scene_ops physics_comp.rs capsule 单位修正(D5) | scene_server 全套 + 手工 cargo test scene_ops | 0.3 天 |
| **A2-6** | sweep:全仓 grep magic number(60/120/70/50/90/110/170/190/410/220/420/980/900),确认没有遗漏 | 全套测试一遍 + 手工 demo 一次 | 0.5 天 |
| **A2-final** | 决策稿状态改"已完成",README 阶段表加 A2 行,handoff 更新 | git status 干净 | 0.2 天 |

总估时:**2-3 天**(对齐用户原估 1-3 天)。

## 验收标准

- web vitest 254 pass(数量可调,如有新加测试)
- scene_server 359 → 359(数量可调,golden 重生成不增加测试数)
- gate_server 189、data_service 71、world_server 72(预存 1 fail)— 全部不动,数字一致
- 手工 demo:启 web_client + scene 节点,登录后:
  - 角色看起来 1.7m 高(不是矮胖小矮人)
  - 跑速感觉 ≈ "正常人慢跑",不是"散步"
  - 跳一下 apex ≈ 1.2m(2 个 macro 块 - 0.8 个)
  - 相机距离不挤角色不太空旷
  - 破坏方块碎屑粒子尺寸看起来跟 1.7m 角色比例正常

## 进度日志

- 2026-05-08:决策稿起草。
- 2026-05-09:用户审 D1-D6,采纳推荐值;补充 verify `localPlayerController.test.ts:54` 与 half-height 无依赖,Step A2-1 顺手清理字面值耦合;待 commit 决策稿入仓后开 Step A2-1。
