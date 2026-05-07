# Phase 1a — RefinedCellData typed domain (read-only wire)

## 目标

把服务端 chunk truth 中的 `refined_cells` 从"占位空池"升级为**强类型 domain + 双端 wire codec**,但**不改变运行时行为**:

- Storage 字段类型从 `[term()]` 收紧到 `[RefinedCellData.t()]`。
- Codec section `0x03 (refined_cells)` 由 `encode_empty_pool_*` 升级为可往返编解码;不再硬性要求空池。
- TS `voxelProtocol.ts` 同步:`SnapshotSection.RefinedCells` 从 `ensureEmptyPool` 升级为真正解码,落到 `ChunkSnapshot.refinedCells`。
- chunk_hash 自动覆盖 refined section(`encode_chunk_truth_payload` 里那一段从空池替换成新编码)。
- Scene 仍**不产生**任何 refined cell——本阶段服务端没有 refined mutation API,意图是:链路准备好,但不踩进新行为。

## 不在范围内

- 不引入新的 normalize_operation 操作类型(`put_micro_block` 等留给 1c)。
- 不改 Gate `VoxelImpactIntent` 语义。
- 不改 `OnlineVoxelWorldAdapter.placeMicroBlock / breakMicroBlock` 的 `rejectServerOnlyEdit` 行为。
- 不动 Phoenix LiveView 可视化层。
- 不实现 attribute_sets / tag_sets 的 typed domain(留给 1b 或独立切片)。

## 决策项(已定稿)

> 决策 1 与决策 2 在 2026-05-07 的复核中按 [`2026-04-29-server-authoritative-voxel-data-protocol-design.md`](../2026-04-29-server-authoritative-voxel-data-protocol-design.md) §5.4 / §5.6 / §12.3 重写;原"dense bitmap + 平行数组 + cell 级 owner"的草案已废弃。决策 3 不变。后续偏离需在进度日志显式记录 RFC,并先回滚相关测试再修改。

### 决策 1:wire 压缩策略 — **layered occupancy(occupancy_words u64[8] + MicroLayer[] + ObjectCoverRef[] + boundary_cache)**

完全采用协议设计文档 §5.4 的"位掩码 + 层"模型:

```text
RefinedCellData {
  occupancy_words   u64[8]              // 8 个 u64 = 512 位,锁定 micro_resolution=8
  layers            MicroLayer[]        // 共享 (material/state/owner/...) 的 slot 合并到一层
  object_refs       ObjectCoverRef[]    // object → mask 的反向索引
  boundary_cache    u64
}
```

字段说明严格对齐文档,不另作裁剪。同 cell 内不变量:

1. `occupancy_words` 必须等于所有 `layers[*].mask_words` 的按位 OR。
2. 同一 micro slot 在同一 cell 内只能归属一个有效 layer。
3. prefab / 组合体写入 truth 时必须保留 `owner_object_id / owner_part_id`。
4. 多个 slot 共享同一 (material, state_flags, health, attribute_set_ref, tag_set_ref, owner_object_id, owner_part_id) 时必须合并成同一层。

理由:

- 文档已经给出明确的 wire 形,以协议设计文档为准是 CLAUDE.md 的硬性纪律。
- v1 锁 `micro_resolution = 8` 的前提下,`occupancy_words u64[8]` 是定长 64 字节,序列化无须处理变长 mask。
- 层模型在 prefab 满铺场景下比平行数组更紧凑(一份共享属性 + 一组 mask 即可),也直接为 Phase 4 的 slot-level owner 留好结构。
- `boundary_cache u64` 是 fast-path 的边界摘要,可由 layer 数据重建,但缓存能降低吸附 / 邻区摘要 / AOI 过滤的成本(文档 §5.4)。

CellRefined delta 形式不在 1a 锁定,留给 1c 决策(候选:整 cell 重发 vs. layer-diff)。

### 决策 2:v1 字段集 — **完全对齐协议文档,不引入额外字段**

`RefinedCellData` 在 1a 的 Elixir/TS domain **不引入文档之外的字段**。下表为最终版字段集(替换原草案):

#### `RefinedCellData`

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `occupancy_words` | `<<_::8*8*8>>` 或 `[0..0xFFFF_FFFF_FFFF_FFFF, 8]` | 该 cell 总占用 mask;长度严格 8 个 u64 |
| `layers` | `[MicroLayer.t()]` | 稀疏层数组 |
| `object_refs` | `[ObjectCoverRef.t()]` | object/part → mask 反向索引 |
| `boundary_cache` | `0..0xFFFF_FFFF_FFFF_FFFF` | 边界摘要,可由 layer 重建 |

#### `MicroLayer`

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `mask_words` | 8 个 u64 | 该层覆盖的 slot mask |
| `material_id` | `0..0xFFFF` | 材质 |
| `state_flags` | `0..0xFFFF_FFFF` | 状态位集 |
| `health` | `0..0xFFFF` | 微格层耐久 |
| `attribute_set_ref` | `0..0xFFFF_FFFF` | 属性集合引用,0 = material/default |
| `tag_set_ref` | `0..0xFFFF_FFFF` | 标签集合引用,0 = material/default |
| `owner_object_id` | `0..0x7FFF_FFFF_FFFF_FFFF`(线格式 u64,持久化按 v1 ≤ 2^63-1 约束) | 对象 id;0 = 地形/无对象 |
| `owner_part_id` | `0..0xFFFF_FFFF` | 部件 id;0 = 无部件 |

#### `ObjectCoverRef`

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `owner_object_id` | `0..0x7FFF_FFFF_FFFF_FFFF` | 被索引对象 |
| `owner_part_id` | `0..0xFFFF_FFFF` | 被索引部件 |
| `mask_words` | 8 个 u64 | 该对象/部件在当前 cell 内覆盖的 slot |

#### **明确不进 1a domain 的字段**(与原草案的差异)

| 草案字段 | 处理 | 理由 |
| --- | --- | --- |
| `local_macro` | 移除 | 由 `MacroCellHeader.payload_index` 索引 RefinedCellData,不在 cell 自身字段中 |
| `micro_resolution` | 移除 | 仅在 `ChunkStorage` 顶层,v1 固定 8;cell 级冗余会和顶层漂移 |
| `cell_hash u32`(在 RefinedCellData 内) | 移除 | 文档 §5.4 第 436 行明确"细分格不再单独维护 local_version,统一使用 `MacroCellHeader.cell_version`/`cell_hash`",cell-level 哈希永远走 macro header |
| 平行数组 `slot_material_ids[] / slot_state_flags[] / slot_part_refs[]` | 移除 | 替换为 `layers[*]` 共享属性 + 自带 mask |
| cell 级 `owner_object_ref u32` | 移除 | owner 在 layer 级(`MicroLayer.owner_object_id u64` + `owner_part_id u32`),slot-level owner 通过 layer mask 自然支持,不再"留给 Phase 4" |

### 决策 3:chunk_hash 空池兼容 — **不可妥协的回归红线(对齐协议 §12.3)**

文档 §12.3 第 1472 行明确 `chunk_hash` 覆盖"普通块、细分格、环境摘要、对象引用、属性集合和标签集合"。当前 `refined_cells` 在所有真实场景中均为 `[]`,因此 1a 改造的硬约束:

> **对所有 `refined_cells: []` 的 storage,改造前后 `chunk_hash` 必须 byte-for-byte 一致。**

落实办法:

1. **改造前**先跑一次 fixture pin 脚本(`priv/scripts/pin_chunk_hash_baseline.exs` 或一次性 `iex`)将下列代表性 storage 的 chunk_hash 打印并提交为常量:
    - 空 chunk(只有 macro headers 全部默认)
    - dev seed chunk(`SceneServer.Voxel.SeedTerrain` 当前产出)
    - 含若干 normal blocks 与 environment summary 的混合 chunk
2. 在 `codec_test.exs` 里钉死回归用例:

    ```elixir
    test "chunk_hash byte-stable for empty refined storage across 1a refactor" do
      assert Codec.chunk_hash(empty_baseline_storage()) == 0x????_????_????_????
      assert Codec.chunk_hash(seed_baseline_storage())  == 0x????_????_????_????
      assert Codec.chunk_hash(mixed_baseline_storage()) == 0x????_????_????_????
    end
    ```

3. PR 必须先建立这条测试(用改造前的实际 hash 数字),再开始重写 encoder。任何改动导致该测试红 → 改 encoder,**不能改测试常量**。
4. 同时在 codec_test 中加 "新 encoder 在 `refined_cells: []` 上的 emit 与 `encode_empty_pool_for_truth(_, :refined_cells)` 的旧 emit byte-for-byte 一致" 的 byte-level 比对测试,作为更直接的失败定位。
5. 同步检查:文档 §12.3 第 1472 行还要求 chunk_hash 覆盖 attribute_sets / tag_sets / object_refs。当前 `encode_chunk_truth_payload/1`(codec.ex:644)已经分别 emit 这些 section,1a 不动它们的 encoder,留作 1b 之后的独立审计。

### Storage 兼容

旧 `refined_cells: [term()]` 历来都是 `[]`,因此可以直接收紧到 `[RefinedCellData.t()]` 而不需要双类型并存。`Storage.normalize!/1` 中需要新增"如果元素已经是 struct 直接通过,否则尝试从 map cast"的路径,以兼容 fixture / 持久化 blob 反序列化。

## 文件清单

### 新增 — Elixir

- `apps/scene_server/lib/scene_server/voxel/refined_cell_data.ex`
  - `defstruct` + `@type t`(字段 `occupancy_words / layers / object_refs / boundary_cache`)
  - `new/1` / `new!/1` 构造
  - `from_map/1`(用于 codec / fixture / 持久化反序列化)
  - `to_map/1`(用于 observe / debug)
  - `validate!/1`,执行四条不变量:
    1. `occupancy_words` 长度严格 8;每个 word 在 `0..0xFFFF_FFFF_FFFF_FFFF`
    2. 所有 `layers[*].mask_words` 按位 OR 等于 `occupancy_words`
    3. 任意 slot 在所有 `layers[*].mask_words` 中只出现一次(无重叠)
    4. `object_refs[*].mask_words` ⊆ `occupancy_words`(对象覆盖只能在已占用 slot 上)

- `apps/scene_server/lib/scene_server/voxel/micro_layer.ex`
  - `defstruct` + `@type t`
  - `from_map/1` / `to_map/1`
  - `validate!/1`:`mask_words` 长度严格 8;字段值在范围内

- `apps/scene_server/lib/scene_server/voxel/object_cover_ref.ex`
  - `defstruct` + `@type t`
  - `from_map/1` / `to_map/1`
  - `validate!/1`:`mask_words` 长度严格 8;`owner_object_id > 0`

- `apps/scene_server/test/scene_server/voxel/refined_cell_data_test.exs`
  - 字段范围校验
  - `from_map` ↔ `to_map` roundtrip
  - 不变量 1-4 全部覆盖正负样例(合法接受 / 违反时 raise)
  - 多层共享同一组属性时拒绝(规则 4 — 必须合并)

- `apps/scene_server/test/scene_server/voxel/micro_layer_test.exs`
  - 字段范围 / mask 长度 / from_map ↔ to_map roundtrip

- `apps/scene_server/test/scene_server/voxel/object_cover_ref_test.exs`
  - 字段范围 / owner_object_id 必非 0 / mask 长度 / from_map ↔ to_map roundtrip

### 修改 — Elixir

- `apps/scene_server/lib/scene_server/voxel/storage.ex`
  - `refined_cells` 类型从 `[term()]` 改为 `[RefinedCellData.t()]`
  - `normalize!/1` 中对每个元素 `RefinedCellData.from_map/1`(已是 struct 跳过)
  - 默认值仍为 `[]`,无行为变化

- `apps/scene_server/lib/scene_server/voxel/codec.ex`
  - 替换 `encode_empty_pool_for_truth(storage.refined_cells, :refined_cells)` 为 `encode_refined_cell_pool_for_truth/1`
  - 替换 `encode_empty_pool_for_wire(storage.refined_cells, :refined_cells)` 为 `encode_refined_cell_pool/1`
  - 新增 `decode_refined_cell_pool!/2` 并接到 snapshot section 解码器
  - 顶部 `@moduledoc` 中"refined cells ... limited to empty pools"说明删除或改为"refined cells now have wire encoding; mutation paths still pending(Phase 1c)"

- `apps/scene_server/test/scene_server/voxel/codec_test.exs`(若已存在;否则新建对应文件)
  - section `0x03` 编/解 roundtrip
  - 含 refined cell 的 snapshot 全量 roundtrip
  - chunk_hash 在含 refined cell 时与空 refined 时不同
  - 旧空池 fixture 解码不破坏(向后兼容)

- 任何引用 `encode_empty_pool_for_truth` / `encode_empty_pool_for_wire` 的文档注释一并修订

### 新增 — TypeScript

- `clients/web_client/src/infrastructure/net/refinedCellWire.ts`(可与 voxelProtocol.ts 合并,但单独文件更便于测试隔离)
  - `RefinedCellWire` 类型
  - `decodeRefinedCellPool(buffer, opts): RefinedCellWire[]`
  - `encodeRefinedCellPool(cells): Uint8Array`(测试 fixture 用)

- `clients/web_client/src/infrastructure/net/refinedCellWire.test.ts`
  - 双向 roundtrip
  - 与 Elixir 端共享 fixture(见下)读出字段一致

### 修改 — TypeScript

- `clients/web_client/src/infrastructure/net/voxelProtocol.ts`
  - `SnapshotSection.RefinedCells` 处的 `ensureEmptyPool` 改为调用 `decodeRefinedCellPool`
  - `ChunkSnapshot.refinedCells` 类型从 `unknown[]` / `never[]` 升级为 `RefinedCellWire[]`
  - 默认空数组的填充路径保持

- `clients/web_client/src/infrastructure/net/voxelProtocol.test.ts`
  - 加入"含 refined cell"的 snapshot 解码用例

- `clients/web_client/src/voxel/storage/types.ts`、`worldStore.ts`、`worldSnapshot.ts`
  - 仅在类型层把 `refinedCells` 字段类型从占位升级到真实类型
  - 运行时仍当 `[]` 处理(在线模式 server 不发,离线模式不动)

### 新增 — 共享 fixture

- `apps/scene_server/test/fixtures/voxel/refined_512_cell_v1.bin`(二进制 RefinedCellData,含 layers + object_refs)
- `apps/scene_server/test/fixtures/voxel/refined_512_cell_v1.json`(同内容的人读版,便于 review)
- `clients/web_client/test/fixtures/voxel/refined_512_cell_v1.bin`(由 Elixir 端脚本生成后拷贝)

> 文件名来自协议设计文档 §13 的样例清单(第 1914 行 `refined_512_cell_v1.bin`),保持名称一致以便日后样例哈希校验对齐。

约定:fixture 由一个独立脚本(`mix voxel.gen_fixture` 或 `priv/scripts/gen_refined_chunk_fixture.exs`)生成,而不是手工维护字节;脚本内容受版本控制。

## 改动点逐条说明

1. **Storage 字段升级是无破坏改动**:历史上该字段都为 `[]`,因此现有所有持久化 blob、测试 fixture、wire payload 都不会改变 byte。新增 typed normalize 只在非空场景生效。

2. **chunk_hash 行为变化**:对**当前所有运行场景**(refined 为空)hash 不变,因为新 encoder 在空 list 上的输出与旧 `encode_empty_pool_for_truth(:refined_cells)` 的空池输出**必须保持一致**。这是 1a 的硬约束,需要在 codec_test 中加 regression 测试:`chunk_hash(empty_storage_pre_change) == chunk_hash(empty_storage_post_change)`。

3. **TS `refinedCells` 类型变化是 API 表层的**:目前没有运行时消费者(在线模式 server 不发,离线模式不走 wire),因此类型升级不会触发 UI 回归。

4. **观测面留位**:本阶段不动 observe 字段,但要在 `chunk_process.ex` 的快照构造日志里把 `refined_cell_count` 留个口子(默认 0),为 1c 提前准备。

5. **catalog 不动**:section `0x04 attribute_sets` / `0x05 tag_sets` 在 1a **不动**,继续 `encode_empty_pool_*`。下次切片(1b 或独立 1a-bis)再处理。

## 测试矩阵

| 测试 | 类型 | 文件 | 目的 |
| --- | --- | --- | --- |
| RefinedCellData 不变量 1-4 | ExUnit | `refined_cell_data_test.exs` | occupancy = OR(layer masks);层间 mask 不重叠;object_refs ⊆ occupancy;长度=8 |
| 规则 4 (层合并)拒绝 | ExUnit | 同上 | 两层属性完全相同时拒绝构造,提示合并 |
| MicroLayer 字段验证 | ExUnit | `micro_layer_test.exs` | mask 长度;range;roundtrip |
| ObjectCoverRef 字段验证 | ExUnit | `object_cover_ref_test.exs` | owner_object_id≠0;mask 长度;roundtrip |
| codec section 0x03 roundtrip | ExUnit | `codec_test.exs` | layered RefinedCellData encode → decode 字段位级一致 |
| snapshot 含 refined 全量 roundtrip | ExUnit | 同上 | 经过 sections 容器后字段一致 |
| chunk_hash 空池兼容(三套 baseline) | ExUnit | 同上 | empty / dev seed / mixed 三组 storage 改造前后 hash 完全一致 |
| 空 refined byte-level 兼容 | ExUnit | 同上 | 新 encoder 在 `[]` 上的 emit 与旧 `encode_empty_pool_for_truth` byte-for-byte 一致 |
| chunk_hash 含 refined 时不同 | ExUnit | 同上 | 加入 RefinedCellData 后 hash 与空时不同 |
| Storage normalize! 接受 typed list | ExUnit | `storage_test.exs`(若存在) | struct list 通过;map list 自动 cast;非法 raise |
| TS decodeRefinedCellPool roundtrip | Vitest | `refinedCellWire.test.ts` | encode → decode 字段位级一致 |
| TS voxelProtocol section 0x03 解码 | Vitest | `voxelProtocol.test.ts` | 共享 fixture decode 后字段一致 |
| 双端共享 fixture 一致性 | ExUnit + Vitest | `refined_512_cell_v1.bin` | 相同 bin 文件 Elixir/TS 解码后所有字段对齐(含 layers / object_refs / boundary_cache) |
| 现有 voxel 回归 | ExUnit / Vitest | 既有 | 所有现存 voxel 测试不变 |

## 验收标准

- `mix compile` 全 umbrella 通过,无新增 warning。
- `cd apps/scene_server && mix test --no-start` 全部通过,新增覆盖前述 ExUnit 测试。
- `cd clients/web_client && pnpm test`(或 npm/yarn 对应)全部通过,新增覆盖前述 Vitest 测试。
- 手工注入一个 refined cell 的 snapshot 经 Elixir encode → TS decode,所有字段位级一致(可由 fixture roundtrip 用例覆盖)。
- 在线模式 Web CLI 仍能正常进入场景;HUD `voxel_sync=server-authoritative` 不变;`placeMicroBlock` 仍返回 `micro_place_not_supported_by_server`(1a 不解锁该路径)。
- chunk_hash 对空 refined 的所有现有 fixture 保持二进制一致(回归测试钉死)。

## 风险

- **风险:fixture 漂移**。共享 fixture 由 Elixir 端脚本生成;TS 端只消费,不再独立生成。脚本必须 idempotent 且受 CI 验证(后续可加 `mix voxel.verify_fixture` 任务)。
- **风险:wire 决策被上游协议设计文档否决**。开工第一步必须复核 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`;若已存在与本计划冲突的 refined wire 描述,以该文档为准并在本计划进度日志记录修订。
- **风险:hash 常量被错误地"修正"**。`chunk_hash` 回归测试中的常量是 1a 改造前真实 hash,任何后续 PR 修改这些常量等价于声明"我故意改变了 wire byte"。必须 PR review 时显式审核。

## 进度日志

- 2026-05-07: **Phase 1a 加固通过**,自查后修补 5 个隐患,scene_server 202/202;web_client 148/148。
  - 加固 #1(协议正确性):`RefinedCellData.normalize!/1` 现在按 `attribute_signature` 字典序排 `layers`、按 `(owner_object_id, owner_part_id)` 排 `object_refs`,等价语义 cell 必产相同 wire bytes / 相同 chunk_hash。文档 §12.3 "规范编码"约束在 1a 钉死,1c 写 mutation 路径时不会因 list 顺序漂移导致客户端缓存失效。
  - 加固 #2(协议正确性):`RefinedCellData.normalize!/1` 拒绝 ghost layer(`mask_words` 全 0)。空 layer 占 92 字节 wire 改变 hash,允许它就允许任意填充攻击。
  - 加固 #3(协议正确性):`RefinedCellData.normalize!/1` 拒绝 ObjectCoverRef 同 `(owner_object_id, owner_part_id)` 重复(必须先 OR 合并 mask),并拒绝 mask 全 0 的 ref。
  - 加固 #4(API 一致性):`Codec.decode_refined_cell_pool/1` 加 dual-form,返 `{:ok, _} | {:error, _}`;`!/1` 仍 raise。符合 Elixir 惯例。
  - 加固 #5(测试纪律):`codec_test.exs` 新增 "fixture is in sync with the generator script" 兜底 — 测试运行时按生成脚本逻辑重建字段,encode 后与磁盘 fixture byte 比对。两边 drift 必红,杜绝 fixture stale。
  - 同时补 `layer_count > 0xFFFF` / `object_ref_count > 0xFFFF` 拒绝路径测试,以及 dual-form decode API 的 `{:ok, _}` / `{:error, _}` / 空池 trailing 三组用例。
- 2026-05-07: **Phase 1a 全部 step 落地**,双端绿(scene_server 190/190;web_client 148/148;tsc --noEmit 通过;umbrella mix compile 干净)。
  - Step 1:`SceneServer.Voxel.RefinedCellData` / `MicroLayer` / `ObjectCoverRef` 三个 domain module + 25 个 ExUnit。四条 §5.4 不变量(occupancy = OR(layer masks)、layer 不重叠、规则 4 强制合并、object_refs ⊆ occupancy)在 `validate_invariants!` 中实现。
  - Step 2:`Storage.refined_cells` 类型从 `[term()]` 收紧到 `[RefinedCellData.t()]`,`normalize_list!` 接 `RefinedCellData.normalize!/1`;运行时无变化。
  - Step 3:三组 baseline(empty / seed / mixed)的 chunk_hash 数字 pin 入 `codec_test.exs` 常量。pin 脚本 `priv/scripts/pin_chunk_hash_baseline.exs` 留作 dev 工具。pinned 值:empty=`0x0980_DF98_C2DA_1FFC`、seed=`0x7B46_B0F3_33B6_3489`、mixed=`0x7491_619E_9791_DFB9`。
  - Step 4:`Codec.encode_refined_cell_pool/1` + `decode_refined_cell_pool!/1` 实现 layered wire form(`occupancy_words u64[8] + boundary_cache u64 + layer_count u16 + layers[] + object_ref_count u16 + object_refs[]`)。空 list 输出 `<<0u32>>` 与旧 `encode_empty_pool_for_*` byte-for-byte 一致 → baseline pin 守住,zero refactor 漂移。`@moduledoc` 同步从"refined cells limited to empty pools"改为"refined cells now have a real wire encoding"。
  - Step 5:TS 端新增 `clients/web_client/src/infrastructure/net/refinedCellWire.ts`(decoder + encoder + 9 个 Vitest);`voxelProtocol.ts` 把 `ensureEmptyPool(SnapshotSection.RefinedCells, …)` 替换为 `decodeRefinedCellPool(…)`,并在 `VoxelChunkSnapshotMessage` 上新增 `refinedCellsWire: RefinedCellWireData[]` 字段(为 1c 之后 CLI 消费做准备;离线 `FRefinedCellData` 不动,在线/离线类型各司其职)。
  - Step 6:共享 fixture `refined_512_cell_v1.bin`(508 字节)双端验证。生成脚本 `priv/scripts/gen_refined_512_cell_fixture.exs` 同时写入 `apps/scene_server/test/fixtures/voxel/` 与 `clients/web_client/test/fixtures/voxel/`。Elixir/TS 双端 decode 字段对齐,encode 回写与 fixture byte-for-byte 一致。
  - 1a 范围内未执行的部分(留给后续阶段):`OnlineVoxelWorldAdapter.placeMicroBlock / breakMicroBlock` 仍 `rejectServerOnlyEdit`(1c);DataService 仍是 `payload :: binary` 整 blob,未拆 schema(1d);Gate `VoxelImpactIntent` 语义未动(1b/1c)。
- 2026-05-07: 复核 `2026-04-29-server-authoritative-voxel-data-protocol-design.md` §5.4 / §5.6 / §12.3 后,**重写决策 1 与决策 2**。
  - 决策 1:wire 形从 "dense bitmap + parallel arrays" 改为协议文档锁定的 "occupancy_words u64[8] + MicroLayer[] + ObjectCoverRef[] + boundary_cache" 层模型;mask 固定 64 字节(锁 micro_resolution=8)。
  - 决策 2:废弃 cell 级 `owner_object_ref u32` 和 "slot 级 owner 留 Phase 4" 的判断 — 文档把 owner 放在 layer 级(`owner_object_id u64` + `owner_part_id u32`),由 layer mask 自然支持 slot-level owner;同时移除原草案的 `local_macro` / `micro_resolution` / `cell_hash` 等错位字段。
  - 决策 3 不变,但补充对齐协议 §12.3 第 1472 行的 chunk_hash 覆盖范围。
  - 文件清单从单 module 拆为 `RefinedCellData` / `MicroLayer` / `ObjectCoverRef` 三个 module;测试矩阵补充层不变量、规则 4 合并约束、对象覆盖 ⊆ occupancy 等检查。
  - fixture 名对齐协议文档样例清单 `refined_512_cell_v1.bin`。
- 2026-05-07: 三项决策初版按"推荐值"定稿(草案,后被复核重写)。
- 2026-05-07: 计划稿成稿。


