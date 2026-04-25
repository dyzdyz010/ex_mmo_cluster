# Bevy Client Restructure Design (2026-04-25)

## 1. 背景与目标

`clients/bevy_client/` 已经把网页端的 web-parity voxel/jump/prefab 功能搬到了 Bevy
端,但代码组织没跟上:

- `app.rs` 3161 行,容纳 components、resources、所有 SystemParam、所有 system
  函数(网络轮询、movement 采样、voxel 输入、HUD、相机轨道、effect、prefab
  guides 等)
- `voxel/mod.rs` 2230 行,把 core 类型、storage、prefab、boundary snap、CLI
  parser、内置 mask 都堆在一起
- `net.rs` 2508 行,thread loop / TCP / UDP fast-lane / codec / events 全在一
  起
- `headless.rs` 982 行,server-attached headless 与 voxel-only headless 与
  script 解析混居

后续要全面排查并修复用户已经观察到的 bug(相机、屏幕中心射线、视角相对移动、
movement uplink、prefab 摆放等),先要让代码具备:

1. Bevy 推荐的 Plugin 边界,system 与资源由领域 Plugin 拥有
2. Rust 工业级"纯逻辑模块 + ECS glue"分层,纯模块独立可测
3. 与网页端等价的概念分组(input controllers、voxel core/microgrid/prefab/
   storage、presentation/hud/devtools)

本设计稿仅描述重构,不修任何 bug。bug 修复留作下一个独立的 plan。

## 2. 范围与非范围

**Scope**:

- 拆分四个巨石: `app.rs`、`voxel/mod.rs`、`net.rs`、`headless.rs`
- 引入 `BevyClientPlugins` PluginGroup 与 `ClientSet` 调度集
- 引入领域 events(`VoxelEditEvent`、`HotbarSelectEvent`、`SkillCastEvent`、
  `ChatToggleEvent`、`ChatSendEvent`),取消 plugin 之间共享 `&mut Resource`
- 拆分 SystemParam 到各自 Plugin,system 函数 ≤ 60 行
- 拆出 `app/`、`input/`(扩 keyboard/mouse/chat/events)、`camera/`、
  `voxel/{core,world,prefab,...}`、`skill/`、`chat/`、`hud/`、`effects/`、
  `presentation/`、`net/{plugin,thread,transport,...}`、`stdio/`、`headless/`

**Non-scope**:

- 不修任何 bug(包括用户提到的相机、射线命中、视角相对移动、移动同步、prefab
  摆放等)
- 不动 `sim/`、`world/`、`movement.rs`、`auth_client.rs`、`config.rs`、
  `observe.rs`,这些尺寸合理边界清楚
- 不合并 `protocol.rs` / `protocol_v2.rs`(两者职责不同,合并属于另一个 net
  v3 设计)
- 不抽 `bevy_client_voxel` 子 crate;全部模块仍在 `bevy_client` 单 crate 内
- 不动 server / scene_server / Rust NIF / web client
- 系统未上线,**不维持向后兼容**:stdio 命令名、observe 字段、CLI flag、
  WorldSnapshot JSON 形态、env var 都可以在某 phase 末顺手改名,只要同步改
  README + docs

## 3. 架构总览

### 3.1 核心原则

1. `app::run` 是薄组合根。`App::new()` + `DefaultPlugins` + `LoginPlugin` +
   `BevyClientPlugins`,行数 ≤ 80。
2. 每个领域 Plugin 自带 resources、components、events、systems、startup 钩子。
   对外只暴露 events 和 read-only resource API。
3. 纯逻辑函数(voxel 算法、boundary snap、camera math、CLI parser)放纯模
   块,不 import `bevy::prelude::*`,只用 std + `glam`。ECS 系统函数做 glue,
   ≤ 60 行。
4. Plugin 之间通过 events 通信,不互相 `ResMut` 同一个 resource。
5. `ClientSet` 调度集统一系统执行顺序,所有 system 显式 `.in_set(...)`。

### 3.2 Plugin 清单

| Plugin | 拥有 resource / event | 调度集 |
| --- | --- | --- |
| `LoginPlugin`(已有) | `AppState`、`SessionCredentials` | `OnEnter(Login)` + Update Login UI |
| `NetworkPlugin` | `NetworkBridge`、`NetworkCommand` event、`NetworkEvent` event | `ClientSet::Network` |
| `StdioPlugin` | `ClientStdioInterface`、`poll_stdio_commands` | `ClientSet::Stdio` |
| `InputPlugin` | `MovementIntent`、`InputTraceState`、`VoxelEditEvent`、`HotbarSelectEvent`、`SkillCastEvent`、`ChatToggleEvent`、`ChatSendEvent` | `ClientSet::Input` |
| `CameraPlugin` | `OrbitCameraState`、`MainCamera` | `ClientSet::Input`(尾部) |
| `ChatPlugin` | `ChatState`、`ChatLogText`、`ChatInputText` | `ClientSet::Logic` |
| `VoxelPlugin` | `VoxelWorld`、`VoxelSelectionState`、`BoundarySnapPreview` | `ClientSet::Logic` |
| `SkillPlugin` | skill 选择/施放队列 | `ClientSet::Logic` |
| `MovementSyncPlugin` | `MovementTick`、`MovementDispatchState`、`LocalRenderPrediction` | `ClientSet::Sync` |
| `EffectPlugin` | `EffectVisual` 组件 | `ClientSet::Render` |
| `HudPlugin` | `HudText`、`update_hud_text` | `ClientSet::Render` |
| `PresentationPlugin` | `SceneRenderAssets`、`PlayerVisual`、`TargetPointMarker`、actor mesh/material 缓存、`sync_player_visuals`、selection guides | `ClientSet::Render` |
| `ObservePlugin`(轻量) | `ClientObserver` | `Startup` + `Last` |

### 3.3 调度顺序

```text
ClientSet::Network   → poll_network_events
ClientSet::Stdio     → poll_stdio_commands
ClientSet::Input     → keyboard / mouse / chat / camera orbit
ClientSet::Logic     → voxel / skill / chat send
ClientSet::Sync      → movement uplink + local render prediction
ClientSet::Render    → presentation / hud / effects / gizmos
```

`Update` 内 `ClientSet::Network.before(ClientSet::Stdio)`,依此类推。每个
system 用 `.in_set(...)` 而非 `.chain()` 显式声明属于哪一组。

## 4. 文件布局

### 4.1 目标目录

```text
clients/bevy_client/src/
├── lib.rs                 // re-export + BevyClientPlugins(PluginGroup)
├── main.rs                // 仅 parse args + 调用 app::run / headless::run
├── app/
│   ├── mod.rs             // run(config, observer, stdio, creds)
│   ├── plugins.rs         // BevyClientPlugins::build()
│   └── schedule.rs        // ClientSet 枚举与 set ordering
├── config.rs / login.rs / auth_client.rs (保留)
├── observe.rs             // 内部新增 ObservePlugin(就地定义,observe.rs 仍是单文件)
├── movement/
│   ├── mod.rs             // 现 movement.rs 内容
│   └── plugin.rs          // MovementSyncPlugin: MovementTick/MovementDispatchState/LocalRenderPrediction、movement_sender、advance_local_render_prediction
├── input/
│   ├── mod.rs / commands.rs (保留 commands.rs)
│   ├── plugin.rs          // InputPlugin
│   ├── keyboard.rs        // movement direction、jump、hotbar 数字键
│   ├── mouse.rs           // wheel、orbit drag、center-ray click
│   ├── chat.rs            // chat toggle/typing
│   └── events.rs          // VoxelEditEvent 等 input → logic 事件
├── camera/
│   ├── plugin.rs
│   ├── orbit.rs           // 纯函数: orbit math, ray_from_viewport
│   └── zoom.rs            // wheel→distance
├── voxel/
│   ├── mod.rs             // re-export
│   ├── plugin.rs          // VoxelPlugin
│   ├── core/
│   │   ├── mod.rs
│   │   ├── coord.rs       // MacroCoord、MicroCoord、bounds、index helpers
│   │   ├── material.rs    // VoxelMaterialId
│   │   └── mask.rs        // MicroMask + 集合运算
│   ├── world/
│   │   ├── mod.rs
│   │   ├── store.rs       // VoxelWorld、CellData、EditStats
│   │   ├── snapshot.rs    // WorldSnapshot import/export, save/load
│   │   └── hotbar.rs      // HotbarState、HotbarEntry、Kind
│   ├── prefab/
│   │   ├── mod.rs
│   │   ├── definition.rs  // PrefabDefinitionData / Cell / RasterCell / PartDefinition
│   │   ├── registry.rs    // LocalPrefabRegistry
│   │   ├── boundary.rs    // BoundarySnapRequest/Preview/PlaceResult + contact 算法
│   │   ├── builtins.rs    // sphere / cylinder / stairs mask
│   │   └── rotation.rs    // Rotation + rotate_*
│   ├── cli.rs             // VoxelCliCommand parse/execute
│   ├── render.rs          // sync_voxel_visuals + selection gizmos (ECS)
│   ├── selection.rs       // VoxelRaySelection、find_voxel_selection_from_ray
│   ├── input_systems.rs   // 把 VoxelEditEvent 翻成 VoxelWorld mutate
│   └── README.md(更新)
├── skill/
│   ├── plugin.rs
│   ├── targeting.rs       // 现 skill_targeting.rs 内容
│   └── input_systems.rs   // skill key、target picking、send_targeted_skill
├── chat/
│   ├── plugin.rs
│   └── state.rs           // ChatState + 事件
├── hud/
│   ├── plugin.rs
│   └── view.rs            // update_hud_text、push_line
├── effects/
│   ├── plugin.rs
│   ├── visuals.rs         // EffectVisual + spawn/update
│   └── colors.rs          // effect_color、effect_runtime_color、interpolation
├── presentation/
│   ├── mod.rs / animation.rs / smoothing.rs / camera.rs (保留)
│   ├── plugin.rs          // PresentationPlugin
│   ├── render.rs          // SceneRenderAssets、sync_player_visuals、actor_render_position
│   └── visual.rs          // PlayerVisual、TargetPointMarker components
├── world/                 // 保留(local_player/remote_player/remote_actor)
├── sim/                   // 保留
├── net/
│   ├── mod.rs
│   ├── plugin.rs          // NetworkPlugin: bridge、poll_network_events
│   ├── thread.rs          // spawn_network_thread loop
│   ├── transport.rs       // MessageTransport + tcp/udp 选择
│   ├── tcp.rs             // tcp send/recv
│   ├── udp.rs             // fast-lane attach、send/recv
│   ├── codec.rs           // 协议 encode/decode
│   ├── events.rs          // NetworkEvent / NetworkCommand
│   └── fastlane.rs        // attach 状态机
├── stdio/
│   ├── mod.rs             // ClientStdioInterface
│   ├── parser.rs          // ClientStdioCommand parse
│   ├── snapshot.rs        // SnapshotFields / snapshot_fields
│   ├── emit.rs            // emit / emit_owned
│   └── plugin.rs          // poll_stdio_commands
├── headless/
│   ├── mod.rs             // run() 选 voxel-only or full headless
│   ├── runner.rs          // 全 server-attached headless main loop
│   ├── voxel_runner.rs    // --voxel-headless
│   ├── script.rs          // wait/move/chat/skill/jump/snapshot 解析
│   └── dispatch.rs        // 共享命令 dispatch
└── tests/
    ├── voxel_parity.rs    // 保留(改 import 路径)
    ├── voxel_cli_parity.rs
    └── plugin_wiring.rs   // 新增,Phase 6 加
```

### 4.2 Plugin 内部契约

每个 Plugin 模块强制遵守:

```rust
// 例:input/plugin.rs
pub struct InputPlugin;

impl Plugin for InputPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<MovementIntent>()
            .init_resource::<InputTraceState>()
            .add_event::<VoxelEditEvent>()
            .add_event::<HotbarSelectEvent>()
            .add_event::<SkillCastEvent>()
            .add_event::<ChatToggleEvent>()
            .add_event::<ChatSendEvent>()
            .add_systems(
                Update,
                (
                    keyboard::sample_movement_input,
                    keyboard::handle_jump,
                    keyboard::handle_hotbar_keys,
                    mouse::handle_wheel_or_zoom,
                    mouse::handle_center_ray_click,
                    chat::toggle_chat_mode,
                    chat::collect_chat_text,
                )
                    .in_set(ClientSet::Input)
                    .run_if(in_state(AppState::Game)),
            );
    }
}
```

边界规则:

- 不允许在 Plugin 之间共享 `&mut Resource`(用 events / commands)
- 纯逻辑函数不 import `bevy::prelude::*`,只用 std + glam
- ECS 系统函数 ≤ 60 行,真正算法走纯模块
- 每个 Plugin 自带 README 写"我拥有什么、依赖什么、对外契约"

## 5. 分阶段落地

一次 PR 改 ~60 个文件 + ~10000 行不可 review。分 7 个 phase,每 phase 一组
commit、一次 `cargo fmt + clippy + test + GUI smoke`。

### Phase 0 — Baseline & branch

- 把当前未提交的 web-parity 改动整理为语义 commit:
  - `bevy: port web-parity voxel/jump/prefab features`(18 个修改 + `voxel/`+`tests/`)
  - `docs: web-parity migration & blueprint composition design`(2 篇 docs)
- push master
- 切 `feat/bevy-client-restructure` 分支
- 同时引入 `app/schedule.rs` 定义 `ClientSet` 枚举,挂到 `Update` 上当 no-op

**退出门槛**: `cargo test + clippy -D warnings + fmt --check` 全绿,GUI 启动到
登录面板正常。

### Phase 1 — 拆 `voxel/mod.rs`(纯逻辑层)

- 仅做"机械搬运 + import 修复",不改行为、不改公共 API
- 拆出: `voxel/core/{coord,material,mask}.rs`、`voxel/world/{store,snapshot,hotbar}.rs`、
  `voxel/prefab/{definition,registry,boundary,builtins,rotation}.rs`、`voxel/selection.rs`、
  `voxel/cli.rs`
- 在 `voxel/mod.rs` 顶层 `pub use` 维持外部 import 路径不变(本 phase 内,
  Phase 末才做 import 路径改造)
- `voxel_parity.rs` 与 `voxel_cli_parity.rs` 全跑

**退出门槛**: voxel 测试 100% 不动 + 不改 expected snapshot;GUI 体素操作走
通。

### Phase 2 — 拆 `net.rs` + `headless.rs`

- `net.rs` 2508 行 → `net/{plugin,thread,transport,tcp,udp,codec,events,fastlane}.rs`
- `headless.rs` 982 行 → `headless/{runner,voxel_runner,script,dispatch}.rs`
- `net/mod.rs`、`headless/mod.rs` 仍 re-export 让外部 import 不变

**退出门槛**: 网络相关单测 + voxel-headless 与 server-attached headless smoke
都过。

### Phase 3 — 引入 `BevyClientPlugins` 骨架

- 新增 `app/plugins.rs` 定义 `BevyClientPlugins: PluginGroup`
- 新增空 Plugin: `NetworkPlugin`、`InputPlugin`、`CameraPlugin`、
  `VoxelPlugin`、`ChatPlugin`、`SkillPlugin`、`EffectPlugin`、`HudPlugin`、
  `PresentationPlugin`、`MovementSyncPlugin`、`StdioPlugin`、
  `ObservePlugin`,每个 Plugin `build()` 先空着
- `app::run` 改成 60 行内: `App::new() + DefaultPlugins + LoginPlugin +
  BevyClientPlugins.build()`,具体 system 暂时仍挂在原 `app.rs` 残留

**退出门槛**: 编译通过,GUI 启动行为零差异。

### Phase 4 — 系统迁入 Plugin(分子阶段,每个一次 commit)

按依赖顺序:

1. `StdioPlugin`(无依赖,先迁): `poll_stdio_commands` 系统迁入
2. `ObservePlugin` + `NetworkPlugin`: `poll_network_events`、
   `MovementSyncPlugin`(`movement_sender`、`advance_local_render_prediction`)
3. `InputPlugin`: 把 `sample_movement_input`、`handle_skill_input`、
   `handle_target_selection_input`、`handle_point_target_input`、
   `handle_voxel_input`、`toggle_chat_mode`、`collect_chat_text` 迁入并按
   keyboard/mouse/chat 拆成多个 system 函数
4. `CameraPlugin`: `update_orbit_camera`
5. `VoxelPlugin`: `update_voxel_selection`、`sync_voxel_visuals`、
   `draw_voxel_guides`
6. `SkillPlugin`、`ChatPlugin`、`EffectPlugin`、`HudPlugin`、
   `PresentationPlugin`

每个子阶段一次 commit,跑全套 test + clippy + fmt + GUI smoke。

**退出门槛**: 旧 `app.rs` 内 system 函数全部清空,只留 `app::run` 与本地常量
(常量也迁到对应 Plugin)。

### Phase 5 — 引入领域 events 替代直连共享 resource

- `VoxelEditEvent { Place, Break, PrefabPlace, PrefabPlaceSnap }` 由
  InputPlugin 与 StdioPlugin emit、VoxelPlugin consume
- `HotbarSelectEvent` 同理
- `SkillCastEvent { skill_id, target }` 由 InputPlugin / Stdio / Skill 三处
  emit、SkillPlugin consume
- `ChatToggleEvent`、`ChatSendEvent` 同样
- 系统未上线,直接切到事件流,不保留旧路径

**退出门槛**: Plugin 之间不再共享 `ResMut<相邻领域 state>`。

### Phase 6 — Plugin 文档 + 测试基建

- 每个 Plugin 加 `README.md`("拥有什么、依赖什么、对外契约")
- 每个 Plugin 至少加一条 ECS-level 测试(用 `App::new().add_plugins(...)`
  单跑 system)
- 现有 `app::tests` 里 jump/release_keys 测试搬到 `input::keyboard::tests`
- 新增 `tests/plugin_wiring.rs` 验证 BevyClientPlugins 不重复挂 system / 不
  漏挂 set
- `voxel_parity.rs`、`voxel_cli_parity.rs` 决定保留 / 重写 / 拆分到 Plugin
  各自的单测里

**退出门槛**: `cargo test` 数量明显增加,clippy + fmt 全绿。

## 6. 测试策略

| 层 | 工具 | 覆盖 |
| --- | --- | --- |
| 纯逻辑 | `#[cfg(test)] mod tests` 在每个 .rs | voxel core/coord/mask、prefab boundary、camera orbit、cli parser、stdio parser、网络 codec |
| ECS 集成 | `App::new()` 临时构建 | InputPlugin 把按键转成事件、VoxelPlugin 接事件后改 VoxelWorld、CameraPlugin orbit 更新 |
| 跨 Plugin smoke | `tests/` | voxel parity、cli parity,新增 `plugin_wiring.rs` |
| GUI smoke | `target/debug/bevy_client.exe --observe-log ...` | startup、登录面板、入场;每 phase 末跑 |
| Headless smoke | `--voxel-headless --script` | 网页端等价 voxel 脚本 |

## 7. 重构期内的"oracle 自律"

为了让"重构是行为零差异的搬运 + 抽象"这件事可验证,每个 phase 内保持以下不
变,直到 phase 完成才一次性变更:

- `pressing_space_sets_one_shot_jump_intent_and_flag` 等现有断言,phase 内不
  动
- voxel headless smoke 命令字符串 phase 内不动
- GUI 启动到入场的可见行为零差异(每 phase 末跑一次 GUI smoke)

phase 末如果决定改命名(比如 `prefab_snap_preview` → `prefab_preview --snap`),
那是该 phase 的最后一个 commit,带上 README + docs 同步更新。这个自律不是对
外契约,只是为了让重构每一步都可验证。

## 8. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| Plugin 边界划分错误导致 system 顺序变化 | `ClientSet`(Network → Stdio → Input → Logic → Sync → Render)统一调度,所有 system 显式 `.in_set(...)`,不靠隐式顺序 |
| 拆 SystemParam 导致 borrow 冲突 | 每个 system 拆自己专属的 `XxxParams<'w, 's>`,不复用 |
| 大量 import 路径变更触发 phantom 错误 | 每 phase ≤ 1500 行变更,跑 `cargo check + clippy + test + GUI smoke`,失败立刻回退该 phase |
| 重构暴露原本就有的 bug(很可能发生) | 不在重构 phase 修;记到 issue list,后续 bug 修复 plan 里处理 |
| 分支与 master 长期并行 | 不允许长开;每完成一个 phase 立即 push,不积累 |

## 9. 后续

重构落定后开新 plan: `docs/superpowers/specs/<date>-bevy-client-bug-sweep.md`,
处理用户已经观察到的:

- 相机轨道与缩放
- 屏幕中心射线命中
- 视角相对移动
- movement uplink / prediction / reconciliation
- prefab 摆放与 boundary snap

每个 bug 在对应 Plugin 内定位 + 加针对性测试。本文档不展开。
