# Phase 5 顶层 backlog + sub-phase 分解

状态：sub-phase 分解稿，每个 sub-phase 后续出独立设计草案再实施
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 5

真相源：
- `.omc/goals/voxel-authoritative-and-field-minimum.md` §Phase 5
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标三"
- Phase 1.2 AttributeSet (commit `251b5b4`) / Phase 1.4 CatalogPatch envelope (commit `53d065d`)

前置依赖：
- Phase 1.1-1.6 全 done（AttributeSet/TagSet/CatalogPatch wire 已冻结）
- Phase 2 (VoxelEditIntent v1 + storage micro API) done
- Phase 3 (transaction infrastructure) done
- Phase 4 (ObjectRegistry + damage cascade) done

---

## 1. Phase 5 顶层目标（goal §Phase 5）

把 attribute / tag 从「typed wire envelope」（Phase 1 已落地）升级为「真正可读可写的语义层」：
- catalog 全局命名空间（key_id 升级为 global id with name / unit / merge_rule）
- 第一批 typed attributes 落地（temperature / humidity / moisture / density / thermal_conductivity）
- 属性存储粒度优先级 + merge_rule
- Scene 低频规则帧基础设施 + 温湿度 simulator
- EnvironmentUpdated / CatalogPatch / AttributeCatalogSnapshot delta 下发

---

## 2. Sub-phase 分解（按依赖顺序）

### 5.A `AttributeCatalogSnapshot` typed module + wire (opcode 0x6E)

**范围**：
- 实现 `apps/scene_server/lib/scene_server/voxel/attribute_catalog_snapshot.ex`：全量 catalog 快照 typed module
- `AttributeDefinition` v1 schema (id / name / unit / value_type / default_value / min_value / max_value / merge_rule / dynamic?)
- wire encode/decode for opcode `0x6E AttributeCatalogSnapshot`（协议规范 line 243 已预留）
- catalog version monotonic 推进

**决策点**：
- A-1 catalog scope 是 logical_scene_id 范围还是全局？建议全局（与 chunk-local AttributeSet 解耦，catalog 升级 chunk key_id 含义）
- A-2 catalog name 字符串编码方式？建议 UTF-8 + u16 length prefix
- A-3 merge_rule 枚举值
- A-4 dynamic? 字段语义（是否影响 wire 编码或仅运行时）

**测试**：catalog roundtrip + version monotonic + 跨 chunk key_id 升级路径

**commit**：`phase5a: AttributeCatalogSnapshot typed module + opcode 0x6E wire codec`

### 5.B `TagCatalogSnapshot` typed module + wire (opcode 0x6D)

**范围**：
- 实现 `apps/scene_server/lib/scene_server/voxel/tag_catalog_snapshot.ex`
- `TagDefinition` v1 schema (id / name / namespace?)
- wire encode/decode for opcode `0x6D TagCatalogSnapshot`

**与 5.A 关系**：结构对称但更简单（tag 无 value_type 等元数据）。可与 5.A 并行做，**独立 commit**。

**commit**：`phase5b: TagCatalogSnapshot typed module + opcode 0x6D wire codec`

### 5.C 第一批 typed attribute 定义注入 catalog

**范围**：
- 定义 5 个 attribute（temperature / humidity / moisture / density / thermal_conductivity）作为 catalog v1 内置项
- 写入 `apps/scene_server/priv/catalogs/attribute_catalog_v1.exs`（或类似 deterministic seed 数据）
- AttributeCatalog initialization (从 priv 加载 → ETS / GenServer)
- `Storage.put_attribute_set_for_cell` API 支持按 catalog id 设置 attribute

**决策点**：
- C-1 catalog id 分配（数字 0-4? hash of name? UUID?）
- C-2 temperature / moisture 数值范围（°C × scale? Q16.16?）
- C-3 default value（room temperature = 20.0°C → 20*65536 = 1310720 Q16.16? humidity = 50%?）

**commit**：`phase5c: attribute catalog v1 with first batch (temp/humidity/moisture/density/thermal_conductivity)`

### 5.D 属性存储粒度优先级 + merge_rule

**范围**：
- `Storage.effective_attribute_at(cell, key_id)` 五层 merge：material default → normal block override → refined micro override → object-part attribute → environment summary
- merge_rule 实现：override / add_delta / max / min / material_default
- 单元测试：每个 merge_rule + 五层覆盖优先级

**决策点**：
- D-1 五层顺序到底是什么？goal §5.1 列了五个粒度但没说优先级
- D-2 `temperature_delta` / `moisture_delta`（已在 NormalBlockData 预留）与 attribute_set_ref 中的 temperature 的关系（add_delta 合并？)
- D-3 object-part attribute 来自哪里？（Phase 4 PartState 是否要扩展？还是单独的 ObjectAttributeSet？）

**commit**：`phase5d: effective attribute merge with five-tier priority + merge_rule`

### 5.E Scene 低频规则帧基础设施

**范围**：
- `SceneServer.Voxel.SimulationTick` GenServer 调度器（每 100ms / 200ms tick？）
- dirty cell / dirty bounds 标记 + 跨 chunk 边界事件（lease/owner_epoch fence，与 Phase 3-bis 持久化对齐）
- deterministic hash for 规则帧 input/output
- 单元 + 集成测试：tick 序列稳定性

**决策点**：
- E-1 tick frequency
- E-2 tick 调度是 per-chunk 还是 per-scene? per-region?
- E-3 跨 chunk boundary 事件如何序列化与重放
- E-4 simulator 是 pluggable 模块还是 hardcoded?

**commit**：`phase5e: scene low-frequency simulation tick + dirty tracking + boundary fence`

### 5.F 温湿度 simulator + EnvironmentUpdated delta

**范围**：
- temperature / moisture diffusion algorithm (heat equation? stencil? graph?)
- `MacroEnvironmentSummary.current_temperature / current_moisture` 写入路径
- `EnvironmentUpdated` delta wire encode/decode（新 opcode 待分配或扩展 ChunkDelta delta_kind=3）
- 集成测试：注入热源 → tick N 次 → 邻 chunk current_temperature 变化 + delta 下发

**决策点**：
- F-1 simulator 算法（v1 简化的 stencil）
- F-2 delta wire 通道（新 opcode? ChunkDelta 扩展 delta_kind=3?）
- F-3 客户端消费路径（Phase 1.6b web_client 端如何渲染 / 显示）

**commit**：`phase5f: temperature/moisture diffusion simulator + EnvironmentUpdated delta`

---

## 3. 实施顺序建议

按依赖 + 风险：

1. **5.A** AttributeCatalogSnapshot（独立设计草案，wire 一旦发出冻结，决策点多，应先做）
2. **5.B** TagCatalogSnapshot（与 5.A 并行，独立 commit）
3. **5.C** 第一批 attribute 定义（依赖 5.A 落地）
4. **5.D** 五层 merge_rule（依赖 5.C）
5. **5.E** 低频规则帧基础设施（独立可并行 5.C/5.D，但 5.F 依赖 5.E）
6. **5.F** 温湿度 simulator + EnvironmentUpdated delta（依赖 5.A/5.C/5.D/5.E）

总共 6 个独立 commit，每个 commit 一个 sub-phase。

---

## 4. 与 Phase 6（局部场最小目标）的衔接

Phase 5 完成后：
- typed `temperature / moisture` 已经在 chunk truth 中可读可写
- 低频规则帧基础设施已就位
- delta 下发链路通顺

Phase 6 局部场（FieldLayer）将在此基础上加入「瞬时高频局部场」（vs Phase 5 的「静态低频规则帧」）。Phase 6 spec §3.1 明确要求 Phase 5 typed attribute domain 落地前不开工。

Phase 5 各 sub-phase 完成情况是 Phase 6 开工的硬 gate。

---

## 5. 风险

- **AttributeCatalogSnapshot wire 一旦发出即冻结**：与 Phase 1.2 同款风险。5.A 设计草案阶段需要用户复核 A-1..A-4 决策点。
- **catalog version 协调**：5.A catalog version 监 monotonic + Phase 1.4 CatalogPatch envelope 中 base_version / new_version 字段语义对齐。
- **simulator 确定性**：5.E + 5.F 必须 deterministic，否则集群多节点不一致。需要 well-defined random source + tick replay 能力。
- **wire opcode 抢占**：5.A 用 0x6E、5.B 用 0x6D（协议规范已预留）；5.F 的 EnvironmentUpdated 需要新 opcode 或扩展 ChunkDelta delta_kind。需在 5.F 设计阶段决定。

---

## 6. 下一步

本 backlog 文档完成后，下轮（#3+）按 §3 顺序逐 sub-phase 出独立设计草案：

- 下轮（#3）：起 5.A AttributeCatalogSnapshot 设计草案 → 用户复核 → TDD → 实现 → commit
- 下下轮（#4）：5.B / 5.C 并行
- 后续：5.D / 5.E / 5.F 逐步推进

每个 sub-phase 标准节奏：读现状 → 设计草案 → 用户复核决策点 → TDD → 实现 → verifier → commit → 文档同步（与 Phase 1.2/1.3/1.4 同款）。
