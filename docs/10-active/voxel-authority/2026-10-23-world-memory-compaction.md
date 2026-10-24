# 2026-10-23 World 常驻内存收紧与安装世代盒戳

---
status: active
owner: VoxelRegion.World（canonical 体素、属性行与世代）；协议字段 owner mmo_contracts Voxel.Codec
protocol: Hello 41 → 42（仅 D3）
---

## 目标

如园（约 1000 万格盒、416 万微格槽、767 个拼装件定义）经 `World.parcel_install` 迁入青岚后，World 必须能在生产容器
3.9 GiB 上限内稳定启动、做周期检查点，并让玩家进入如园时窗口属性快照保持字节级而非数十 MB。

不改世界真值的语义（唯一例外见 D3 决策项 1，需用户批准），不加兼容层、兜底或开关。

## 实测基线

副本 `voxim-qinglan-ruyuan-20261023`（镜像为本仓 ffa336c7 构建，seq 14615，15 批如园已装、液体静止）。
探针与原始输出在 Voxim `Saved/Playtest/release-20261023/`（`Server/heap_probe.ex`、`heap-probe.json`、副本内 `/demo/boot-heap-3.txt`）。

World 进程堆 1269 MB（`erts_debug:flat_size` 按字段；另 536 MB refc 二进制在堆外）：

| 字段 | 堆 MB | 内容 |
|---|---|---|
| refined | 310 | 30 822 宏格 / 4 165 644 槽，`%{cell => %{slot => {material, {birth, occ}}}}` |
| entries | 309 | 检查点事务从任务进程复制回来后常驻（epochs 第二份 + 属性行） |
| epochs | 276 | 4 692 422 条 `cell => seq`，几乎全部由安装写入 |
| prefabs | 239 | 其中 `definition.cells/macro_cells` 解码列表 236 MB（3 414 727 格）；`nodes` 已是二进制（2.6 MB 堆 + 58.6 MB 堆外） |
| region_bases / refined_encoded / damage | 48 / 39 / 32 | |

启动：World 堆在 1.26↔2.07 GB 间反复 GC，`erlang:memory(total)` 1 s 采样最高约 4 GB，beam VmHWM 6.49 GB；稳态 2.1–2.3 GB。
检查点：每轮重编 145 个区域（image 15–29 s），重写库内前缀约 52 MB（区域 16 MB + 元数据 36 MB，元数据主要是 epochs）。

窗口：玩家位于 (3988, 300, 163)，`CollisionStream.box(_, 1)` = tile [61,3,1]–[64,6,4]，属性快照含 1 969 651 条 epochs
（`PropertyBatch.epochs` 20 B/条 ≈ 37.6 MB）与 83 672 条属性行，World 组装 0.74 s。真实客户端尚未进过如园，此项未在客户端复现。

## 开工前自查

1. **对外不变量**：宏格被替换即换世代（`Tools.damage_geometry` 注释：“Macro epochs track replacement even back to the same material”）；
   属性行键含 incarnation（`Damage.key/1`），旧世代的行不得落到新块上；工具会话以 `incarnation` 防 ABA（`Tools` `hit.incarnation == request.incarnation`）；
   客户端以同一世代把属性行配到目标（Voxim `VoxelDamageState`）。这些不变量的 owner 仍是 World，本稿只改表示。
2. **依赖的契约**：客户端依赖 PropertyBatch 给出窗口内全部非零世代；Scene Replica 依赖快照与事务里的 epochs（`replica.ex`）。
   D3 改为“窗口内稀疏世代 + 与窗口相交的盒戳”，两端同一取值函数，协议 42 显式切换，无旧版兼容。
3. **正交性**：D1/D2/D4 只改 World 内部表示，不影响 Scene、Gate、客户端；D3 触及属性观察协议，但不改动移动、碰撞、载荷字节。
4. **红鲱鱼排除**：峰值不是液体（已在液体静止后检查点下复测）；不是检查点 DB 写入（persist 1–2 s）；是大堆 GC 与跨进程复制。

## 依据与取舍

- Erlang/OTP 官方《Efficiency Guide — Constructing and Matching Binaries》：不超过 64 字节的 heap binary 存在进程堆、
  GC 与发消息时复制；更大的 refc binary 本体“stored outside all process heaps”，堆上只有 ProcBin。
  <https://www.erlang.org/doc/system/binaryhandling.html>
- Erlang/OTP 官方《ERTS — Garbage Collection》：进程堆是复制式半空间回收（from space → to space，复制完才释放 from space），
  full sweep 同时回收新老堆；off-heap 二进制不复制，只扫 MSO 链减引用。
  <https://www.erlang.org/doc/apps/erts/garbagecollection.html>
  → 对应：常驻堆越大，每次 full sweep 的瞬时峰值约为两份堆；把不可变大块数据放成 refc 二进制即可移出 GC 复制与 `Task` 复制。
  本仓已有先例：`Prefab.definition_geometry` 把 `nodes` 体素存成二进制（注释“避免每次世界 GC 扫描展开坐标”）。
- RocksDB DeleteRange（Meta 工程实现文档）：用带序号的范围墓碑替代逐键墓碑；“A key is covered if it's included in the
  internal key range and has a seqnum less than the tombstone's seqnum”，点查取覆盖它的最大墓碑序号比较。
  <https://github.com/facebook/rocksdb/wiki/DeleteRange-Implementation>，动机见 <https://rocksdb.org/blog/2018/11/21/delete-range.html>
  （逐键墓碑大量堆积拖慢读与回收）。→ 对应 D3：整盒替换写一条带 seq 的盒戳，`epoch_at(cell) = max(稀疏世代, 覆盖该格的最大盒戳 seq)`。
  取舍：RocksDB 的范围墓碑会随 compaction 合并；本稿盒戳数量等于安装次数（如园 15 条），不做合并。

## 决策项

### D1 拼装件定义不常驻解码列表（纯服务端）

`definition` 的 `cells`、`macro_cells` 保留 VXPD 线格式二进制（14 B/格），在仅有的两处读取时解码：
`Prefab.runtime_definition` 展开被引用的子定义（玩家／设计器发布新定义）、`Parcel` 导出（`Prefab.encode`）。
`World.Canopy` 只读 `presentation_bindings`，不受影响。
解码复用现有 `decode_cells`，数据在发布边界已校验，内部解码不重复校验（§2.2-6）。预期 −236 MB 堆。

### D3 安装世代改为盒戳（协议 42，客户端同步）

- 立论：`Parcel.install` 的语义是整盒替换（`target_trees` 清空目标盒内实例，盒内全部格由 parcel 定义），
  所以“替换即换世代”对盒内每一格成立，用一条 `{box, seq}` 表达，不是为大批量另开流水（§2.2-9）。
  **凡整盒替换都走盒戳，不设格数阈值**；普通编辑、拼装件放置仍写稀疏 `epochs`。
- World：新增 `epoch_boxes`（随日志元数据与检查点持久化，回放按 seq 追加）；`Canonical` 提供唯一取值函数 `epoch_at/2`，
  替换现有 `Map.get(state.epochs, cell, 0)`（`canonical.ex`、`parcel.ex` carried_row、`observation.ex` 世代比较）。
- 观察：`PropertyObservation.project` 保留与窗口相交的盒戳；`PropertyBatch` 增加 `epoch_boxes: :bytes`
  （min xyz、max xyz 各 i32，seq u64，共 32 B/条）；Scene Replica 同样持有并用同一取值。
- 客户端：`VoxelGateCodec` 解码新字段，`VoxelDamageState` 的 `Epochs.FindRef(Macro)` 三处换成同一取值。
- 预期：−276 MB 堆，检查点 `entries` 常驻随之降 ~276 MB，元数据 36 MB → 约 1 MB，如园窗口 epochs 37.6 MB → 字节级。
- **需用户批准的语义点 1**：现在安装只给“值或归属有变”的格换世代；盒戳会让盒内等值格也换世代，
  这些格上原有的目标侧属性行（如自然地形的损伤／温度）随安装移除，由 parcel 携带的源侧属性行替代。
  这与“整盒替换”一致，但是可观察差异。
- **需用户批准的点 2**：协议 41 → 42，客户端与服务端、发布清单同时更新并重建（Voxim AGENTS 分发规则）。

### D2 检查点事务不常驻完整元数据（条件项）

`finish_checkpoint` 后 `retain_entry` 对检查点事务只留区域条目与投影字段，元数据按需从日志读（沿用无格事务的
`entries_after` 做法）。D3 落地后该常驻约剩 30 MB，**D1+D3 实测后仍超预算才做**。

### D4 refined 改为每格槽记录二进制（条件项）

以 `MmoContracts.Voxel.Refined.slot_records/1`（16 B/槽，持久化的区域载荷本就是此格式）为唯一存储，删除 `refined_encoded`；
World 内约 50 个读点经 `Canonical` 取槽函数解码。预期 −349 MB 堆、+64 MB 堆外。
取舍：World 内存表示与线格式绑定（线格式变更时需同改），每次读取解码（需射线／`target_at` 基准）。**D1+D3 实测后仍超预算才做。**

### 不做

增量检查点（只重编变化区域、库端按区域替换）：省 CPU/IO，对内存帮助小，且改持久化语义；无当前需求，不做。

## 对功能设计目标的影响

- 不变：世界真值与权威裁决、材料／热量守恒账、属性行与 HP／温度显示、工具会话防 ABA、液体／热／魔法、载荷字节与碰撞。
- 安装（`Parcel.install`，只经维护 rpc，玩家不可触发）：盒内等值格的目标侧属性行改为随安装移除，
  更贴合迁移设计“目标盒整体换成地块内容”（Voxim `Docs/Playtest/terrain-transplant-design.md`）；移除行的热量照常记入移除账。
- 协议 42：玩家必须更新客户端（发布 41 本已不兼容生产 39，无额外影响）。
- 性能取舍：D1 让发布引用子定义的拼装件时多一次子定义解码；D4（若做）让射线／目标解析每格多一次槽解码；D2（若做）让跨检查点追补从库读元数据。
- 未解决、影响后续内容规模：refined、实例、属性行仍随作者内容线性常驻在单个 World 进程堆里。如园一处约 416 万槽；
  若后续继续迁入圆明园其它景区，D4 大概率需要做，更大规模则要另立区域分页／分片设计，不在本稿范围。
  窗口内 8.4 万条属性行与每笔事务整表写 `prefab_instances`／`attachment_owners` 同样另行处理。

## 测试矩阵

| 项 | 测试 | 期望依据 |
|---|---|---|
| D1 | 导出拼装件定义：`Prefab.encode(definition)` 与原 `.vxpd` 文件字节逐字相等 | 原文件字节 |
| D1 | 既有 prefab / canopy / parcel 套件全过 | 既有用例 |
| D3 | `epoch_at` 手算小例：稀疏 5 + 覆盖盒戳 9 → 9；其后单格编辑 12 → 12；盒外 → 稀疏值；无任何 → 0 | 手算 |
| D3 | 真实 World：盒内损伤行在安装后移除；安装前取得的旧 incarnation 工具请求被拒（ABA） | 契约 |
| D3 | 冷重启：盒戳经日志与检查点恢复，抽样格 `epoch_at` 与重启前相同（场景自产状态再重启） | 重启前观测 |
| D3 | `PropertyBatch` 新字段 golden（服务端）与 Voxim `VoxelM1CodecTests`／`VoxelDamageTests` 同一字节样本 | 冻结样本 |
| D3 | 真实双客户端：均进入安装盒，挖同一安装格，两端属性行 incarnation 一致、HP 一致，逐笔核对事务 | Voxim Testing.md §4 |
| 内存 | 副本按新代码从公网备份重装如园，记录 World 堆分项、启动 VmHWM、周期检查点峰值、如园窗口 PropertyBatch 字节 | 本稿基线 |

既有失败（ffa336c7 上同样失败，不计入本稿）：body_contact_world_test 10 项、thermal_edit_world_test 2 项、
thermal_domain_equivalence 1 项、generated_store “native returns the existing raw payload body”。

## 验收（门槛待用户批准）

- 启动 beam VmHWM 与周期检查点峰值 ≤ 3.0 GiB（3.9 GiB 上限留 0.9 GiB 给同机 Scene 节点与分配器）。
- 如园中央窗口 PropertyBatch 中 epochs + epoch_boxes ≤ 64 KB。
- 双客户端行为验收通过；开发期在 Windows 原生服务端验证，分发彩排才用镜像。

## 进度日志

- 2026-10-23：完成实测与本稿。用户已定不带如园发布、先做重构；待批准 D3 语义点 1、协议 42 与验收门槛后开工，顺序 D1 → D3 → 实测 → 视结果 D2/D4。
- 2026-10-24：用户明确目标是超大世界（近景窗口处处如园级复杂度）内存稳定。本稿只降常数、不改“常驻随世界累计内容线性增长”的斜率，
  不满足该目标；暂停开工，D1／D3／D4 待并入区域分页设计后重排。
- 2026-10-24：区域分页稿 [2026-10-24-world-region-paging.md](2026-10-24-world-region-paging.md) 接管执行顺序：D1 随 M3，D3 并入 N1，D4 即区域页内 refined 格式，D2 被脏页检查点取代。
