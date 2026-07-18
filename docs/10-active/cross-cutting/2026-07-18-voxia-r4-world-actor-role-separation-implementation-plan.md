# Voxia R4 World Actor 角色与 legacy probe 分离实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans and superpowers:test-driven-development task-by-task.

**Goal:** 用显式角色绑定替代 `Owner` cast 推断，并把 dormant SVO/VHI/heightmap renderer 及其状态从
`AVoxiaWorldActor` 迁到独立 `AVoxiaLegacyVoxelWorldProbeActor`，使唯一生产根的 near actor 只保留
完整 XYZ near 呈现、renderer-neutral far ownership 端口与既有根调用面。

**Architecture:** 先建立纯值 `EVoxiaWorldActorRole`/binding contract，再让 unified root 与 online
compatibility 在 deferred spawn 期间显式绑定 near 角色。当前巨型 actor 的 legacy 实现按原字节迁入
独立 probe actor，避免改写历史 probe 行为；新的 `AVoxiaWorldActor` 不继承 legacy actor，只保留生产
near 依赖闭包。`legacy_svo_handoff` 等既有 CLI schema 作为只读 compatibility telemetry 保持字段和
默认值，不重新获得 renderer 所有权。

## 不变边界

- 不改变 wire codec、协议字段、CLI token/envelope/schema、近场几何、材质、预算、readiness 或可见效果。
- `AVoxiaUnifiedVoxelWorldActor` 仍是唯一 `production_all_features` 根，仍恰有一个 near owner 与一个
  Pure3D far owner。
- legacy probe 保持显式 `probe/compatibility`，不得被 unified root 持有、绑定 world snapshot 或注册为
  production near owner。
- 不借 R4 改动 Transport、Pawn、far shell 或启动参数语义。
- 新增/修改代码注释使用中文。

### Task 1：显式角色合同

- [x] 先写 `Unbound → Bound`、重复绑定、BeginPlay 后绑定、非法角色和稳定 label 的 RED Automation。
- [x] 实现 `EVoxiaWorldActorRole` 与 `FVoxiaWorldActorRoleBinding` 纯值合同。
- [x] `AVoxiaWorldActor::BindRole` 只接受 unified production near / online compatibility near；未绑定
  BeginPlay 显式失败并禁用 Tick。
- [x] unified root 与 GameMode online compatibility 改用 deferred spawn + 显式 role bind；删除 owner cast。

### Task 2：legacy actor 迁移与 production near 收缩

- [x] 新建 `AVoxiaLegacyVoxelWorldProbeActor`，迁入现有 dormant SVO/VHI/heightmap renderer 方法、组件、
  uploader、fade、raymarch 与 handoff 状态；legacy composition 只 spawn 此类。
- [x] 从 `AVoxiaWorldActor` 头/实现移除 legacy renderer include、组件、状态和生命周期分支，保留
  production near、near active batch、chunk transaction、retirement 与 renderer-neutral sink。
- [x] 保持 `NearMeshStateJson`/root presenter 的既有字段、类型和 dormant telemetry 默认语义。
- [x] 反射/静态门禁确认 unified root 不引用 legacy actor，production near 不含旧 renderer
  component/property/type token，legacy actor 不提供 production snapshot bind。

### Task 3：验证、文档与提交

- [x] Development build 与 focused role/composition/world actor Automation。
- [x] 全量 Automation 不少于 R3 的 76 项、0 failure/warning。
- [x] Null-RHI 25 路生命周期 smoke 与独立 CLI 合同 smoke。
- [x] 更新 Gameplay/根 README 与治理进度，运行 `git diff --check`。
- [x] 分仓提交：client `refactor(governance): separate production near from legacy actor`；outer
  `docs(voxia): record R4 actor separation`。

## 验证证据

- Development build：`VoxiaEditor Win64 Development`，UHT、非 unity 编译与链接成功。
- focused Automation：`WorldActor`、`WorldActorRole`、`VoxelWorldComposition` 全部 Success。
- 全量 Automation：`77/77 Success`、0 failure、0 warning；产物
  `.demo/observe/voxia_governance_r4_full_final_20260718/`。
- 唯一生产根 Null-RHI：25 路通过、clean exit、far release=`11/11/0`；产物
  `.demo/observe/voxia_phase1_2026-07-18T16-48-03-570Z_null_rhi_1280x720/`。
- production CLI：help、flow probe、near mesh、interest、render/fps alias、legacy rejection、unknown 与
  quit 契约保持；最终 production 查询证据
  `.demo/observe/voxia_governance_r4_production_cli_final_20260718.log`。
- legacy probe CLI：`mode=legacy_probe`、`production_root=false`，`near_mesh.present=true` 且 readiness
  schema 保持；产物 `.demo/observe/voxia_governance_r4_legacy_probe_cli_green_20260718.log`。
