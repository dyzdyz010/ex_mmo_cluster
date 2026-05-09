# Phase A1 — 客户端可玩 demo 必须线 (playable client experience)

**起草日期**:2026-05-09。**状态**:决策稿(已合并 prefab 改进 + 破坏技能,用户已授权直接开干)。

阶段 A 第二子阶段。原 A1 范围 = 移动+跳跃同步,扩展为"客户端 demo 必须线全套",包括用户在 2026-05-09 提的 prefab 修复 / 防覆盖 / 线框预览 / 破坏技能。前后顺序由"用户最直观感知"驱动。

A2(尺寸真实化)已落地(2026-05-09,commit chain `6144408..730e6e7`)。A3(多客户端联调)在 A1 之后。

## 阶段目标

让 web_client 路演 demo 体验级别的 5 个痛点全部修复:
1. 三个 prefab 放下去看到的形状跟客户端 preview 一致(实际是 sphere/cylinder/stairs)
2. 已被占用的 cell 不能再放 prefab 覆盖,服务端权威拒绝
3. Prefab 放置时显示沿 micro mask 的线框,不再像放宏格一样只一个方框
4. 移动 + 跳跃同步端到端跑通,服务端 Airborne mode 权威 + 客户端 reconciliation
5. 用技能直接打 prefab 看到局部破坏(碎屑粒子 + part_destroyed flag)

## 范围

### 在范围

- 服务端 `BlueprintCatalog` micro 化:每个 prefab 携带 occupancy mask + materialId + part 定义,跟客户端 `prefab/definitions.ts` 对齐
- 服务端 `PrefabRaster` 改成产生 micro `:put_micro_block` intents(批量,按 occupancy mask 展开 micro slot)
- 服务端 `chunk_process` occupancy 拒绝逻辑:已有 refined / solid 内容时返回 `:rejected`
- 客户端 `prefabPreviewGeometry` 沿 micro mask 描线框(不再单 macro outline)
- 客户端 jump 按键 → server `0x05 MovementInput` flag → 服务端 `Airborne` mode → ack groundY/mode → 客户端 reconciliation(Predictor 已支持垂直,主要是端到端联调)
- 服务端 `0x09 SkillCast` 命中 voxel target_position → `Storage.lookup_owner_at` → `ObjectRegistry.accumulate_damage` → `ObjectStateDelta` 0x6C 推送(debris 链路 4-bis 已就位)

### 不在范围

- A3 多客户端联调 / 跨 region 同步
- Phase 5 属性目录 / 温湿度
- 跳跃 reconciliation 的 jitter / packet loss 容忍(Phase B/C+ 范围)
- 技能视觉特效(EffectEvent 已有,visual cue 用现有的)
- prefab rotation > 0(v1 仍只接受 rotation=0,本阶段不动)
- Per-class movement profile / 不同角色不同跑速(A2 决策稿 D4 已说"Phase 5+")
- prefab 线框预览的 socket 高亮(只描 occupancy mask 边线)

## 决策项

### D1. Prefab catalog 协议层迁移到 micro

**现状**:
- 服务端 `BlueprintCatalog` 定义 macro cell offset list(`builtin_pillar_3` / `builtin_floor_3x3` / `builtin_cube_2x2x2`),`PrefabRaster` 产生 macro `put_solid_block` 写
- 客户端 `prefab/definitions.ts` 定义 micro occupancy mask(sphere / cylinder / stairs),只用于 preview 渲染
- wire 上 `0x67 PrefabPlaceIntent` 只携带 `blueprint_id` + `anchor_world_micro` + `rotation`,**没有 micro 信息**
- 结果:用户看 sphere preview → 放下去 → 服务端按 pillar 填 solid → 客户端 chunk delta 渲染成 macro 方块,**视觉对不上**

**目标**:服务端 catalog 携带 micro occupancy mask,跟客户端语义统一。

**推荐方案**:
- `BlueprintCatalog` 重写:每个 prefab 改成 `%{id, name, version, material_id, occupancy_mask :: <<512 bits>>, part_id_table :: [non_neg_integer()]}` 形式(512 bits = 8³ micro slots per macro)
- 三个 v1 prefab 改成 `builtin_sphere` (id=1) / `builtin_cylinder` (id=2) / `builtin_stairs` (id=3),mask 用跟客户端**完全一样**的几何函数生成(球/圆柱距离判定,阶梯 y ≤ x 判定)— 写在 `BlueprintCatalog` 里 compile-time 算
- material_id 跟客户端 `VoxelMaterialId.Stone / Ice / Wood` 对齐
- v1 仍是 1×1×1 macro bounds(单 macro 内 micro 蚀刻),不做跨 macro 拼接
- `version` 升 1→2,wire `blueprint_version` 强校验。**不留 v1 兼容**(memory `feedback_no_backcompat_unreleased.md`)

**推荐:采纳**。这是 prefab 形状对齐的根本路径,不绕弯。

### D2. PrefabRaster 改成 micro intents

**现状**:`PrefabRaster.rasterize/4` 产生 `[%{chunk_coord, local_macro, block: NormalBlockData}]`(macro level)。

**目标**:产生 micro-level edits。

**推荐方案**:
- `rasterize/4` 改成产生 `[%{chunk_coord, local_macro, micro_intents}]`,其中 `micro_intents` 是 256 个 micro slot 中被 mask 命中的那些 slot 的 `:put_micro_block` 列表(或者一个 batch micro write 数据结构)
- 实际看 `BuildTransactionApplier` 当前接什么 — 如果 Phase 1c 已经支持 micro intent batch,直接用;如果只支持 `put_solid_block`,要扩 applier(在 step 实施时 verify)
- 由于 Phase 1c-3 已经有 `:put_micro_block` 走 chunk_process,本质是在 prefab 路径上改成 micro 写入,**不开新的 storage API**

**推荐:采纳**。

### D3. Prefab 防覆盖(occupancy reject)

**现状**:`Storage.put_solid_block` 不检查 cell 当前状态,直接覆盖;`Storage.put_micro_block` 已有"不能写到 solid macro"的 raise,但**不检查 micro slot 是否已经被占用**。

**目标**:已有 micro/refined 内容时,**整个 prefab 拒绝**(全成功或全失败,不部分覆盖)。

**推荐方案**:
- 在 prepare 阶段(Scene 端 `BuildTransactionApplier.prepare/4` 或 chunk_process 的 build_intent_storage)新增 occupancy 检查:遍历 prefab 所有 micro slot,检查是否任意 slot 被占
- 任意被占 → 整个 transaction `:rejected`,reason `:cell_occupied`
- Wire 响应:`prefab_place_response` 用现有的 `:rejected` 响应码,reason atom 透传到客户端
- 客户端:HUD 提示"该位置已有方块"3.5s flash

**推荐:采纳**。"全成功或全失败"对齐 Phase 3 transaction 语义。

### D4. Prefab 线框预览(沿 micro mask)

**现状**:`prefabPreviewGeometry.ts` 用 `buildPrefabRasterMicroWireGeometry` 按 macro 单方框描线(决策稿调查报告说 cyan 0x67e8f9 wireframe LineSegments)。**但**用户描述说"像放置宏格一样只一个方框" — 我现在没读这个文件具体行为,得确认一下。

**目标**:沿 micro occupancy mask 的边线描线框,清晰可见 sphere/cylinder/stairs 形状。

**推荐方案**:
- 实施前先 verify `buildPrefabRasterMicroWireGeometry` 当前到底产生什么(D4 step 第一件事)
- 如果当前是单 macro outline:改成遍历 occupancy mask,每个 occupied micro slot 描自己的方块边线(产生 micro slot 表面 line segments)
- 重复边(相邻 micro 共享面)合并,只画外表面线
- 颜色保留 cyan,加细 alpha 让 sphere 不致太密

**推荐:采纳,但 step 第一件事先 verify 现状**(用户描述 vs 调查报告有 gap,我得先看代码确认)。

### D5. 移动 + 跳跃同步

**现状**:
- 客户端 `localPlayerController` 有 jump 按键 `requestJump`,产生 `MovementFlag.Jump` 输入帧
- Predictor `predictor.ts` 已经支持 airborne / groundY 推导
- 服务端 `movement_core` `airborne_step` 已实现(Phase A2 已确认)
- A2 把 jump_impulse=485 / max_fall_speed=5300 调到合理值

但**端到端跑通**没确认。可能存在的问题:
- 服务端 `player_character.ex` 是否正确 forward 输入帧到 `MovementEngine.step`(包括 Airborne mode transition)
- ack 包是否带 `groundY` / `movement_mode`(client reconcile 用)
- client reconcile 是否处理垂直 correction(predictor 已支持,但 reconcile.ts 要 forward groundY)

**推荐方案**:
- Step 实施时先**手动 demo 一次** + 看 ClientStdioInterface 日志判断现状(memory `cli_debugging.md`)
- 找出实际坏在哪一层,针对性修
- 不预先猜测,**先观察再动手**(memory `feedback_align_with_industry.md`)

**推荐:采纳"先观察再动手"路线**。step 落地时分两步:A1-4a 诊断 + A1-4b 修复。

### D6. 破坏技能 → voxel 串联

**现状**:
- 调查报告:`0x09 SkillCast` 已携带 `target_position` (f64×3 world coord)
- `CombatExecutor` 现在伤害只走 player HP,**没有连到 voxel**
- `Storage.lookup_owner_at(scene_id, chunk_coord, local_micro)` 已有反查
- `ObjectRegistry.accumulate_damage(scene_id, object_id, part_id, damage, ...)` 已有
- `ObjectStateDelta` 0x6C 推送 + 客户端 debris 链路(Phase 4 + 4-bis)已全套就位

**目标**:用现有技能(选 1-2 个,例如 Arc Slash / Arc Bolt)在打到 voxel 时触发 `accumulate_damage`,客户端看到 debris 飞溅 + part_destroyed HUD。

**推荐方案**:
- 服务端 `CombatExecutor` 在 apply_damage 阶段,如果 target 不是 player(或同时是),把 target_position 转成 (chunk_coord, micro_slot),调 `Storage.lookup_owner_at` → 命中则调 `accumulate_damage`
- 命中 cascade 已有(part destroyed → object_destroyed → ObjectStateDelta cascade 推送)
- 客户端不用改(consumer 已有)
- 选用现有技能:`Arc Slash` (id=1) 走 voxel + actor 双路径
- 伤害量:从 `Skill.damage_amount` 取,默认值不调

**推荐:采纳**。现有 API 串联,不开新 wire。

## 风险

1. **A1-1 prefab catalog 改造范围比预期大**:如果 `BuildTransactionApplier` 不直接接 micro intent batch,要扩展 applier;但 Phase 1c-3 已支持 `:put_micro_block`,概率低。**Step 实施时 verify**。
2. **A1-1 v1→v2 wire 升级会让旧客户端断版本**:仅影响本会话内手动 demo,memory `no_backcompat_unreleased.md` 适用,不留兼容。
3. **A1-2 occupancy 检查放在 prepare 还是 commit?** 放 prepare 早拒绝,但 prepare 在 transaction 持久化前发生,还没 lock chunk;放 commit 时拒绝太晚已经写一半。**推荐放 prepare**(参考 Phase 3 fence 语义)。
4. **A1-4 跳跃 reconciliation 现状未知**:可能"已经能用了只是没被 demo 过",也可能"垂直 correction 漏一层"。先观察。
5. **A1-5 同时打到 player 和 voxel 时怎么算**:`CombatExecutor` 现状只支持 single target,实施时如果发现要扩,**只扩 voxel target 路径,不动 player damage 行为**。

## 步骤分解

每步独立 commit,Elixir 改前 `mix format`,web 改后 `npx tsc --noEmit && npx vitest run`。**不 push**。

| Step | 范围 | 验证 | 估时 |
|---|---|---|---|
| **A1-1** | BlueprintCatalog 改 micro mask + PrefabRaster 改产生 micro intents + applier 接通 + 测试更新 | 手动 demo:放 sphere 看到客户端渲染是 sphere | 1-1.5 天 |
| **A1-2** | chunk_process build_intent_storage 加 occupancy 检查 + :rejected response + 客户端 HUD 提示 | 手动 demo:放 prefab 在已有 prefab 上看到拒绝 | 0.5 天 |
| **A1-3** | 客户端 prefabPreviewGeometry 沿 micro mask 描边线 | 手动 demo:举起 prefab 看到 sphere 线框 | 0.3 天 |
| **A1-4a** | 跳跃同步现状诊断(stdio 日志 + 一次手动 jump demo) | 找出问题点,记录到决策稿 | 0.3 天 |
| **A1-4b** | 跳跃同步修复 | 手动 demo:jump → apex → fall 完整曲线,服务端 ack groundY/mode 正确 | 1-3 天(看现状) |
| **A1-5** | CombatExecutor 接 voxel 路径 + 选 1 个技能放通 | 手动 demo:Arc Slash 打 prefab 看到 debris | 0.5-1 天 |
| **A1-final** | 决策稿状态 + README + handoff | git status 干净 | 0.2 天 |

总估时:**3-7 天**(看 A1-4b 诊断结果)。

## 验收标准

- web_client vitest 不破坏(数量可调,可能有新 prefab 测试加几条)
- scene_server / movement_core 测试不破坏(prefab catalog 改了 fixture 要更新)
- gate_server / world_server / data_service 不破坏
- 手动 demo 5 条体验全过:
  1. 拿 prefab → 举起来看到 sphere/cylinder/stairs **线框** preview
  2. 放下去 → 客户端渲染出来跟 preview **形状一致**
  3. 在已有 prefab 上再放 → 服务端拒绝,HUD 提示
  4. 跳一下 → apex 1.2m,着地不抖
  5. Arc Slash 打 prefab → 看到 debris 飞溅,part destroyed flash

## 进度日志

- 2026-05-09:决策稿起草。用户已授权直接开干(不再单独 review),边做边纠偏。
