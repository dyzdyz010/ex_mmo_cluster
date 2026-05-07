# Phase 1b — typed `VoxelEditIntent` (decode-only)

## 目标

为客户端编辑意图引入 typed wire contract,**先把字段集和 wire 形钉死**,但**不路由到 Scene**(scene mutation API 留 1c)。同时把 `VoxelImpactIntent` 标记 deprecation,wire 不动,但语义收口为"技能/工具触发的地形影响",不再充当客户端编辑通道。

具体:

- 协议设计文档新增 `VoxelEditIntent (0x70)` 定义。
- `GateServer.Codec` 实现双向编解码 + ExUnit。
- Gate WS/TCP 解码后落 observe 日志,**不调用** `ChunkDirectory.apply_intent`。
- `VoxelImpactIntent` 在协议文档 / Gate codec / ws_connection / tcp_connection 三处加 deprecation 注释,行为不变。
- TS `encodeVoxelEditIntent` + Vitest;**不接 UI**(`OnlineVoxelWorldAdapter` 不调用)。
- 共享 fixture `voxel_edit_intent_v1.bin` 双端 byte 对齐。

## 不在范围内

- Scene 不新增 mutation 操作(`put_micro_block` 等留 1c)。
- 不解锁在线模式 `placeMicroBlock / breakMicroBlock`。
- `VoxelImpactIntent` 不删除、不改字段。
- 不动 `OnlineVoxelWorldAdapter` 调用方代码,UI 行为完全不变。
- 不引入 attribute / tag 目录(留 Phase 5)。

## 决策项(已定稿)

> 与 1a 一致,决策按推荐值落定。后续偏离须在进度日志显式记录 RFC。

### 决策 1:**新增 opcode `VoxelEditIntent (0x70)`,不复用 `VoxelImpactIntent`**

理由:

- `VoxelImpactIntent` 在协议设计文档 §13.6 明确说"技能系统通常在服务端内部直接触发体素影响;此消息只给工具、特殊交互或需要客户端显式指定地形目标的技能使用"——语义就不是"客户端直接编辑"。当前实现把 `impact_kind=0` 当作 break sentinel、非 0 当 material_id,是 hack。
- 1c 要支持 macro / micro / object-part 三种 target_granularity + place/break/damage/replace/attribute_patch 五种 action,塞进单一 `impact_kind u16` 会爆字段语义。
- 新 opcode 让 deprecation 路径明确:`VoxelImpactIntent` 不变,继续服务于 skill system;客户端编辑全走 `VoxelEditIntent`。

opcode 槽位 0x70(紧邻 0x6F `VoxelDebugProbe`,在 voxel 命名空间内)。

### 决策 2:**fixed-layout wire 形 + sentinel 表示 unspecified**

字段集(92 字节固定 wire,不含 opcode):

| 字段 | 类型 | 偏移 | unspecified sentinel |
| --- | --- | --- | --- |
| `request_id` | u64 BE | 0 | — |
| `client_intent_seq` | u32 BE | 8 | — |
| `logical_scene_id` | u64 BE | 12 | — |
| `action` | u8 | 20 | — |
| `target_granularity` | u8 | 21 | — |
| `target_world_micro` (x, y, z) | i64 BE × 3 | 22 | — |
| `face_normal` (nx, ny, nz) | i8 × 3 | 46 | (0,0,0) |
| `material_id` | u16 BE | 49 | 0 |
| `blueprint_ref` | u32 BE | 51 | 0 |
| `object_ref` | u64 BE | 55 | 0 |
| `part_ref` | u32 BE | 63 | 0 |
| `attribute_patch_ref` | u32 BE | 67 | 0 |
| `expected_chunk_version` | u64 BE | 71 | 0xFFFF_FFFF_FFFF_FFFF |
| `expected_cell_hash` | u32 BE | 79 | 0xFFFF_FFFF |
| `client_hint_hash` | u64 BE | 83 | — |
| **total** | | | **91 bytes payload + 1 byte opcode = 92** |

`action` 枚举:

| 值 | 名 | 含义 |
| --- | --- | --- |
| 0 | `Place` | 在邻接位放置(material_id 必须有意义) |
| 1 | `Break` | 破坏目标 |
| 2 | `Damage` | 减目标 health(后续 attribute system) |
| 3 | `Replace` | 用 material_id 替换目标材质 |
| 4 | `AttributePatch` | 应用 attribute_patch_ref(后续 attribute system) |

`target_granularity` 枚举:

| 值 | 名 | 含义 |
| --- | --- | --- |
| 0 | `Macro` | 命中整宏格(忽略 micro 偏移) |
| 1 | `Micro` | 命中单 micro slot |
| 2 | `ObjectPart` | 命中 (object_ref, part_ref) 标识的部件 |

理由(为什么 fixed layout + sentinel 而不是 flag bitmask):

- 1b 是 decode-only,wire 越简单越早期暴露字段集设计缺陷。
- 91 字节对 voxel intent 完全可接受,客户端编辑频率低于 movement 同步几个量级。
- sentinel 选择避开合法值:`expected_chunk_version` 真实范围 0..2^63-1(协议 §10),max u64 不冲突;`expected_cell_hash` 是 xxhash low 32,0 概率极低且 1b 不消费,实际安全。
- 1c 写 mutation 时再加 flag 也不破坏 1b 已发布 wire(flag 字段可在 reserved 区扩展,sentinel 字段直接换语义即可)。

### 决策 3:**Gate 1b 阶段 decode → observe → 静默 drop**

Gate 解码 VoxelEditIntent 后:

1. 落 observe 日志:request_id / actor / action / target_granularity / target_world_micro / 关键 ref 字段 / expected_* 是否 unspecified。
2. **不调用** `ChunkDirectory.apply_intent` / `apply_intents` 路径。
3. **不回** `VoxelIntentResult`(避免在 1b 期间形成"客户端以为编辑成功"的错觉)。客户端在 1b 期间不应该发该消息;observe 日志能让发出方知道"提交了但没生效"。

理由:

- Scene mutation API 还没建(1c)。如果 1b 路由到 Scene,Scene 必须 fail-loud 拒绝,客户端会看到 `VoxelIntentResult { result_code = Rejected, reason = "edit_action_not_implemented" }` —— 这等于让客户端误以为 wire 通了但临时不可用。1b 真正语义是 "wire 准备好,业务路径未通",observe-only 比 fail-loud 更准确。
- 测试只验证 codec roundtrip + Gate 落 observe 字段;不需要 mock 整个 Scene 路径。

### 决策 4:**`VoxelImpactIntent` 加 deprecation 注释,wire / 行为不变**

- 协议设计文档 §13.6 头部加一段说明:"客户端编辑意图请使用 `VoxelEditIntent (0x70)`;此 opcode 保留给技能/工具系统的服务端内部触发或需客户端指定地形目标的特殊技能。"
- `gate_server/lib/gate_server/codec.ex` 在 `@msg_voxel_impact_intent` 处加 `# DEPRECATED for client-side direct edit; use 0x70` 注释。
- `ws_connection.ex` / `tcp_connection.ex` 处理 VoxelImpactIntent 的 dispatch 函数加 docstring 注释,但行为不变(继续 floor 到 macro + impact_kind sentinel 解释)。
- `web_client/src/infrastructure/net/voxelProtocol.ts` 的 `encodeVoxelImpactIntent` 加 jsdoc `@deprecated`(不删除,因为 bevy 客户端可能也调用,deprecation 注释让 IDE 警告)。

不删除的理由:1c 才让 VoxelEditIntent 真正接管 break/place 行为;1b 阶段拔掉 VoxelImpactIntent 会让 Web/Bevy 客户端立即破。

### 决策 5:**TS encode 在 1b 范围内,不接 UI**

- 新增 `clients/web_client/src/infrastructure/net/voxelEditIntent.ts`(或扩 `voxelProtocol.ts`):`encodeVoxelEditIntent` + 相关常量 + JSDoc。
- Vitest 覆盖 fixed-layout wire 字段位置 + sentinel + action/granularity 枚举边界。
- **不在** `OnlineVoxelWorldAdapter` 中调用。1c 才让 placeMicroBlock 等切到 typed intent。

## 文件清单

### 新增 — 文档

- `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`:在 §13 操作码表 + §13.6 后插入新章节 §13.6.1 `VoxelEditIntent (0x70)`(或重新排序)。同时在 §13.6 头部加 deprecation 提示。

### 新增 — Elixir

- `apps/gate_server/lib/gate_server/codec.ex`:
  - `@msg_voxel_edit_intent 0x70`
  - `decode/1` 子句 + `encode/1` 子句(用于 GateServer 自测;真正 encode 主要在客户端)
  - `@msg_voxel_impact_intent` 处加 deprecation 注释
- `apps/gate_server/test/gate_server/codec_test.exs`:VoxelEditIntent 编解码 + 边界 + deprecation 注释覆盖

### 修改 — Elixir

- `apps/gate_server/lib/gate_server/worker/ws_connection.ex` 与 `tcp_connection.ex`:
  - 新增 `voxel_edit_intent` dispatch:落 observe + 静默 drop
  - 不路由 ChunkDirectory
  - 既有 `voxel_impact_intent` dispatch 注释 deprecation,行为不变

### 新增 — TypeScript

- `clients/web_client/src/infrastructure/net/voxelEditIntent.ts`:
  - `VoxelEditAction` / `VoxelEditTargetGranularity` 枚举
  - `EditIntentUnspecified` 常量(`-1n` / `0xFF...` / `0` 等 sentinel)
  - `encodeVoxelEditIntent(args): Uint8Array`
- `clients/web_client/src/infrastructure/net/voxelEditIntent.test.ts`:wire 字段位级测试 + sentinel + 枚举边界

### 修改 — TypeScript

- `clients/web_client/src/infrastructure/net/opcodes.ts`:加 `VoxelEditIntent: 0x70`
- `clients/web_client/src/infrastructure/net/voxelProtocol.ts`:`encodeVoxelImpactIntent` 加 `@deprecated` JSDoc

### 新增 — 共享 fixture

- `apps/gate_server/priv/scripts/gen_voxel_edit_intent_fixture.exs`:生成代表性 fixture
- `apps/gate_server/test/fixtures/voxel/voxel_edit_intent_v1.bin`
- `clients/web_client/test/fixtures/voxel/voxel_edit_intent_v1.bin`(同 bytes)

## 测试矩阵

| 测试 | 类型 | 文件 | 目的 |
| --- | --- | --- | --- |
| Codec encode → decode roundtrip | ExUnit | `codec_test.exs` | 字段级 + byte 级一致 |
| sentinel 解码后保持 unspecified 语义 | ExUnit | 同上 | 0xFFFF... 解出后语义不变 |
| `action` / `target_granularity` 越界拒绝 | ExUnit | 同上 | u8 范围内但未定义的值如何处理(decode 通过,业务层后续校验) |
| short payload 拒绝 | ExUnit | 同上 | <91 字节返 `:invalid_message` |
| Gate ws/tcp dispatch 落 observe + 不调用 ChunkDirectory | ExUnit(if mockable)| `gate_server` test | 行为隔离 |
| VoxelImpactIntent 行为不变 | ExUnit | `codec_test.exs` | 既有测试不动应仍通过 |
| TS encode 字节级 byte stable | Vitest | `voxelEditIntent.test.ts` | offset / 大端序 / sentinel |
| 共享 fixture 双端解码 | ExUnit + Vitest | `voxel_edit_intent_v1.bin` | byte 对齐 |
| fixture stale 兜底 | ExUnit | 同 1a 模式 | 测试运行时按脚本逻辑重建 fixture,与磁盘 byte 比对 |

## 验收标准

- `mix test` 全 umbrella 通过,gate_server / scene_server / world_server 全绿。
- `pnpm test` (web_client) 全绿,tsc --noEmit 通过。
- 新增 ≥ 12 ExUnit + ≥ 8 Vitest。
- fixture 双端 byte 对齐。
- VoxelImpactIntent 既有路径行为完全不变(行为回归测试 0 失败)。
- HUD / CLI / observe 在客户端不发 VoxelEditIntent 的情况下完全不变(因为 1b decode-only 不暴露任何 UI 改动)。

## 风险

- **风险:fixed-layout wire 字段集在 1c 不够用**。如果 1c 发现遗漏字段,要么牺牲 sentinel 复用,要么在尾部追加(打破 fixed size)。缓解:1b 决策稿已经覆盖 phase-1a 文档列出的所有候选字段(action/granularity/material/blueprint/object/part/attr_patch/expected_*/face_normal/hint_hash),覆盖度高。
- **风险:Gate observe 日志在 1b 大量出现**。如果客户端误发,会刷日志。缓解:observe 加 rate limit 或仅在 dev/staging 输出;production 默认 sample 1%。本计划 v1 不做 sampling,留 1c 视情况调。
- **风险:`VoxelImpactIntent` 仍是客户端默认编辑通道**,1b 不破。但用户可能误以为 1b 完成 = 客户端编辑切到 typed intent。缓解:本文件 / 进度日志 / 协议文档明确说明 1c 才切。

## 进度日志

- 2026-05-07: **Phase 1b 加固通过**,自查后修补 6 类问题,gate_server 152 → 170 tests;web_client 158 → 197 tests。
  - 加固 A(协议正确性):Codec encode 14 字段每个都有越界拒绝测试(原仅 3 个)。补 u8 / u16 / u32 / u64 / i64 各类型上下界、非整数 / nil / atom / string 输入、tuple 形状错误、缺字段等。新增 11 个 ExUnit。
  - 加固 B(协议正确性):Codec decode 边界 + forward-compatibility。新增 10 个 ExUnit:trailing bytes 拒绝、empty payload (just opcode) 拒绝;forward-compat 接受未定义 `action` / `target_granularity` 值(0..255 任意 byte);接受 wire-legal 但语义不合法的 `face_normal`(如 `(5, 0, 0)`);确认 face_normal 是 signed i8 解释(byte 0xFF → -1);byte-level boundary 全字段 roundtrip(u8/u16/u32/u64 max,i64 min/max);所有字段全零 roundtrip。
  - 加固 C(架构 + 行为正确性):
    - **架构疏漏修复**:ws/tcp dispatch 的 observe payload 加 `client_hint_hash`(原本漏掉,排障关键字段)。
    - 新增 ws_connection_voxel_test 3 个集成测试:`:in_scene` 状态收 voxel_edit_intent → 落 `ws_voxel_edit_intent_received` observe + **不发** VoxelIntentResult(1b 核心保证);非 `:in_scene` 状态 → 落 `ws_voxel_edit_intent_dropped_invalid_state` observe + 静默;edit_intent 与 deprecated impact_intent 共存路径仍各自工作。
    - tcp_connection 端代码模式与 ws 共享,行为通过 codec test 间接覆盖。
  - 加固 D(协议正确性):TS encode 14 字段每个都有越界拒绝测试(原仅 5 个)。补 u8 / u16 / u32 / u64 / i64 上下界 + bigint required(全部 8 个 bigint 字段强制 typeof 检查)+ non-integer (NaN / 1.5 / Infinity) reject + face_normal 三轴独立 reject + target_world_micro 三轴独立 reject + all-zero / all-max intent 编码并 byte-level 验证 fixed offset。新增 39 个 Vitest(用 table-driven 模式覆盖 14 字段)。
  - 验收:gate_server 170 tests, 0 failures;scene_server 202 tests, 0 failures;web_client 32 files / 197 tests / 0 failures;tsc --noEmit 干净;world_server 那处预存 Windows path 测试与本加固无关。
- 2026-05-07: **Phase 1b 全部 Step 落地,双端绿**。
  - Step 1 协议文档:`docs/2026-04-29-...` §13 操作码表加 `0x70 VoxelEditIntent`;§13.6 头部加 deprecation 提示;新增 §13.6.1 字段表 + `action` / `target_granularity` 枚举说明 + Phase 1b 实施范围说明。
  - Step 2 GateServer.Codec:`@msg_voxel_edit_intent 0x70`;decode 子句(91 字节固定 payload);encode 子句 + 字段范围校验(u8/u16/u32/u64/i64/i8/world_micro/face_normal);`@msg_voxel_impact_intent` 加 deprecation 注释。新增 6 个 ExUnit:基础 decode、short-payload reject、全 sentinel 解码、roundtrip、out-of-range encode reject、双 fixture decode + stale 兜底。gate_server 由 54 → 62 tests。
  - Step 3 ws/tcp_connection dispatch:新增 `:voxel_edit_intent` 分支,`in_scene` 状态下落 observe 日志(`phase: "1b_decode_only_no_route"` 标志显式表达 wire 已通但业务路径未通);非 `in_scene` 状态落 dropped 日志。**不调用 ChunkDirectory,不回 VoxelIntentResult**。`voxel_impact_intent` dispatch 头部加 deprecation docstring。
  - Step 4 TS encode:新增 `voxelEditIntent.ts`(`VoxelEditAction` / `VoxelEditTargetGranularity` 枚举 + `EXPECTED_*_UNSPECIFIED` sentinel 常量 + `encodeVoxelEditIntent`)。`opcodes.ts` 加 `VoxelEditIntent: 0x70`。`voxelProtocol.ts` 的 `encodeVoxelImpactIntent` 加 `@deprecated` JSDoc。新增 9 Vitest:wire size、字段位级偏移、sentinel、u8/u16/u64/i8/i64 越界 reject、boundary i64 接受。
  - Step 5 共享 fixture:`gen_voxel_edit_intent_fixture.exs` 生成 184 字节(2 × 92)fixture(intent A = macro+place+material;intent B = ObjectPart+break+expected_chunk_version+expected_cell_hash+object_ref/part_ref);双端 byte 对齐;Elixir/TS 各加 fixture decode 测试 + 1 个 fixture stale 兜底。
  - 顺手修:1a 留下的 `refinedCellWire.test.ts` 在 `noUncheckedIndexedAccess` 严格模式下解构后 `c1`/`a`/`b`/`ref` possibly undefined 的 tsc 报错(发现并修);新增 `@types/node` 到 web_client devDependencies 以让 tsc 接受 `node:fs` / `node:url` / `node:path` import,tsconfig types 加 `"node"`。
  - 验收:gate_server 144 → 152 tests, 0 failures;scene_server 202 tests, 0 failures;web_client 32 files / 158 tests / 0 failures;tsc --noEmit 干净。
  - 不在 1b 范围的预存失败:`apps/world_server/test/world_server/voxel/authority_observe_test.exs:35` 一处 Windows path 大小写 + slash 风格比对(`c:/...` vs `C:\\...\\...`)失败。world_server 本会话零改动,git status 干净;此失败属预存 Windows-only 测试 path normalization 问题,与 typed edit intent / wire 完全无关,记此处留作后续修复(建议在测试里 normalize 两侧 path 后比对)。
- 2026-05-07: 计划稿成稿。决策 1-5 按推荐值定稿。
