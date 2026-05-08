# Phase 4 — Object provenance、局部破坏与整体销毁

## 这一阶段在解决什么问题

Phase 3 / 3-bis 已经做完"放置 prefab"事务化:玩家提交 `0x67 PrefabPlaceIntent`,
World 起一笔事务,Scene 把蓝图占用的微格写进 chunk 真相,客户端看到房子立起来。

但**这些微格目前是"无主"的**:写下去之后,系统只知道"这个槽是混凝土材质",
不知道这个槽来自哪一栋房子、哪一个 part(部件)。这意味着:

- 玩家拿斧子砍房子,服务端只能按"独立微格"算,无法触发对象级反馈
- 没有"血条"语义,战斗节奏不可控
- 想"删掉整栋 7 号房子"必须扫整张 chunk 表反推
- 未来加门、机关、装备脚下的魔法阵时,没有挂载点

Phase 4 把"对象 / 部件"语义补回 chunk 真相,**并把破坏路径一次做闭环**:
微格视觉破坏 + part 血条兜底 + 整 part 死 + 整对象死。

> 本稿基于用户审稿后的决策(2026-05-08):破坏机制采用**方案 E + E1**——
> 微格视觉破坏 + part 血条独立累计,health 归零强制清剩余 mask。
> 这条路径**把"整体销毁"拉进了 Phase 4**(原稿留 Phase 5),
> 因为 part_destroyed → object_destroyed 在状态机上是自然推论,
> 拆开做反而割裂。

> 协议设计文档(`docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`)
> 第 8 节(蓝图 / 对象 / 来源追踪)和第 11 节(`voxel_scene_objects` 表)
> 已经把数据形态钉死。本阶段是**把这个形态从"协议占位符"落地到运行时与持久化**,
> 并在协议预留的 `PartDefinition` / `state_flags` 上补一层运行时血条。

## 术语速查

| 术语 | 通俗解释 |
| --- | --- |
| **macro / 宏格** | 体素世界基本格子。一个 chunk = 16×16×16 = 4096 个宏格。 |
| **micro / 微格** | 宏格内部的细分小格。一个宏格 = 8×8×8 = 512 个微格。 |
| **chunk** | 一个 16×16×16 宏格组成的方块,持久化、订阅、网格化的最小单位。 |
| **prefab / blueprint(蓝图)** | 可复用的"建筑模板",定义"这个房子由哪些微格、哪些部件构成"。 |
| **part(部件)** | 蓝图内部的语义子结构,比如"墙"、"屋顶"、"柱子"、"门"。一个蓝图含多 part。 |
| **object instance(对象实例)** | 玩家放下一次 prefab,产生一条对象实例;有自己的 `object_id`、状态、生命周期。 |
| **owner_object_id / owner_part_id** | 每个微格层(MicroLayer)上挂的两个回指字段:这个微格来自哪个对象、哪个部件。 |
| **provenance(来源追踪)** | 上面那对回指字段构成的语义:从一个微格反查所属对象/部件。 |
| **ObjectCoverRef** | 一个宏格内的索引:对象 X 的 part Y 在我这个宏格里覆盖了哪些微格。 |
| **ChunkObjectRef** | 一个 chunk 内的索引:对象 X 在我这个 chunk 里覆盖到哪个宏格包围盒。 |
| **SceneObjectInstance** | 整个对象的真相记录:`object_id`、所属蓝图、世界锚点、`part_states`、覆盖了哪些 chunk。 |
| **PartState(本阶段新引入)** | 单个 part 的运行时状态:`part_id`、`health`、`state_flags`(damaged / destroyed)。 |
| **微格破坏(局部)** | 玩家攻击 → 清单个 micro 的 mask(视觉缺口);part.health 同步累计伤害。 |
| **part 死** | `part.health <= 0` → 强制清该 part 剩余所有 micro 的 mask + 标 destroyed。 |
| **object 死** | 一个对象**所有** part 都 destroyed → 整对象终态:删行 + 广播 + 清 ChunkObjectRef。 |
| **方案 E / E1** | 微格视觉 + part 血条兜底,damage 累计与微格清除独立(不按比例追踪)。 |

## 已有底盘(Phase 1–3-bis 留下的)

- `MicroLayer` struct 已含 `owner_object_id u64` / `owner_part_id u32`,
  codec 已编/解。
- `RefinedCellData.object_refs`(`ObjectCoverRef[]`)字段已在,
  `Storage.remove_micro_slot/2` 已经维护:破微格时同步 prune mask + 丢空 refs
  (`apps/scene_server/lib/scene_server/voxel/storage.ex` L482–L514)。
- `ChunkStorage.object_refs`(`ChunkObjectRef[]`)字段已在,但**目前从未被写入**。
- `0x6C ObjectStateDelta` wire 操作码已 spec(协议 §12.4),codec 未实现。
- 协议 §11 已定义 `voxel_scene_objects` 表 schema(列拆法、bytea 列等),
  Postgres 表 / Ecto schema / Store 都还没建。
- Phase 3 `BuildTransaction` intents 目前不带 `owner_object_id`(默认 0),
  因此现在所有放进去的 prefab 微格在真相里都是无主。
- 协议 §8.1 `BlueprintDefinition.part_definitions[]` + `PartDefinition.flags`
  已定义,但 `PartDefinition` 当前**没有 `default_health` 字段**——本阶段不改协议,
  health 由 SceneServer 端按"该 part 占用的初始 micro 数 × ratio"推导(D6)。

## 目标(本阶段交付)

1. **`voxel_scene_objects` 表落地**:Postgres 表 + Ecto schema + Store。
2. **`object_id` 分配路径**:World coordinator 在 begin_transaction 阶段
   申请 `object_id`(Postgres SEQUENCE 全局单调),写进
   `BuildTransaction.scene_objects` 字段,随事务一起持久化。
3. **prefab 放置时写入 owner**:`BuildTransaction` intents 全量带
   `owner_object_id` + `owner_part_id`,Storage 写微格层时落到 `MicroLayer`
   和 cell 级 `ObjectCoverRef`。
4. **chunk 级 `ChunkObjectRef` 维护**:ChunkProcess commit 后由当前 layers
   推导 `ChunkObjectRef[]`,写回 `ChunkStorage.object_refs`,
   `chunk_hash` 自然反映来源变化。
5. **per-scene `ObjectRegistry` GenServer**:在 SceneServer 内承载活跃
   `SceneObjectInstance`(含 `PartState[]`)的内存真相;启动时从 Postgres load。
6. **反向查询 API**:`Storage.lookup_owner_at(chunk_storage, macro_idx, slot_idx)`、
   `ObjectRegistry.lookup_object/2`、`ObjectRegistry.list_objects_in_chunk/2`。
7. **damage 累计路径**:`break_micro_block` intent commit 后,
   ChunkProcess 推算出受影响的 (object_id, part_id),通知 ObjectRegistry
   `accumulate_damage(object_id, part_id, 1)`(本阶段每破 1 micro = 1 damage)。
8. **part_destroyed 闭环**:`part.health <= 0` → ObjectRegistry 触发
   `destroy_part(object_id, part_id)`,通过 ChunkProcess 批量清该 part 在所有
   chunk 内的剩余 mask + 标 PartState `destroyed`。
9. **object_destroyed 闭环**:对象所有 part 都 destroyed →
   `voxel_scene_objects` 删行 + ObjectRegistry 移除 + 广播 ObjectStateDelta(`destroyed`)+
   各 chunk ChunkObjectRef 同步清除。
10. **`0x6C ObjectStateDelta` wire 编码 + 服务端发送**:覆盖 part 状态变化、
    object 状态变化、微格破坏摘要。
11. **客户端 web_client 解码 stub**:本阶段只解码 + console log,不消费成可视。

## 不在范围内(显式归属,留 Phase 5+)

- **damage 数值化**:武器伤害值、爆炸 AOE 半径、暴击系数等。本阶段每破 1 micro
  恒定 = 1 damage,武器属性/伤害模型留 Phase 5 跟属性目录一起做。
- **`PartDefinition.default_health_ratio` 协议字段**:本阶段 ratio 走 SceneServer
  全局默认(D6 推荐 1.0),不改协议。Phase 5 蓝图持久化时把字段加进 `PartDefinition`。
- **结构完整性 / 悬空检测 / 塌陷规则**:柱子 part 死后屋顶悬浮就悬浮,
  不会自动塌。这是 Phase 5+ 规则系统范围,无论 part 还是 micro 路径都要做。
- **掉落物 / 任务系统钩子 / 资源回收**:object_destroyed 触发的下游事件
  (掉什么物品、刷新任务进度、释放 attribute/tag 引用计数)。本阶段
  destroy 闭环只到"删行 + 广播",不挂下游钩子。
- **`0x6B ObjectAction`**(玩家点击门、拉机关):本阶段对象只能被攻击,
  不能交互。
- **`voxel_blueprints` 表 / 蓝图持久化**:本阶段假设蓝图来自既有内置目录,
  不引入持久化的玩家蓝图。
- **对象级 attribute / tag overrides**:`SceneObjectInstance.object_attribute_ref` /
  `object_tag_set_ref` 字段保留但本阶段不写入也不读取,留 Phase 5。
- **跨 region 多 participant prefab**:承袭 Phase 3-bis 不在范围。
- **per-region coordinator / coordinator HA**:Phase 6。
- **bevy_client**:已冻结(2026-05-07 起),不动。
- **微格 hit detection / 落点计算**:本阶段沿用 Phase 1c 的 `break_micro_block`
  intent(客户端报 (chunk, macro_idx, slot_idx)),不引入服务端 raycast。

## 决策项(待审,逐条给推荐值)

> 每条标注 **推荐值** + **理由** + **替代被否**。用户审完一次性确认 →
> 进度日志记 D1–D11 推荐值生效 → 才动 Step 1 代码。

### D1:`voxel_scene_objects` 表 schema

新表 schema(列名/类型对齐协议设计 §11 + Phase 3-bis 风格):

```sql
CREATE TABLE voxel_scene_objects (
  object_id              BIGINT      NOT NULL,
  logical_scene_id       BIGINT      NOT NULL,
  parcel_id              BIGINT      NOT NULL,
  blueprint_id           BIGINT      NOT NULL,
  blueprint_version      INTEGER     NOT NULL,
  anchor_world_micro_x   BIGINT      NOT NULL,
  anchor_world_micro_y   BIGINT      NOT NULL,
  anchor_world_micro_z   BIGINT      NOT NULL,
  rotation               SMALLINT    NOT NULL,
  owner_actor_id         BIGINT      NOT NULL,
  state_flags            INTEGER     NOT NULL DEFAULT 0,   -- damaged / destroyed 等
  object_attribute_ref   INTEGER     NOT NULL DEFAULT 0,
  object_tag_set_ref     INTEGER     NOT NULL DEFAULT 0,
  covered_chunks         BYTEA       NOT NULL,             -- term_to_binary([{cx,cy,cz}, ...])
  part_states            BYTEA       NOT NULL,             -- term_to_binary([%PartState{}, ...])
  object_version         BIGINT      NOT NULL,
  inserted_at            TIMESTAMPTZ NOT NULL,
  updated_at             TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (object_id),
  CONSTRAINT scene_objects_logical_scene_unique UNIQUE (logical_scene_id, object_id)
)
CREATE INDEX scene_objects_logical_scene_lookup ON voxel_scene_objects(logical_scene_id);
```

`PartState` Elixir struct(运行时):

```elixir
%PartState{
  part_id: 3,
  health: 50,
  state_flags: 0,   # bit 0: damaged, bit 1: destroyed
}
```

**推荐**:
- 单列主键 `object_id`,`(logical_scene_id, object_id)` UNIQUE 兜底
- `covered_chunks` 与 `part_states` 都用 `bytea + term_to_binary`(对齐 Phase 3-bis fence_payload)
- 不上 wire 不需跨语言

**理由**:
- `object_id` 在协议中是全局 `u64`,走全局主键最直接
- 服务器端 blob 用 `term_to_binary` 与 fence_payload 同风格,不引入第三种序列化
- `part_states` 与对象 1:1 同生命周期,内嵌而非拆表

**替代被否**:
- `BIGSERIAL`:否决,`object_id` 必须在 begin_transaction 就分配(D2)
- `part_states` 拆 `voxel_scene_object_parts` 关联表:否决,1:1 同生命周期不值得拆
- `covered_chunks` 用 PG 数组列:否决,Ecto 索引/迁移更折腾

### D2:`object_id` 分配 — Postgres SEQUENCE,coordinator 同步获取

```sql
CREATE SEQUENCE voxel_scene_object_id_seq START 1 INCREMENT 1;
```

World coordinator 处理 `begin_transaction` 时:

1. 从 prefab placement intent 提取需创建的 object 数(一般 1)
2. 同步 `SELECT nextval('voxel_scene_object_id_seq')` 拿 `object_id`
3. **同时**根据蓝图 `part_definitions` 计算每个 part 的初始 health(D6),
   组装初始 `part_states`
4. 把 `(object_id, blueprint_id, ..., covered_chunks, part_states)`
   塞进 `BuildTransaction.scene_objects: [ObjectAllocation]`
5. intents 内每条带 owner 的微格写入操作携带 `object_id` + `part_id`

**推荐**:Postgres sequence + begin_transaction 同步申请。

**理由**:
- `object_id` 必须**单调可恢复**:crash 后 Watcher resume commit 不能重新分配
- Postgres sequence 跨进程跨节点天然单调
- 申请失败 → begin_transaction reject,Gate 返回 `:object_id_unavailable`

**替代被否**:
- 内存计数器 + 落盘:否决,跨重启 / 跨 coordinator 不安全
- Snowflake/UUID:否决,协议钉死 `u64`
- 各 ChunkProcess 自己申请:否决,跨 chunk 对象会得到不同 ID

### D3:`BuildTransaction.scene_objects` 字段持久化

`BuildTransaction` struct 加新字段:

```elixir
defstruct [
  :transaction_id,
  ...,
  :state,
  intents_by_participant: %{},
  scene_objects: []   # 本笔事务要创建的对象实例
]

%ObjectAllocation{
  object_id: 42,
  blueprint_id: 7,
  blueprint_version: 1,
  parcel_id: 13,
  anchor_world_micro: {x, y, z},
  rotation: 0,
  owner_actor_id: 1001,
  covered_chunks: [{0, 0, 0}, {0, 0, 1}],
  part_states: [%PartState{part_id: 1, health: 80, state_flags: 0}, ...],
  state_flags: 0
}
```

随既有 `voxel_transaction_coordinator_snapshots` 单行 snapshot 一起落盘
(对齐 Phase 3-bis 的 `intents_by_participant` 处理)。

**推荐**:跟 `intents_by_participant` 同行落盘,不开新表。

**理由**:同生命周期 + 同 commit/abort 边界 + Phase 3-bis 已建立的"transaction
内嵌附属数据"模式。

**替代被否**:独立表 `voxel_transaction_scene_objects`:否决,理由同 Phase 3-bis D2。

### D4:per-scene `ObjectRegistry` GenServer

新模块 `apps/scene_server/lib/scene_server/voxel/object_registry.ex`:

- 每个 `logical_scene_id` 一个 GenServer,通过 BeaconServer 注册
- state:`%{object_id => SceneObjectInstance.t()}`(其中含 `part_states`)
- 启动时从 `voxel_scene_objects` LOAD 该 scene 的所有对象
- API:
  - `lookup_object(server, object_id)`
  - `list_objects_in_chunk(server, chunk_coord)`
  - `upsert_object(server, instance)`(写内存 + 同步 INSERT/UPDATE Postgres)
  - `apply_chunk_cover_change(server, object_id, chunk_coord, kind)`(`:add` / `:remove`)
  - `accumulate_damage(server, object_id, part_id, damage)` — **新**(D7)
  - `destroy_part(server, object_id, part_id)` — **新**(D8)
  - `destroy_object(server, object_id)` — **新**(D9)
  - `snapshot(server)`(测试/dump)

**推荐**:per-scene GenServer + 同步落盘。

**理由**:
- 反向查询(`lookup_object`、`list_objects_in_chunk`)是 ObjectStateDelta
  广播的依赖,需低延迟
- 与 ChunkProcess 解耦:ChunkProcess 是 chunk 级真相;ObjectRegistry 是
  scene 级对象索引

**替代被否**:
- 每个 object 一个 GenServer:否决,启动开销 + supervision 复杂度
- 不用 GenServer,直接每次查 Postgres:否决,反向查询频次高

### D5:owner 写入时机 — coordinator commit_decision 之后由 ChunkProcess 应用

事务路径:

1. `begin_transaction`:coordinator 申请 `object_id` + 算 part_states,塞进 `scene_objects`
2. `prepare_transaction`:Scene 端 ChunkProcess 收到 intents(每条已带
   `owner_object_id` + `owner_part_id`),只校验 + 起 fence,不写真相
3. `commit_decision`:coordinator 决策 commit
4. `commit_transaction`:Scene 端 ChunkProcess apply intents 到 storage,
   `MicroLayer` 写入时 owner 字段自然落盘
5. **新增**:commit 后 ChunkProcess 调 `Storage.refresh_chunk_object_refs/1`
   重算 `ChunkStorage.object_refs`(D10)
6. **新增**:commit 后 ChunkProcess 调 `ObjectRegistry.upsert_object/2`
   (该对象首次落地)+ `apply_chunk_cover_change/3`(若是后续 chunk 加入)
7. **新增**:ObjectRegistry 持久化到 `voxel_scene_objects`
8. **新增**:广播 `ObjectStateDelta`(`created` 形态)

**推荐**:owner 写入与既有 commit apply 路径一致;新增聚合 + 落盘只挂在
"commit 后"事件钩子。

**理由**:不破坏 Phase 3 prepare/commit 双相提交。

**替代被否**:
- prepare 阶段就写入 chunk_object_refs:否决,prepare 不变更真相
- 每条 intent apply 后增量维护:否决,中间状态 cleanup 复杂

### D6:`PartState.health` 初始值规则 — `micro_count × ratio`,ratio 全局默认 1.0

每个 part 创建时 `health` 计算公式:

```elixir
@default_health_ratio 1.0   # SceneServer 全局常量
health = floor(part_initial_micro_count * @default_health_ratio)
```

`part_initial_micro_count` = 该 part 在蓝图 occupancy_layers 内 mask_words
统计的 1-bit 总数(蓝图固定值,可在蓝图加载时预算)。

**推荐**:
- 本阶段 `@default_health_ratio = 1.0`(打掉所有 micro 才能让 part 死)
- 配置位置:`apps/scene_server/lib/scene_server/voxel/part_state.ex` 模块属性
- Phase 5 引入 `PartDefinition.default_health_ratio` 协议字段,改成 per-part

**理由**:
- ratio = 1.0 时,Phase 4 实际行为退化为"全微格清除才 destroy",
  跟纯 A 路径**功能等价**——但 PartState/destroy 状态机的代码通道全部就位
- Phase 5 调小 ratio(比如 0.6)立即生效"打 60% 微格 → 整 part 倒"的设计意图
- 不改协议(留蓝图持久化阶段一并做),避免本阶段动协议波及 wire 兼容性

**替代被否**:
- ratio = 0.6 默认:否决,本阶段没有掉落物 / 任务钩子,part 倒了之后行为
  比较裸,先用 1.0 看通路再调
- ratio 配置写 application config:否决,改 ratio 需要 Phase 5 上协议字段,
  写 application config 反而留多一处迁移负担
- health 走纯 micro count 不引入 ratio 参数:否决,通道里至少要有 ratio
  这个旋钮,否则 Phase 5 retrofit 又要改 PartState struct 形态

### D7:damage 累计路径 — `break_micro_block` commit 后由 ChunkProcess 推算

当前 Phase 1c 的 `break_micro_block` intent 已经能清单微格 mask + cell 级 prune。
本阶段在 ChunkProcess commit 完成后**新增**:

1. 遍历本批 commit 的 intents,对每个 `break_micro_block` op 取 commit 前
   的 cell snapshot,查出该 slot 原 owner_object_id + owner_part_id
2. 按 (object_id, part_id) 聚合 damage 计数(每破 1 个 micro = 1 damage)
3. 调 `ObjectRegistry.accumulate_damage(object_id, part_id, count)`
4. ObjectRegistry 累计到 `PartState.health`,如果 `health <= 0` → 触发 D8

**推荐**:
- ChunkProcess 在 commit 路径**同步**触发 ObjectRegistry,不走异步队列
- 每破 1 micro = 1 damage,武器属性/AOE 留 Phase 5
- 如果 break 的 micro 是无主的(`owner_object_id == 0`),什么都不做

**理由**:
- 同步触发简单可观察,不引入额外消息通道;ObjectRegistry 操作内存 +
  Postgres UPDATE,延迟可接受
- 1 micro = 1 damage 是 Phase 4 简化前提;Phase 5 改 damage 数值化时,
  intent 形态加 `damage_amount` 字段,这条路径替换为读取 intent 字段

**替代被否**:
- 异步队列 / pub-sub 推 damage:否决,引入额外通道,本阶段 commit 频率不高
- damage 在 prepare 阶段累计:否决,prepare 可能 abort
- 整 micro batch 累计 → 一次 ObjectRegistry call:**采纳**(已含在推荐里,
  按 (object_id, part_id) 分组 batch)

### D8:`part_destroyed` 闭环 — 强制清剩余 mask + 标 destroyed

ObjectRegistry 检测到 `part.health <= 0` 时:

1. 把 `PartState.state_flags` 置 `destroyed` 位 + 写入 Postgres
2. 找出该 part 在 ObjectRegistry 端记录的 `covered_chunks`(交集:对象
   covered_chunks ∩ 该 part 实际涉及的 chunk;后者从蓝图静态可推)
3. 对每个相关 chunk 调 `ChunkProcess.destroy_part/3`(新 API):
   - 输入:`(object_id, part_id)`
   - ChunkProcess 扫该 chunk 内所有 cell 的 `cell.object_refs`,找
     `owner_object_id == X && owner_part_id == Y` 的 mask
   - 对每个 mask 调 `Storage.remove_micro_slot/2` 批量清(已有路径)
   - commit 后再次走 D5 步骤 5(`refresh_chunk_object_refs`)+ D10 广播
4. 触发 `ObjectStateDelta`(`part_destroyed` 形态,带 affected_chunks)

**推荐**:`destroy_part` 走和正常 commit 一样的 ChunkProcess 路径,
不绕过 fence 机制。

**理由**:
- 清 mask 复用既有 Storage API,无新代码路径
- ChunkProcess 单进程串行化,destroy_part 与正常 break_micro 不会 race

**替代被否**:
- ObjectRegistry 直接改 ChunkProcess state:否决,违反进程边界
- destroy_part 跳过 fence:否决,可能与正在 prepare 的事务冲突

### D9:`object_destroyed` 闭环 — 整对象终态

ObjectRegistry 在 `destroy_part` 后检查:对象**所有** `PartState.state_flags`
都标 `destroyed` → 触发 `destroy_object`:

1. 删 `voxel_scene_objects` 行
2. 从 ObjectRegistry 内存移除
3. 对每个 `covered_chunks`,调 `ChunkProcess.cleanup_object_refs/2`
   (扫 chunk 级 `ChunkObjectRef[]` 移除该 object_id 项)
4. 广播 `ObjectStateDelta`(`destroyed` 形态)

**推荐**:**真删行**,不留僵尸。

**理由**:
- 微格层 + cell 层 + chunk 层的 owner 痕迹在 D8 part_destroyed 时已清完;
  到 D9 时 chunk 真相里这个 object 已经不存在,只剩 `voxel_scene_objects`
  一行 + ChunkObjectRef 摘要 → 删掉是正确终态
- 对象级下游事件(掉落、任务、资源回收)虽然是 Phase 5+,但 D9 留
  `voxel_object_destroyed` observe 信号,Phase 5 接钩子时挂在这个 observe 上即可

**替代被否**:
- 留 tombstone(只标 destroyed 不删):否决,跟 Phase 4 把闭环做完的目标矛盾
- 异步删除(标 destroyed 后定时清):否决,本阶段无对象级下游事件,可以同步删

### D10:`ChunkObjectRef[]` 重算 — commit / destroy_part / destroy_object 三个时机

`Storage.refresh_chunk_object_refs/1`:

```elixir
@spec refresh_chunk_object_refs(ChunkStorage.t()) :: ChunkStorage.t()
```

实现:

1. 扫 4096 个 macro_header,找 `kind == :refined` 的
2. 每个 refined cell 读 `cell.object_refs`(`ObjectCoverRef[]`)
3. 按 `object_id` 聚合,记录每个 object 在 chunk 内的 macro 包围盒(min/max)
4. 计算 `cover_hash`(协议 §12.3 规范编码 xxHash64)
5. 写回 `ChunkStorage.object_refs: [ChunkObjectRef.new(...)]`

调用时机:

- D5 commit 后(prefab 放置 / break_micro)
- D8 destroy_part 后
- D9 destroy_object 走的 chunk 清理后

**推荐**:整 chunk 重算(不增量维护)。

**理由**:每 chunk 内 cell 4096,object 稀疏(典型 < 10),全扫成本微秒级,
远低于 INSERT/UPDATE Postgres 的开销。

**替代被否**:增量维护:否决,簿记复杂度不值。

### D11:`0x6C ObjectStateDelta` wire 编码 + 服务端发送

协议 §9 已定义 `ObjectStateDelta`。本阶段服务端广播形态:

```text
ObjectStateDelta {
  logical_scene_id    u64
  object_id           u64
  object_version      u64
  state_flags         u32             # 含 created / damaged / destroyed 位
  attribute_patch     AttributePatch[]   # 本阶段固定空
  tag_patch           TagPatch[]          # 本阶段固定空
  affected_chunks     ChunkCoord[]
}
```

广播触发点:

- D5 prefab 放置 commit 后(`state_flags |= CREATED`)
- D7 damage 累计后,如果 part 进入 damaged 状态(`state_flags |= DAMAGED`)
- D8 part_destroyed 后(`state_flags |= PART_DESTROYED`)
- D9 object_destroyed 后(`state_flags |= DESTROYED`)

**注意**:`PartState[]` 不上 wire(协议 §9 没有这个字段);客户端要看具体哪个
part 状态,本阶段无法。Phase 5 引入 part 级 wire 字段时再补。本阶段 wire
只表达"对象整体经历了状态变化"。

**推荐**:
- web_client 端只解码 + console log,不消费成可视
- `attribute_patch` / `tag_patch` 全空(Phase 5)
- `affected_chunks` 装本次受影响的 chunk_coord 列表

**理由**:打通 wire 通道,不引入未规划字段,后续 part 级可视化能 retrofit。

**替代被否**:
- 完全不上 wire:否决,0x6C 是协议规划入口
- 加非协议字段(part_id 等):否决,Phase 4 不动协议

### D12:测试矩阵

新增 / 扩展的 ExUnit 测试:

- `apps/data_service/test/data_service/voxel/scene_object_store_test.exs`(新):
  - put / get / delete / list_in_scene
  - `covered_chunks` + `part_states` term_to_binary roundtrip
  - 唯一约束 `(logical_scene_id, object_id)`
  - `next_object_id` sequence 单调

- `apps/scene_server/test/scene_server/voxel/storage_object_refs_test.exs`(新):
  - `refresh_chunk_object_refs/1`:多 cell 多 object 聚合 + 包围盒 + cover_hash
  - 破微格后重算:`:removed` / `:updated` diff
  - `lookup_owner_at/3`(反向查询)

- `apps/scene_server/test/scene_server/voxel/object_registry_test.exs`(新):
  - 启动 LOAD 该 scene 所有对象
  - `upsert_object/2`、`apply_chunk_cover_change/3`
  - `accumulate_damage/3`:health 累计、跨 batch 累计
  - `destroy_part/2`:health <= 0 时触发,标 destroyed,清剩余 mask
  - `destroy_object/2`:所有 part destroyed 触发,删行 + 广播

- `apps/scene_server/test/scene_server/voxel/chunk_process_object_provenance_test.exs`(新):
  - prefab 放置 commit 后 `MicroLayer.owner_object_id` 落盘
  - commit 后 `ChunkStorage.object_refs` 含正确 ChunkObjectRef
  - 破微格 commit 后 cell + chunk 级 refs 同步 + ObjectRegistry damage 累计
  - `destroy_part/3`:批量清剩余 mask + ChunkObjectRef 移除该项
  - `cleanup_object_refs/2`:整对象死时清 ChunkObjectRef

- `apps/scene_server/test/scene_server/voxel/object_lifecycle_integration_test.exs`(新):
  - 端到端:prefab 放置 → 攻击直到 part1 死 → 攻击直到 part2 死 → 整对象 destroyed
  - 中间状态:多 part 对象只死一个 part,其它 part 仍 alive
  - 多 chunk 对象:某 chunk 内全部 micro 清光但其它 chunk 还在,对象 covered_chunks 缩,不死

- `apps/world_server/test/world_server/voxel/transaction_coordinator_object_alloc_test.exs`(新):
  - begin_transaction 申请 `object_id` 单调
  - `BuildTransaction.scene_objects`(含 `part_states`)reload 完整保留
  - `:object_id_unavailable` 兜底

- `apps/gate_server/test/gate_server/codec/object_state_delta_test.exs`(新):
  - 0x6C encode/decode roundtrip
  - 各 state_flags 组合 + `affected_chunks` 多 chunk

- `clients/web_client/src/infrastructure/net/__tests__/objectStateDelta.test.ts`(新):
  - decode 0x6C → console log,不影响 chunk snapshot/delta 流

不补跨进程 e2e harness(继续 park 在 Phase 2 决策稿 backlog)。

## 高层步骤(每 step 单独 commit)

每个 Step 单独 commit。Elixir 改前 `mix format`;web 改前 `cd clients/web_client && npx tsc --noEmit && npx vitest run`。

| Step | 范围 | 验收信号 |
| --- | --- | --- |
| 4-1 | `DataService.Schema.VoxelSceneObject` Ecto schema + migration `voxel_scene_objects` 表 + sequence + `DataService.Voxel.SceneObjectStore`(stateless module:`put_object/2`、`get_object/2`、`delete_object/2`、`list_in_scene/2`、`next_object_id/1`、`reset/1`)+ `scene_object_store_test` | data_service 53 → 60+ tests;表迁移幂等(up/down 各跑一遍),sequence 单调 |
| 4-2 | `Storage.refresh_chunk_object_refs/1` + `Storage.lookup_owner_at/3` + `storage_object_refs_test` | scene_server +N tests,Storage 既有用例零退化 |
| 4-3 | `PartState` struct + `SceneServer.Voxel.ObjectRegistry` GenServer 基本 API(`lookup` / `list_in_chunk` / `upsert` / `apply_chunk_cover_change`)+ 启动 LOAD + `object_registry_test`(基本 API 部分) | per-scene registry 用 BeaconServer 注册成功;启动 LOAD 用例覆盖 |
| 4-4 | `BuildTransaction.scene_objects` 字段(含 `part_states`)+ `TransactionCoordinator.begin_transaction` 内 `next_object_id` + `compute_initial_part_states/1`(按蓝图 occupancy 推 health × ratio=1.0)+ reload 测试 + `transaction_coordinator_object_alloc_test` | world_server +N tests;`:object_id_unavailable` 兜底通过 |
| 4-5 | intents 形态扩 `owner_object_id` / `owner_part_id`(默认 0,prefab 路径填实)+ ChunkProcess commit 后调 `refresh_chunk_object_refs/1` + 通知 ObjectRegistry diff(`upsert` + `apply_chunk_cover_change`)+ `chunk_process_object_provenance_test` 基本路径 | scene_server +N tests,Phase 3 既有 prefab 用例零退化 |
| 4-6 | `ObjectRegistry.accumulate_damage/3` + `destroy_part/2` + `destroy_object/2` + `ChunkProcess.destroy_part/3` + `cleanup_object_refs/2` + `object_registry_test`(damage / destroy 部分)+ `chunk_process_object_provenance_test`(destroy 部分) | scene_server +N tests,part/object 终态闭环 |
| 4-7 | `object_lifecycle_integration_test`:prefab 放置 → 攻击 → part_destroyed → object_destroyed 全链路 + multi-part 中间状态 + multi-chunk covered_chunks 缩 | scene_server +N tests,端到端用例全绿 |
| 4-8 | 0x6C `ObjectStateDelta` codec encode/decode + `object_state_delta_test` + ws/tcp dispatch(server-only)+ ChunkProcess 在 D5/D7/D8/D9 触发广播验证 | gate_server +N tests;codec roundtrip 全绿 |
| 4-9 | web_client `objectStateDelta.ts` decoder + console log + `objectStateDelta.test.ts` + `tsc --noEmit && vitest run` | web_client 210 → 215+ vitest;tsc clean |
| 4-10 | docs 同步:`apps/scene_server/lib/scene_server/voxel/README.md`、`apps/world_server/lib/world_server/voxel/README.md`、`apps/data_service/lib/data_service/voxel/README.md`、`docs/voxel-server-authority/README.md` 阶段表 Phase 4 = 已完成 + `_session-handoff.md` 更新。决策稿进度日志补每 step RFC + commit hash | 文档与代码一致;阶段表更新到位 |

## 验收

- mix test 全 umbrella 全绿(预存失败 `authority_observe_test.exs:35` Windows 大小写不算回归)
- `cd clients/web_client && npx tsc --noEmit && npx vitest run` 全绿
- prefab 放置 commit 后:`SceneObjectInstance` 已落盘(含初始 `part_states`);
  `MicroLayer.owner_object_id` 在 chunk 真相中可见;`ChunkStorage.object_refs` 已聚合
- 破单 micro:cell.object_refs 自动 prune;chunk 级 ChunkObjectRef 同步;
  ObjectRegistry 累计 damage 到 part.health;若 health > 0 → 仅微格变化
- `part.health <= 0`:剩余 part mask 一次性清光;`PartState.state_flags |= destroyed`;
  广播 `ObjectStateDelta`(part_destroyed)
- 所有 part destroyed:`voxel_scene_objects` 删行;ObjectRegistry 移除;
  各 chunk `ChunkObjectRef` 移除该 object;广播 `ObjectStateDelta`(destroyed)
- coordinator 重启后 `BuildTransaction.scene_objects`(含 `part_states`)reload 完整保留;
  Phase 3-bis 的 :prepared resume 路径 commit 出来的对象同样落盘正确
- 多 part 对象只死一个 part 时,其它 part 仍 alive,对象不死
- 多 chunk 对象某 chunk 全 micro 清光但 part 未死时,covered_chunks 不变(`MicroLayer`
  在其它 chunk 还在);part 死时 covered_chunks 同步缩

## 风险

- **`object_id` sequence 在 Postgres 主从切换 / 备份恢复**:恢复点之后 sequence
  可能回滚但已下发的 object_id 已在内存 / 客户端缓存。本阶段不做 HA sequence,
  运维文档需写明"备份恢复后 manual `setval()`"。Phase 6 per-region coordinator
  时考虑分布式 sequence。
- **`refresh_chunk_object_refs/1` 在 chunk 内 4096 cell 全扫**:典型 chunk 只有
  少量 refined cell,扫成本可控;极端 chunk 全 refined 时聚合达 ms 级。本阶段
  不优化,Phase 5 加 hot-path 监控。
- **`ObjectRegistry` 启动 LOAD 整 scene 所有对象**:对象数量级 N=1000 启动
  +50ms OK;N=100k(玩家长期建筑)需要分页 LOAD 或 lazy。本阶段不分页,
  埋测试预警 + 文档标"启动慢 → 看 N"。
- **`PartState.health` 与微格 mask 双状态可能漂移**:理论上 D7 同步累计,D8
  health 归零 → 强制清 mask;但若 ObjectRegistry crash 在两步之间,health 写盘
  但 mask 没清 → 残留 micro。本阶段加 `ObjectRegistry` 启动时的 reconcile
  扫 PartState.destroyed 对应的 chunk 看是否有残留 mask,有则补清。
- **damage 累计在 commit 同步路径**:break_micro batch 大时,ObjectRegistry
  Postgres UPDATE 多次,可能拖慢 commit。本阶段按 (object_id, part_id)
  分组 batch 一次 UPDATE,不会一次 UPDATE 一行。
- **scene_objects 在 BuildTransaction abort 时,sequence 已 next**:abort 不
  回滚 sequence,浪费 object_id。`u64` 空间 9e18 无修复需要。
- **0x6C 客户端不消费**:本阶段只到 wire 通道。Phase 5 客户端引入消费时,
  若有人提前依赖 wire 字段未来变更,会有兼容压力。本阶段 0x6C wire 严格
  按协议 §9 发,不擅自加非协议字段。
- **ratio=1.0 让 part 死的体验等价于 A 路径**:本阶段产品上看不出 E 与 A 的
  差别,直到 Phase 5 调小 ratio。这是预期权衡——通道先打通,数值后续调。
- **本阶段无结构完整性 / 塌陷**:柱子 part 死后屋顶悬浮,视觉上奇怪但不阻断
  玩法。Phase 5 规则系统补。

## 进度日志

- 2026-05-08:决策稿初稿(方案 B / 纯 part 血条)入仓审稿
- 2026-05-08:用户审后改方案 E + E1(微格视觉 + part 血条独立累计)。
  整体销毁闭环拉进 Phase 4。决策稿重写,等待 D1–D12 推荐值确认。
- 2026-05-08:用户确认 D1–D12 推荐值生效,决策稿入仓 commit `067085f`。
- 2026-05-08:**Phase 4 全程落地**(object provenance + part-health 破坏闭环 + 整体销毁)。
  - **Step 4-1**(commit `df1ba93`):新建 `voxel_scene_objects` schema +
    migration + sequence + `DataService.Schema.VoxelSceneObject` Ecto schema +
    `DataService.Voxel.SceneObjectStore`(stateless module:`put_object/2`、
    `get_object/2`、`delete_object/2`、`list_in_scene/2`、`next_object_id/1`、
    `reset/1`)。`covered_chunks` + `part_states` 用 `term_to_binary` 编码,
    反序列化用 `[:safe]` 模式。data_service:53 → 71 tests。
  - **Step 4-2**(commit `95a3330`):`Storage.refresh_chunk_object_refs/1`
    整 chunk 重算 cell + chunk 级 object refs(xxHash64 cover_hash 走规范
    编码:object_id::u64 ++ AABB::6×u8 ++ macro_count::u32 ++
    [(macro_idx::u16, mask_words[8 × u64])])。`Storage.lookup_owner_at/3`
    反向查询。scene_server:277 → 293 tests。
  - **Step 4-3**(commit `f61351c`):`SceneServer.Voxel.PartState` struct +
    flag bit 常量 + `apply_damage/mark_damaged/mark_destroyed` helpers。
    `SceneServer.Voxel.ObjectRegistry` GenServer 基本 API:`lookup_object/3`、
    `list_objects_in_chunk/3`、`upsert_object/2`、`apply_chunk_cover_change/5`、
    `load_scene/2`(lazy)、`snapshot/1`、`reset/1`。`covered_chunks` 收缩到
    空集 → `:covered_chunks_would_be_empty` 错误提示走 destroy_object。
    scene_server:293 → 309 tests。
  - **Step 4-4**(commit `686d3cd`):`BuildTransaction.scene_objects` 字段
    (默认 [],持久化随既有 voxel_transaction_coordinator_snapshots 透传)+
    `TransactionCoordinator` `:next_object_id_fn` init opt(默认绑
    `SceneObjectStore.next_object_id`)+ `begin_transaction` 内逐 seed 分配
    object_id + replay 路径跳过 allocation 避免 sequence 浪费 +
    `begin_fingerprint` 不含 scene_objects + `:object_id_unavailable` 兜底。
    world_server:60 → 72 tests。
  - **Step 4-5**(commit `53e4e7d`):`ChunkProcess.apply_normalized_intent` /
    `apply_normalized_intents` 在 build_intent(s)_storage 之后调
    `Storage.refresh_chunk_object_refs/1`(覆盖 direct apply 路径 + batch +
    transaction commit)。`BuildTransactionApplier.register_scene_objects/2`
    把 transaction.scene_objects upsert 到 ObjectRegistry,失败 emit
    `voxel_scene_object_register_failed` 非阻塞。`TransactionExecutor.run_commit`
    在 commit_decision 之后 `function_exported?` 守门 + safely_invoke 调
    scene_caller 的 register_scene_objects。`ChunkProcess.debug_state` 加
    `:storage` 字段方便测试。scene_server:309 → 315 tests。
  - **Step 4-6**(commit `330d528`):破坏闭环全链路。`ObjectRegistry`
    `accumulate_damage/6` + `destroy_part/5` + `destroy_object/4` 同步
    cascade 链。`ChunkDirectory.destroy_part/2` + `cleanup_object_refs/2`
    路由。`ChunkProcess` 同 API + `destroy_part_in_state` 扫所有 refined
    cells 找 owner=X、part=Y layer 逐 micro slot 调 Storage.clear_micro_block。
    `ChunkProcess` apply 路径加 damage attribution:pre-apply
    `lookup_owner_at` 收集 `{(oid,pid) => count}`,post-persist `Task.start`
    异步 dispatch 避免 ChunkProcess→ObjectRegistry→ChunkDirectory→ChunkProcess
    同步 deadlock。emit `voxel_part_damaged` / `voxel_part_destroyed` /
    `voxel_object_destroyed` / `voxel_chunk_destroy_part`。scene_server:
    315 → 328 tests。
  - **Step 4-7**(commit `d800996`):`object_lifecycle_integration_test` 端到端
    用例,真跑 ObjectRegistry + ChunkDirectory + ChunkProcess 三栈无 mock。
    覆盖 single-part full lifecycle 与 multi-part 中间状态。`assert_eventually`
    等异步 Task.start 派发 cascade 收尾。scene_server:328 → 330 tests。
  - **Step 4-8**(commit `0a5b428`):`GateServer.Codec.@msg_voxel_object_state_delta`
    = 0x6C + encode/decode roundtrip + truncated header / truncated chunks
    rejection 测试。**实际通过 Gate 订阅者推送链路 deferred 到 Phase 4.5 /
    Phase 5**(decision doc D11 显式允许这种分阶段)。gate_server:181 → 188 tests。
  - **Step 4-9**(commit `5352040`):`clients/web_client/src/infrastructure/net/objectStateDelta.ts`
    decoder + console.log stub + 反向查 attributePatchCount / tagPatchCount
    forwards-compat 用例。web_client:210 → 216 vitest tests,tsc clean。
  - **Step 4-10**(本 commit):docs 同步:
    `apps/scene_server/lib/scene_server/voxel/README.md`、
    `apps/world_server/lib/world_server/voxel/README.md`、
    `apps/data_service/lib/data_service/voxel/README.md`、
    `docs/voxel-server-authority/README.md` 阶段表 Phase 4 = 已完成 +
    `_session-handoff.md` 更新到 Phase 4 末态。

**RFC 备注 / 实施期偏离**:

- D11(0x6C wire)实施时仅落 codec encode/decode + web_client decoder stub,
  服务端 → Gate 订阅者实际推送链路标为 Phase 4.5 / Phase 5 backlog。原因:
  scene_server → gate_server 没 dep,跨 app 推送需要新 ChunkProcess /
  ChunkDirectory broadcast API 配套,且与 Phase 5 attribute_patch / tag_patch
  填充强耦合;Phase 4 的核心(object provenance + part-health 状态机 + 整体
  销毁)已经全链路落地,wire 通道也已打通,推送只是把 ObjectRegistry 端的
  observe 转成订阅者消息,机械工作。

- 未在决策稿中显式但实施时确认的小决策:
  - `ObjectRegistry` 默认 module-named singleton,tests 通过 `:name` opt
    起独立实例(对齐 ChunkDirectory 风格)
  - `ChunkProcess` 加 `:object_registry` / `:chunk_directory` init opts
    默认 `SceneServer.Voxel.{ObjectRegistry, ChunkDirectory}`,tests 注入
    stub。无 ObjectRegistry 进程时 dispatch_damage_async 内部 `try/catch :exit`
    静默吞掉,best-effort。
  - `ChunkProcess.destroy_part` 通过 state.lease 持久化(server-internal 操作
    不走 user lease validate,但仍用当前 lease 作为持久化身份);state.lease
    为 nil 时 `persist_snapshot` 返 `:missing_lease`,destroy_part 链路自然
    fail-fast。
  - `MicroLayer.attribute_signature` 已经包含 owner_object_id /
    owner_part_id(Phase 1c 既有),所以同 owner 的 micros 自动合并成一个
    layer,ObjectCoverRef 重建只产生 |distinct part| 个条目。
