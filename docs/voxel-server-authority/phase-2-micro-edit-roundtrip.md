# Phase 2 — Refined micro edit 端到端贯通(被 1c 吸收,标记完成)

## 目标

确认原 Phase 2 "refined micro edit 端到端贯通" 的实质交付已经在 Phase 1c(尤其 1c-4 / 1c-5 / 1c-6)中提前完成,正式将 README 阶段表的 Phase 2 状态置为"已完成",并把 Phase 2 留下的两条延伸 scope(决策 5 RFC、跨进程 e2e harness)显式标注为后续阶段或 backlog,避免 phase 表悬空。

完成后:

- README 阶段表 Phase 2 行状态 = "已完成",计划文件指向本稿。
- 验收证据(commit / 测试集合)在本稿"验收"段记录,不需要再写代码或测试。
- 后续 scope 在"不在范围内"段显式归属到 Phase 3+(prefab v2)或 backlog,不再属于 Phase 2。

## 不在范围内(显式归属)

- **决策 5 RFC 落地**(原"在线 storage 直接以 `RefinedCellWireData[]` 为 truth,删除 wire→`FRefinedCellData` 的 lossy adapter"):**归入 Phase 3 之后的客户端重构 backlog**,不在 Phase 2 范围。理由:1c-5 已经实现了"客户端能消费 CellRefined delta",即 Phase 2 的端到端贯通诉求已满足;wire-form-as-truth 是后续优化(消除 lossy adapter),与 Phase 3 prefab 事务化无强耦合,可以独立排期。
- **跨进程 e2e 自动化测试 harness**(gate ↔ scene ↔ data_service ↔ web_client 真实节点 + 真实 socket 全链路):**归入测试基建 backlog**,不在 Phase 2 范围。当前 ExUnit + vitest 各自覆盖已经在 1c-4 / 1c-5 / 1c-6 路径上验证了端到端语义(decode → dispatch → apply → delta encode → decode → apply),跨进程 harness 是高成本投资,留给后续单独 Phase。
- **bevy_client 任何相关动作**:已在 2026-05-07 决策"客户端只迭代 web_client",bevy 暂停。

## 决策项

> 本阶段唯一决策:**确认"已被 1c 吸收"路径,而不是另开 Phase 2 scope**。

### 决策 1:**Phase 2 标记完成,不另立新工作**

理由:

- 原文档 Phase 2 的核心交付是"refined micro edit 端到端贯通"——这正是 1c-4(typed VoxelEditIntent dispatch)+ 1c-5(web_client 解锁 micro edit 并消费 CellRefined delta)+ 1c-6(VoxelEditIntent dispatch 加固 + solid-macro 拒绝原因细化)所完成的语义。
- 重复立项会让 README 与决策稿都僵硬地走一遍"已经做完的事再写一遍计划",违反"全新未上线系统不留兼容、不走双路径"的工作纪律。
- 后续 scope(决策 5 RFC 客户端重构、e2e harness)可以单独立项,不需要捆绑在 Phase 2 名下。

### 决策 2:**Phase 2 文件以本稿(stub + 验收证据)归档,不再追加内容**

本稿为最终态。后续 scope 的实施稿在新 phase 文件中开,不回流到本稿。

## 高层步骤

| Step | 范围 | 验收信号 |
| --- | --- | --- |
| 2-1 | 在 `docs/voxel-server-authority/README.md` 阶段表把 Phase 2 状态置 `已完成`,计划文件链接指向本稿 | README diff 仅有该行变化 |
| 2-2 | 提交 commit:`docs(voxel): mark Phase 2 as absorbed by Phase 1c (refined micro edit roundtrip)` | 单文件 commit(本稿 + README) |

无代码 / 测试改动。无 `mix format` / `vitest` / `tsc` 必要(纯 docs)。

## 验收(已完成的证据指针)

| Phase 2 子诉求 | 已完成证据 |
| --- | --- |
| typed `VoxelEditIntent (0x70)` 解码与 dispatch | 1c-4 commit `508ce1e` — gate_server 9 个 typed dispatch 用例 |
| Scene 端 `:put_micro_block` / `:clear_micro_block` | 1c-1/2/3 commit `c99d6fd` — scene_server refined mutation API + state matrix |
| `CellRefined` delta 编码与回推 | 1c-1/2/3 commit `c99d6fd` — Codec / ChunkProcess / ChunkDirectory 路径 |
| 客户端发起 micro edit 并应用 delta | 1c-5 commit `a02817a` — web_client `OnlineVoxelWorldAdapter.placeMicroBlock` / `breakMicroBlock` + delta apply |
| dispatch 加固 + 拒绝原因细化 | 1c-6 commit `07bee6b` — `:cannot_micro_edit_solid_macro` 等 reject path |
| canonical 持久化(让 reload 后客户端拿到一致 truth) | 1d commit `36b8ad7` — Postgres canonical persistence |

测试矩阵指针:

- `apps/scene_server/test/scene_server/voxel/chunk_process_micro_block_test.exs` 与 `chunk_directory_apply_intent_test.exs`(1c-1/2/3)
- `apps/gate_server/test/gate_server/worker/{ws,tcp}_connection_voxel_edit_intent_test.exs`(1c-4 / 1c-6)
- `clients/web_client/src/voxel/onlineVoxelWorldAdapter.test.ts`(1c-5)
- `apps/scene_server/test/scene_server/voxel/codec_test.exs` chunk_hash 全字段覆盖矩阵(1d)

## 风险

- **风险:Phase 2 标记完成后,后续如果发现 1c 链路有 micro edit 漏洞**——按"测试是契约"原则,在新 phase 或 hotfix commit 中修,**不**回退本稿状态。
- **风险:决策 5 RFC backlog 长期不落地**,在线 storage 永远经过 lossy adapter——可接受,因为不影响真相(真相在 server / Postgres),只是客户端内存表达层的优化。

## 进度日志

- 2026-05-07: Phase 2 决策稿入仓,标记 README 阶段表 Phase 2 = 已完成。Phase 2 实质内容由 1c-4 / 1c-5 / 1c-6 / 1d 提前交付。
