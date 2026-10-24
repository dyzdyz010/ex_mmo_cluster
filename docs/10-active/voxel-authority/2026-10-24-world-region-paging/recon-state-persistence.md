# 调研：VoxelRegion.World 状态与持久化（按区域分页决策稿输入）

仓库 `D:\hemifuture\ex_mmo_cluster`，只读调研，源码版本 = 当前工作树（HEAD 之后未改）。
路径缩写（均相对 `apps/voxel_region/lib/voxel_region/`）：

| 缩写 | 文件 |
|---|---|
| W | `world.ex` |
| Log | `world/log.ex` |
| Ed | `world/edits.ex` |
| Pl | `world/payloads.ex` |
| Can | `world/canonical.ex` |
| OL | `overlay_log.ex` |
| OLS | `apps/data_service/lib/data_service/voxel/overlay_log_store.ex` |
| Mig | `apps/data_service/priv/repo/migrations/20260907000001_create_voxel_overlay_log.exs` |
| P | `apps/mmo_contracts/lib/mmo_contracts/voxel/payload.ex` |
| GS | `generated_store.ex` |
| LP | `log_projection.ex` |

“事实”直接来自源码；标“推断”的是由源码推出、未经实测的结论。

---

## 0. 区域尺寸与坐标换算（核实）

- **L0 区域 = 64³ 宏格**（1 宏格 = 1 m），载荷跨度 **66³**（core 64³ + 每侧 1 格 ring），原点 `region×64−1`：P:13 `@extent 66`、P:76 `origin/1`、P:79 `cell_index`（x 最快）、P:82 `local/2`。
- L 级区域同样是 64³ 个“L 级格”（L 级格 = 2^L m），即 L 级区域覆盖 (64·2^L) m 立方；`edit_keys/1` 对每个坐标生成 L0..L5 共 6 个 `{level, region}` 键：Ed:40-45。`@max_level 5`：W:39、Pl:15。
- **64 没有单一常量**，在至少 7 处硬编码：Can:132 `region_of/1`（世界内正式用的那份）、OL:87（私有副本）、LP:9-11/110-112/165、P:76、`attachments.ex:35`（附件按 anchor 微格 `floor_div(x, 64*8)`）、`world/parcel.ex:295-296`、Ed:21-22（`valid_region?`）；`collision_source.ex:9` 用 `Payload.extent() - 2` 推出。另外 Log:98-104 / Log:120-123 回放时用字面量 66 解 core 下标。
- 微格分辨率 8、chunk 16 来自 Voxim 头文件 `VoxelSpatialConstants.h` 的正则解析：`spatial.ex:3-11`。
- ring 规则：一个 L0 格改动影响的区域 = 该格 ±1 后覆盖的所有区域（最多 8 个）：LP:7-13 `region_keys/1`。

---

## 1. World 状态字段全表

状态在 `restore/1` 里一次构造为普通 map：W:528-653。下表列出全部键，外加运行时动态加的 `component_cache`（`world/observation.ex:141`）。

列说明：**增长**：C=常量/配置，P=随在线玩家/连接，H=随历史编辑内容（世界内容），R=随访问过的区域。**可分区**：能否直接按 L0（或 L 级）区域键切分。**持久化**：PG kind（见 §3），或“派生”“不持久”。

### 1.1 来源、缓存与载荷（派生，不是真值）

| 键 (W 行) | 含义 / 形状 | 增长 | 可分区 | 持久化 / 启动恢复 |
|---|---|---|---|---|
| `source`, `source_state` (530-531) | baseline 来源模块（正式 = `GeneratedStore`，`application.ex:40`）及其 store map（manifest、index、counters）：GS:79-90 | C | — | manifest + `baseline/` 磁盘缓存；`source.open/1` W:507 |
| `cv` (532) | content_version u64 | C | — | 由 manifest 推出 GS:56-75 |
| `decoded` (533) | `{level, region} => %Payload{}`：已解码的 baseline 载荷（Can:93-107 写） | **R，没有淘汰**；只有 rebase 删掉（Log:199）；`serve_item` 回调后还原成调用前的 decoded（W:1292），所以浏览请求不会让它增长，编辑/快照/意图会 | 是 | 不持久；按需 `source.read` |
| `region_bases` (534) | `{level, region} => %Payload{}`：检查点区域的地形基底，载荷里的 refined/instances/structure/attachments/liquid/canopy 字段都已清空（Log:190-193） | H（检查点过的区域数） | 是 | kind1 行回放 → `rebase_region` Log:169-205 |
| `snapshots` (535) | `MapSet{level, region}`：凡出过完整后像的区域（后像、结构变化、液体回放、rebase 都会加入：Pl:224、Pl:335、Log:84、Log:144、Log:201） | **H，单调增长，从不移除**（只有 CoarseRebuild 会动） | 是 | 回放 kind1/4/液体时重建 |
| `payloads`, `lru`, `lru_ticks`, `tick`, `lru_bytes`, `resident_bytes`, `cache_limit`, `cache_stats` (536-543) | 载荷缓存 `{level, region} => {bytes, header}`；L0–L3 用 gb_tree 做 LRU，受 `cache_limit` 字节上限约束（默认 512 MiB，W:41/514-519；`config/runtime.exs:179`）；L4+ 常驻，不受上限约束 | L0–L3 **有界**；L4+ 随粗层区域数 | 是 | 不持久（Pl:348-416） |
| `served_headers` (544) | `{level, region} => {seq, hash}`：每个区域最近一次下发的头 | R（下发过的区域，不淘汰） | 是 | 不持久 |
| `liquid_adopted` (559) | `region => payload bytes`：已核对过“无待接纳液体”的载荷字节（`world/liquids.ex:63-70`） | R（不淘汰）。推断：它引用载荷 refc binary，缓存淘汰后这份字节仍被它钉住 | 是 | 不持久 |
| `refined_owners` (548) | `owner(instance id) => MapSet(macro cell)`：派生索引（Can:37-48） | H | **否**（按部件分，一个部件可以跨区域） | 不持久，随 put_refined 重建 |
| `refined_regions` (549) | `L0 region => MapSet(macro cell)`：派生索引 | H | 是（本身就是区域索引） | 同上 |
| `refined_encoded` (551) | `cell => {slots, slot_records_bin}`：refined 槽编码备忘，写入时失效 | H（实测 39 MB） | 是 | 不持久 |
| `component_cache`（observation.ex:141） | `owner => {tag, geometry}`：部件 HP/几何备忘；`prepare_component_cache(state, nil)` 在启动时对全世界跑一遍（W:682） | H | 否（按部件分） | 不持久 |
| `entry_regions` (647) | `{level, region} => gb_tree(seq)`：保留事务的区域序号索引（LP:16-30） | 随保留事务 | 是 | 由 `entries` 派生 |

### 1.2 体素真值（随世界内容增长）

| 键 (W 行) | 含义 / 形状 | 增长 | 可分区 | 跨区域引用 | 持久化 / 启动恢复 |
|---|---|---|---|---|---|
| `overlay` (545) | `{level, cell} => {material, skins}`：稀疏逐格编辑（L0 与 L1–L5 规约结果）；`put_overlay` 写入时同时维护 `overlay_regions` 并让缓存失效（Ed:60-79） | H（不在 snapshot 区域里的稀疏编辑） | 是（L 级区域） | ring：一个格进 1–8 个区域索引 | kind0/kind2 行，回放 Log:72-78、148-160；检查点后在 snapshot 区域里的部分被 rebase 吸收（Log:173-175） |
| `overlay_regions` (638) | `{level, region} => MapSet(cell)`，cell 可能是邻区的 ring 格 | H | 是 | 含邻区格 | 派生自 overlay |
| `refined` (546) | `macro cell => %{slot(0..511) => {material, {birth, occurrence} owner}}`：微格细化（实测 30 822 宏格 / 416 万槽，310 MB） | H | **是**（按 macro cell） | 槽的 owner 指向 `instances`（可能跨区域的部件树） | **只存在于 kind1 L0 区域载荷**：回放 Log:97-108 解 core（1..64）写回 |
| `structure` (625) | `{level≥1, cell} => grid binary`：L1–L5 结构网格，由 refined/附件向上规约（Pl:263-346） | H | 是（L 级区域） | 由 L0 refined 和附件派生 | kind4 行（OL:52）；**检查点不写 kind4**，rebase 还会清掉 `structure`（Log:191），所以重启后必须全量 `refresh_structure` 重算（W:679，见 §2） |
| `instances` (626) | `{birth, occ} => %{definition_id, anchor, orientation, parent_id, component_slot}`：预制件实例树（`mmo_contracts/voxel/refined.ex:100-160`） | H | **否**（树，anchor 能定位区域，但子件/足迹可以跨区） | parent_id 链；被 refined 槽、macro_owners、attachment_owners、damage(g=2) 引用 | **两份**：① L0 载荷里只带“跨度内引用到的 id 及其祖先”（Pl:178-191）；② **每笔 append_log 的 kind3 元数据都带全表** `prefab_instances`（Log:28-36），回放时最后一笔整表覆盖（Log:411） |
| `attachments` (552) | `{kind, axis, anchor_micro} => {attachment_id, material}`：面/棱附件槽 | H | 是：事实归 anchor 所在 core（`attachments.ex:34-35`） | 足迹/支撑会跨 ring；`id` 被 attachment_owners、damage(g=3) 引用 | L0 载荷 `attachments` 字段（`Attachments.extract`，Pl:188），回放时只取 anchor 落在本区的部分（Log:113-118） |
| `attachment_owners` (554) | `aid => {instance_owner, slot}` | H | 否（按 id） | 指向 instances | **每笔 append_log 的 kind3 都写全表**（Log:32；只有 `liquid_journal` 不写，Log:24-25）；回放整表覆盖（Log:396） |
| `attachment_serial` (553) | 附件 id 分配水位 | C | — | — | 每笔 kind3 都写（Log:31） |
| `liquid_units` (556) | `macro cell => units`：有限液体/散体数量 | H | 是 | — | L0 载荷 `liquid_units` 字段（Pl:185-187）+ kind3 增量 `liquid_units`（Ed:364-376；回放 Log:81-86） |
| `liquid_active` (557) | `MapSet(cell)`：待步进液体格 | H/活动 | 是 | — | **每笔 kind3 都写全量列表**（Log:35），回放整表覆盖（Log:399） |
| `macro_owners` (607) | `macro cell => instance id`：宏格归属预制件 | H | 是（按 cell） | 指向 instances | kind3 增量（`production.ex:26-33`）；检查点写全表（Log:316） |
| `placed_by` (606) | `macro cell => cid`：花材料放置者溯源 | H | 是 | 指向角色 | 同上（Log:315） |
| `epochs` (565) | `macro cell => seq`：宏格身份世代（重放到同材质也会换代，`world/tools.ex:480-482`）；**只 merge，从不删除**（Log:393） | **H，单调增长**（实测 469 万条 / 276 MB）。推断：parcel install 给整盒每个变化格都写了世代（`parcel.ex:205-208` + damage_geometry） | 是（按 cell） | — | kind3 增量；检查点写全表（Log:308） |
| `damage` (564) | `Damage.key => property row`：稀疏属性行（HP、温度、燃料、相态焓……）。key 形状：g=0/1/4 → `{g, micro, incarnation, owner, material}`；g=2 → `{2, owner}`；g=3 → `{3, aid}`（`damage.ex:340-342`） | H | g=0/1/4 可以（按 micro 所在区域）；**g=2/3 不行**（部件/附件可以跨区域，行里带 `observation_cells`） | 指向 instances / attachments | kind3 `property_states`（增量；flags==1 表示删除，Log:384-388）；检查点写全量值列表（Log:307） |
| `protection` (609) | `%{regions: id => rect, index: 256m 桶 => [id]}`（`protection.ex:1-30`） | H（少量） | 部分（xz 桶，y 无界） | — | kind3（检查点写 `.regions`，Log:317；回放 `Protection.apply` Log:407） |
| `beacons`, `beacon_attunements` (611-612) | 信标 `id => %{id, name, core, landing}`；`cid => [id]`（`world/beacons.ex:5-8`） | H（少量）/ 随角色 | 信标可按 core 定位；调谐按角色 | — | kind3 增量 + 检查点全表 |
| `seq` (639) | 全局单调事务号 | C | **全局** | — | 回放取最大值（Log:68） |

### 1.3 角色/全局账目（不随空间分布）

| 键 (W 行) | 形状 | 增长 | 持久化 |
|---|---|---|---|
| `material_balances` (580) | `{cid, material} => units` | 随角色 × 材料 | kind3 增量 merge（Log:412-413）；检查点全表 |
| `caster_energy` (582) | `cid => J` | 随角色 | 同上（Log:414） |
| `material_supplies` (597) | `{cid, key} => receipt`（含 parcel/beacon 一次性安装回执 `{0, {:parcel, key}}`） | H | 同上（Log:402） |
| `craft_ledger`, `food_ledger` (601-603) | `material => 累计单位` | C（随材料数） | kind3 整表覆盖（Log:403-404） |
| `food_receipts` (604) | `cid => %{…}`，按 cid 嵌套 merge（`production.ex:21-22`） | 随角色 × 进食次数（推断：不裁剪） | kind3 增量 |
| `phase_inventory` (615) | `{cid, material} => 相态库存` | 随角色 | kind3 merge（Log:401） |
| `material_units_per_micro` (616) | 整数量子 | C | 每笔 kind3 都写（Log:34） |
| `thermal` (567) | `%{config, sources: macro => source, semblances, elapsed_s, supplied_j, …账}`（`world/catalogs.ex:79-81`） | 随活跃热源/拟态 | **每笔几何事务都写整个 `thermal`**（Ed:298），热提交同样；回放整值覆盖（Log:400） |
| `interaction_history`, `interaction_floor` (640-641) | 最近 512 个操作（`world/interactions.ex:5,62`） | **有界** | kind3（检查点写入；回放 `Interactions.apply`） |
| `properties` (624) | 属性目录（`Damage.load`），含 digest | C | 资产文件；在日志里只以行的 `digest` 体现 |
| `magic`, `production_materials`, `liquid_bounds`, `death_drop_probability`, `gm_tools`, `projectile_backend` | 目录/配置 | C | 配置 / 资产 |
| `prefabs` (629) | `definition_id(sha256) => %{nodes(cells 存成 term_to_binary), has_macro_cells, definition(**解码后的完整列表**), summary}`（`prefab.ex:17-23,153-161`） | 随目录（作者目录 + 运行时发布），实测 239 MB，主要是 `definition` 里的 cells/macro_cells 元组列表 | 文件：`Prefab.load(catalog_path, <world_dir>/prefabs)` 每次启动全量解码 + 编译 |
| `published`, `prefab_dir` (627-628) | 运行时发布记录 `[%{id, publisher, name, bytes}]`（`prefab.ex:25-33`） | 随发布 | `<world_dir>/prefabs/*.pub|.vxpd` |

### 1.4 在线/会话/调度（随玩家或进程，不持久）

| 键 | 增长 | 说明 |
|---|---|---|
| `tool_sessions`, `spell_sessions`, `build_sessions`, `claim_corners` (566, 589, 617, 614) | P | 按 Player/Gate pid，断开时删除（W:1572-1577） |
| `bodies`, `caster_coherence`, `pending_casts` (595, 585, 592) | P | Scene 报来的派生值；pending_casts 冷启动即丢 |
| `subs`, `canonical_subs`, `canonical_feeds`, `replica_subs` (648-651) | P | 订阅；canonical_subs/replica_subs 记录 box |
| `liquid_falls`, `liquid_timer`, `thermal_work`, `thermal_due`, `thermal_timer`, `thermal_quiet_seq`, `thermal_run`, `projectile_timer`, `projectile_task` | 活动 | 调度/派生；`thermal_work` 启动时由 `damage` 全量重建（`world/thermal.ex:65-73`） |
| `checkpoint_timer`, `checkpoint_job`, `checkpoints` (643-646) | C | 检查点调度 |
| `entries` (642) | 见 §3.4：**保留的检查点事务（含全世界区域载荷和全量元数据）+ 之后的后缀**，实测 309 MB | 内存保留；来源是持久日志 |
| `log` (652) | `{OverlayLog.Db, cv}` | — |

### 1.5 可分区性小结（推断）

- 天然按 L0 区域切分（键里就有 cell 或 region）：`overlay`、`refined`、`refined_encoded`、`attachments`（按 anchor）、`liquid_units`、`liquid_active`、`epochs`、`macro_owners`、`placed_by`、`damage`(g=0/1/4)、`region_bases`、`decoded`、`snapshots`、`payloads`；L1+ 的 `structure`/coarse `overlay` 按 L 级区域切。
- 跨区域、按身份组织：`instances`（树）、`attachment_owners`、`refined_owners`、`damage`(g=2 部件池、g=3 附件)、`component_cache`。这几项是分页的主要难点：部件 HP 是整件一份（g=2），几何却分散在多个区域。
- 全局、按角色：balances/energy/ledgers/receipts/phase_inventory/beacons/protection/`seq`/thermal 账。体量随角色数增长，不随世界体积增长，适合单独做表或分区。
- 内容寻址目录：`prefabs`。可以按 id 懒加载，和区域无关。

---

## 2. 启动路径（`init/1` → `restore/1` → `replay_log/1`）

| 步 | 位置 | 动作 | 是否全世界 |
|---|---|---|---|
| 1 | W:503-507 | `GeneratedStore.open/1`：读 manifest，校验 kernel identity，算 cv，创建 `<root>/<cv hex>/`，读 `baseline/index.etf` 列边界（GS:31-90） | 常量 |
| 2 | W:514-526 | 读 `payload_cache_bytes`，把 `min_bin_vheap_size` 设为 cache_limit/wordsize，避免频繁全堆 GC | — |
| 3 | W:528-653 | 构造 state。其中 `load_thermal_environment`（JSON）、`load_properties`（属性目录）、`load_magic`、`Prefab.load_published(<world_dir>/prefabs)`、**`Prefab.load(catalog_path, <world_dir>/prefabs)` 全量解码并编译全部预制件定义**（`prefab.ex:17-23`、`publish/1` 132-164） | 全目录 |
| 4 | W:655 → Log:65-70 | `replay_log`：`OverlayLog.Db.replay(cv)` = `OverlayLogStore.read_all(cv)`：`SELECT … WHERE content_version=$1 ORDER BY seq, ordinal`，**一次性把整个世界日志读进内存**（OLS:62-75）；再 `OverlayLog.transactions/1` 按 seq 分组、逐行解码（OL:74-85；kind3 走 `binary_to_term`，并先加载全部写入方模块，OL:40-43） | **全世界** |
| 4a | Log:66-67 | 对每笔事务依次 `replay_entry`：kind1 区域行做 `Payload.decode` 全解码；L0 时把 core 的 refined、instances、attachments、liquid 写回 state，然后 `rebase_region` 把去掉细节的地形放进 `region_bases`（Log:90-133, 169-205）；kind4 写 `structure`（Log:135-146）；kind0/2 写 `overlay`（Log:148-160）。接着 `replay_liquid` 和 `replay_damage`（全部 kind3 元数据合并/覆盖，Log:384-416） | 全世界 |
| 4b | Log:68 → Log:39-45 | 每笔都调 `remember_entry`：`Interactions.apply`、`retain_entry`（**把检查点事务连同全部区域载荷字节和全量元数据保留进 `entries`**）、`Thermal.touch`、`schedule_checkpoint` | 全世界 |
| 5 | W:666-677 | 热环境容差、魔法/热不变量、`material_units_per_micro` 校验、`validate_damage_catalog`（遍历全部 damage 行，`catalogs.ex:118-124`） | 全 damage |
| 6 | W:678 | `migrate_component_damage`：扫全部 damage，把旧 g=1 行聚合成 g=2（`heat_commit.ex:233-250`） | 全 damage |
| 7 | **W:679** | `refresh_structure(state, Map.keys(state.refined))`：**对全部 refined 宏格**逐级 L1→L5 规约结构网格（Pl:263-346）。原因：检查点不写 kind4，rebase 又清空 structure（Log:191），回放后 `structure` 是空的，所以每个结构格都算“变了”，被加进 `snapshots`，缓存失效 | **全世界** |
| 8 | **W:680** | `if map_size(structure) > 0, do: compact_log(state)`：**同步执行完整检查点**：`checkpoint_input → build_checkpoint → finish_checkpoint`（Log:261-266），对 `snapshots` 里每个区域（L0–L5）重新物化并编码完整载荷，写 PG 前缀替换（§3）。推断：VmHWM 6.5 GB 主要叠加在 4（整表行 + 解码）、7、8（全区域编码 + 整张检查点事务 + 数据库批量插入）这几步 | **全世界** |
| 9 | W:681 | `Thermal.rebuild_work`：从全部 damage 推热行/电路（`thermal.ex:65-73`） | 全 damage |
| 10 | W:682 | `prepare_component_cache(state, nil)`：对 `refined_owners` 的所有部件算几何（observation.ex:138-164；内部还把整张 `refined` 建成 order map，146 行） | 全世界 |
| 11 | W:688-691 | `schedule_liquid`、`Thermal.wake`、`Projectiles.wake` | 活动 |

离线入口 `rebuild_coarse/1`（W:490-497）复用同一个 `restore/1`，然后 `CoarseRebuild.run`（`world/coarse_rebuild.ex`）。它同样是全世界的，并在最后整体替换日志前缀。

---

## 3. 日志与检查点

### 3.1 PG 表（唯一表 `voxel_overlay_log`）

迁移 Mig:15-27：

| 列 | 类型 |
|---|---|
| content_version | bigint（u64 按补码存，OLS:118-121） |
| seq | bigint（World 内存计数，不是 DB 序列） |
| ordinal | integer（事务内顺序） |
| kind | smallint |
| level | smallint |
| region_x / region_y / region_z | integer |
| payload | bytea |

- **只有一个唯一索引 `(content_version, seq, ordinal)`**（Mig:26）。**没有 `(content_version, level, region)` 索引**，也没有主键。按区域读回目前只能全表扫描。
- `DataService.Voxel.OverlayLogStore`（OLS）只有三个操作：`append/3` 在一个事务里批量 INSERT（每批 500 行，OLS:26-35, 84-116）；`replace/3` 在一个 DB 事务里 `DELETE … seq <= P` 再 INSERT 检查点行（OLS:37-60）；`read_all/2` 读整个世界（OLS:62-75）。另有只测试用的 `reset/1`。
- 状态类别声明：`PERS:durable_authoritative`（OLS:2-3）。

### 3.2 kind 编码（OL:8-12, 45-71, 73-85）

| kind | 内容 | level / region 列 | payload 格式 | 回放 |
|---|---|---|---|---|
| 0 | L0 单格 `cell`：`%{seq, coord, material, coarse}` | 0 / `region_of(coord)` | 0x77 kind0 线格式（`Codec.encode_entry`） | `Edits.put_overlay` L0 + 逐级 coarse（Log:148-160） |
| 1 | **完整区域载荷**（VXR4 容器，format v4–v13；seq 盖在头里） | 头里的 level / region | `Codec.encode_payload` 字节 | 全解码 → 写回 refined/instances/attachments/liquid（L0）→ `rebase_region`（Log:90-133） |
| 2 | 粗格 `coarse`：`%{level, cell, material, skins}` | 级 / region_of(cell) | `Codec.encode_coarse` | `put_overlay(level)`（Log:75-77） |
| 3 | **元数据**：一笔事务至多一行，`level=0, region={0,0,0}` | 固定 (0, 0,0,0) | `term_to_binary(metadata, compressed:1)`，键取自固定白名单（OL:66） | `Map.merge(txn, term)` → `replay_damage`/`replay_liquid`/`Interactions.apply` |
| 4 | 结构格后像 `%{seq, level, cell, structure: grid}`（空字节表示删除） | 级 / region_of(cell) | 0x77 kind2 | 写/删 `structure` 并标记 snapshot（Log:135-146） |

kind3 的白名单键（OL:66）：`property_states, epochs, material_balances, caster_energy, material_supplies, craft_ledger, food_ledger, food_receipts, placed_by, macro_owners, protection, beacons, beacon_attunements, prefab_instances, phase_inventory, thermal, attachment_serial, attachment_owners, material_units_per_micro, liquid_active, liquid_units, interaction, interaction_history, interaction_floor`。

**kind3 不分区域**：region 列恒为 (0,0,0)。检查点时整个世界的非地形元数据压成**单独一行** ETF。

### 3.3 每笔事务写什么（append_log / attachment_metadata）

- `Log.append_log(state, txn)` = `append_journal(attachment_metadata(state, txn))`（Log:17-21）。
- `attachment_metadata/2`（Log:28-36）**给每笔事务追加全表**：`attachment_serial`、**`attachment_owners`（全表）**、**`prefab_instances = state.instances`（全表）**、`material_units_per_micro`、**`liquid_active`（全量列表）**。
  - 结论（事实）：是的，**每笔 append_log 事务都会把实例表、附件归属表、液体活动集整张写进 kind3**。纯液体数量提交走 `liquid_journal`（Log:24-25），只去掉 instances 和 owners，`liquid_active` 仍是全量。
  - 调用方（全部走 append_log）：`attachment_ops.ex:101`、`beacons.ex:152`、`casting.ex:160,379`、`catalogs.ex:103`、`claims.ex:104`、Ed:197、Ed:375、`heat_commit.ex:73`、`prefabs.ex:574`、`production.ex:94,167,206`、`tools.ex:229,261,395`。
- 几何事务另外写：`property_states`（增量）、`epochs`（本笔宏格）、placed_by/macro_owners 增量（`production.ex:26-33`）、settlement（balances 等增量），以及**整个 `thermal`**（Ed:298）。
- 几何事务的格条目：`select_transaction/2` 对每个 `{level, region}` 比较“稀疏条目字节”和“完整区域载荷字节”，取小的那个（Log:207-259）。会改实例、附件、液体、树冠的区域，一律写完整后像 kind1（`Pl.region_afterimages`，Pl:221-260；Ed:223-228, 260-266）。
- `publish_property_catalog` 会把全部 damage 行重写成一笔事务（`catalogs.ex:88-91`），O(全部 damage)。

### 3.4 内存保留（retain_entry）与订阅补发

- `remember_entry`（Log:39-45）→ `retain_entry`（Log:47-55）：有格条目的事务原样保留（只去掉广播字段）；纯属性事务只保留 `[:seq, :entries, :coarse, :liquid_units]`。
- `finish_checkpoint` 用 `[checkpoint_txn | suffix]` 重建 `entries`（Log:356-358）。所以**检查点事务本身（全部 snapshot 区域的 kind1 字节 + 全量 damage、epochs、balances、instances……）一直常驻在 `entries` 里**，这就是实测 entries 309 MB 的来源。保留它的用途：
  - `subscribe/5` 对 `have_seq` 之后的全部保留事务按 box 过滤补发（W:1311-1321），检查点事务对任意更旧游标都是“完整补丁”（Log:287 注释）；
  - `serve_item` 的 entries 回复走 `LogProjection.since(entry_regions, entries, …)`（Pl:44；LP:36-52）；
  - `entries_after/2` 诊断（W:1325-1334），纯属性正文需要时从持久日志 `backend.replay` 整表补读。
- 推断：常驻量 = 一份完整世界快照（地形 + 细节 + 元数据）的第二份副本，外加后缀。

### 3.5 检查点（checkpoint_input / build_checkpoint / finish_checkpoint）

- 触发：每笔新事务后，只要 `map_size(entries) > 1`、且没有 timer 和 job，就安排一次 60 s 定时器（Log:58-63）；到期 `request_checkpoint`（W:1406-1407, 1599-1609）。`compact/1` 显式请求（W:1386-1388）。另外启动时同步执行一次（W:680）。
- `start_checkpoint`（W:1611-1620）：只在热提交边界（`thermal_run == nil`）冻结 `checkpoint_input`，再 `Task.async(fn -> build_checkpoint(input) end)`。推断：闭包会把 input 拷到 Task 进程堆上（大 binary 是 refc 共享，map/元组会被复制），检查点期间 refined、overlay、region_bases、damage、epochs 等非 binary 结构相当于存了两份。
- `checkpoint_input`（Log:269-282）冻结的键：`seq, cv, source, source_state, region_bases, overlay, overlay_regions, snapshots, refined(+owners/regions/encoded), instances, structure, macro_owners, attachments, liquid_units, properties, damage, epochs, material_balances, caster_energy, material_supplies, craft_ledger, food_ledger, food_receipts, placed_by, protection, beacons, beacon_attunements, phase_inventory, thermal, attachment_serial, attachment_owners, material_units_per_micro, liquid_active, payloads, decoded, lru…, interaction_history/floor`，另加精简过的 `prefabs`（只留 presentation_bindings）。
- `build_checkpoint`（Log:285-327）：
  1. 不在 `snapshots` 里的 overlay 格：`select_transaction`，得到稀疏行或整区后像（Log:289-294）；
  2. **对 `snapshots` 里每个 `{level, region}` 做 `Payloads.payload_bytes` 完整物化/编码**（命中缓存就直接用，Log:297-301）。`snapshots` 只增不减，所以**每次检查点都会把历史上所有出过后像的区域（L0–L5）重写一遍**；
  3. 合并全量元数据：`property_states: Map.values(damage)`、`epochs`（全表）、balances、energy、supplies、ledgers、receipts、placed_by、macro_owners、`protection.regions`、beacons、attunements、phase_inventory、thermal、interaction_history（Log:305-323），再过一遍 `attachment_metadata`（instances、owners、liquid_active 全表）。
- `finish_checkpoint`（Log:330-369）：`backend.checkpoint` → `OverlayLogStore.replace(cv, rows, through_seq: P)`，**一个 DB 事务里删掉 ≤P 的全部行，再插入整张检查点**（全部区域 kind1 + 稀疏行 + 一行巨大的 kind3）。若期间没有新后缀（`state.seq == txn.seq`），对每个 kind1 做 rebase；snapshot 里 core 无编辑的区域跳过（Log:337-353）。然后重建 `entries`，通知 Replica 退休前缀（Log:360），下一回调做 full GC（W:1391-1398）。
- 结论（事实）：检查点 = O(全部 snapshot 区域 + 全部元数据)，与本期间的脏区域无关。DB 写入量相同，每分钟一次（只要有新事务）。

### 3.6 compact_log

`compact_log/1`（Log:261-266）就是同步跑一遍 `checkpoint_input → build_checkpoint → finish_checkpoint`，然后 `schedule_checkpoint`。调用方只有 `init`（W:680）。`seq == 0` 时什么也不做。

### 3.7 文件后端（只测试）

`OverlayLog.File`（OL:109-146）：`<world_dir>/overlay.log` 存 `<<len::32, term_to_binary(txn)>>` 帧；checkpoint 时读全文件、保留后缀、写 tmp 再 rename。语义与 Db 后端相同。

---

## 4. 区域载荷

### 4.1 L0 区域载荷包含什么（`with_existing_details`，Pl:152-194；P:19-42）

| 字段 | 内容 | 来源 |
|---|---|---|
| cells / records / fmi / maps | 66³ 地形材质 + 表皮 CSR（含 ring） | baseline 或 region_bases，再叠 overlay 与邻区基底 ring（Pl:84-91, 128-150） |
| `refined` / `refined_records` | 跨度（含 ring）内 refined 宏格的槽 | `refined_in_regions(27 个区域)`（Pl:160-176） |
| `instances` | **跨度内被引用到的**实例 id 及其祖先（微格 owner 加 macro_owners 值），不是全部实例 | Pl:178-181, 191 |
| `attachments` | anchor 在 core 加一宏格 ring 范围内的附件槽 | `Attachments.extract`（`attachments.ex:36-43`） |
| `liquid_units` | 跨度内的有限数量 | Pl:185-187 |
| `canopy*` | 树冠锚点/残余，由 macro_owners × 定义 presentation_bindings 派生 | `world/canopy.ex:9-26` |
| `format_version` | 4/5…13 | — |

L1+ 载荷：地形 + `structure`（该级跨度内的结构网格，Pl:196-205）。

**不包含**（所以 kind1 不是“该区域完整真值”的序列化）：

- `damage` / property rows（HP、温度、燃料、相态焓）：只在 kind3；
- `epochs`、`macro_owners`、`placed_by`：只在 kind3（macro_owners 只用来算载荷里的 instances 和 canopy，本身不进载荷）；
- `attachment_owners`、`attachment_serial`：只在 kind3；
- 完整的 `instances` 子树：载荷只带被引用 id，权威全表在 kind3；
- `liquid_active`、`thermal.sources`、semblances、`protection`、beacons、各种账：kind3；
- L1+ `structure`：L1+ 载荷里有，但回放时 L1+ kind1 只做 rebase（Log:128-132），会清掉 structure（Log:191）；它是派生物，启动时重算。

**推断**：L0 kind1 已经是“该区域的地形 + 细化 + 附件 + 液体数量”的完整序列化（core 部分）。缺的是按 cell 定位的元数据（epochs、macro_owners、placed_by、damage g=0/1/4、liquid_active），以及按身份组织、跨区的 instances、attachment_owners、damage g=2/3。要让区域行自足，就得把前一类挪进区域分页，后一类另立按 id 分页的表。

注意 ring：L0 载荷含邻区的一圈 ring 格。回放时只取 core（Log:102、122-123），附件只取 anchor 在本区的（Log:115-117），所以**持久语义已经是“core 拥有、ring 投影”**。

### 4.2 GeneratedStore 与载荷缓存（现成的有界机制，可作分页模板）

- **磁盘 baseline**（GS:1-16, 155-216）：`<root>/<cv>/baseline/L<level>/<region file>` 存 VXR4 字节，是可丢弃缓存。L1–L5 开服前由 `Bake` 烘齐；L0 首次访问时在线生成（`Native` NIF），通过硬链接发布、ETS 锁表保证同一 BEAM 内同一区域只生成一次（GS:14-15, 255-282）。能由列边界证明为均匀（纯空气/纯岩石）的区域不落盘，读时合成常量载荷（GS:163-176）。列边界：`baseline/index.etf` 加 ETS `:voxel_region_column_bounds` 备忘（GS:120-146）。
- **冷 miss 在调用方进程预备**：`prepare/2`（W:122-150）先 call World 拿 `{source, source_state, missing}`，再在调用方用 `Task.async_stream` 并发 `source.ensure`（`generation_concurrency` 默认 8），World 本身不被生成阻塞。意图路径 `prepared_intent`（W:153-160）同理，并在调用方把 L1+ 来源**解码**好再交给 World（`decode_sources`，W:163-175）。
- **载荷缓存**（Pl:348-416）：`payloads` map、`lru` gb_tree `{tick, key}`、`lru_ticks`、`lru_bytes`。L0–L3 超过 `cache_limit` 就 `take_smallest` 淘汰；L4+ 常驻，计入 `resident_bytes`。编辑时 `cache_delete` 精确失效触及的区域（Ed:60-79；Pl:224）。
- **未编辑区域直接读 source 字节**：overlay 为空、不在 snapshots、相邻也没有 region_bases 时，`payload_bytes` 原样返回 source 字节，不解码（Pl:77-82）。
- 推断（可借鉴的模板）：“权威持久形式（磁盘/PG 字节）+ 不可变字节 LRU + 调用方进程预备冷区域 + World 只做查找/接纳”这条链路已经跑通。按区域分页真值时，可以沿用同一形状，让 `region_bases`/`refined`/区域元数据成为“可从 PG 按区域读回的冷页”。目前缺的是：(a) `decoded` 与 `region_bases` 没有淘汰；(b) 真值页的回写路径；(c) PG 的区域索引。

---

## 5. 现有可直接作为“按区域读回”基础的接口

| 接口 | 位置 | 能力 | 局限 |
|---|---|---|---|
| `voxel_overlay_log` 每行都有 `level, region_x/y/z` 列 | Mig:20-23；OL:48-71 | kind0/1/2/4 行都标了区域，按区域筛选的数据形状已具备 | 没有区域索引；kind3 恒为 (0,0,0)；检查点每次都替换全部前缀 |
| `OverlayLogStore.read_all/2` | OLS:62-75 | 按世界全量读 | 没有按区域读的函数（需新增 `WHERE level=? AND region_*=?`） |
| `Payload.decode/1`、`decode_cells/1` | P:89-131 | 区域字节 → struct；也能只解 cells | — |
| `Log.replay_entry(state, %{payload: bytes})` + `rebase_region/2` | Log:90-133, 169-205 | **单个区域载荷 → 写回该区 core 的 refined、attachments、liquid，并设 region_bases**；已是区域粒度的“装页”函数 | instances 用 merge 再 take live；依赖全局 `refined_owners`、`macro_owners` 计算 live ids（Pl:208-210） |
| `Canonical.decoded/3`、`decoded_source/2`、`cell_value/3` | Can:83-129 | 读路径的唯一入口：overlay → region_bases → source；缺页时可在这一层装页 | 缺 base 时直接读 source，不知道 PG 里还有区域行（现在靠启动全量回放兜住） |
| `Payloads.payload_bytes/4`、`canonical_region_bytes/2`、`canonical_regions/2` | Pl:66-123, 419-432 | 单区域物化/编码 | 内部有全表扫描：`liquid_units`、`macro_owners`、`refined_owners`（Pl:178-187）、L1+ `structure`（Pl:197-202）、`Canopy.candidates` 扫全部 macro_owners（canopy.ex:47-52）、`Attachments.extract` 扫全部附件 |
| `Canonical.refined_in_regions/2` + `refined_regions` 索引 | Can:50-52 | refined 已有按 L0 区域的索引 | `in_refined_order/2` 仍按整表次序遍历（Can:59-60） |
| `Observation.capture_canonical_snapshot/2`、`property_snapshot/2`、`PropertyObservation.project/2` | observation.ex:47-68, 182-200；property_observation.ex:15-25 | 按 box 读区域字节 + 属性投影 | property 部分先扫全部 damage、取全部 epochs 再过滤（observation.ex:183-196） |
| `Parcel.export/2` | `world/parcel.ex:22-66` | **按宏格盒导出完整 L0 真值**（cells、refined、macro_owners、liquid、完整实例树、附件 + owners、相关属性行、定义字节），并拒绝跨盒实例/附件 | 维护期 rpc；内部用全表 filter；拒绝跨界，说明“跨区实例”在语义上需要另行界定 |
| `Replica`（`replica.ex:1-30`）+ `replica_snapshot_and_subscribe/3`（W:68-71） | — | 已有按 box 订阅、只读的区域物化视图，带前缀退休（`:canonical_replica_checkpoint`） | 数据全部来自唯一 World |
| `LogProjection.index/2`、`since/5`、`region/3` | LP:16-52, 116-153 | 按 `{level, region}` 索引的事务序号，按区域投影事务 | 只覆盖内存中的保留事务 |
| `Edits.edit_keys/1`、`Payloads.region_keys/1`、`intent_keys`、`prepare/2` | Ed:40-45；LP:7-13；W:122-150 | **每笔意图已经先算出涉及的 `{level, region}` 集合，并在 World 回合之外预备冷区域**，这正是“O(涉及区域)装页”需要的钩子 | 目前只预备 source，不装持久真值页 |

---

## 6. 与目标的差距清单（事实 → 推断）

| 目标 | 现状（事实） | 主要违背点 |
|---|---|---|
| 常驻 = O(活跃区域)+有界缓存 | 全部真值字段常驻；`entries` 保留整份检查点；`decoded`/`region_bases`/`snapshots`/`epochs`/`served_headers`/`liquid_adopted` 都不淘汰；`prefabs` 全目录解码常驻 | refined、entries、epochs、prefabs 四项合计约 1.1 GB |
| 每笔成本 = O(涉及区域) | 每笔 kind3 写全表 `instances`、`attachment_owners`、`liquid_active`，以及整个 `thermal`（Log:28-36；Ed:298）；`damage_geometry` 扫全部 damage（`tools.ex:484-488`）；载荷物化时多处全表扫描（§5） | 写放大与 CPU 都随世界内容增长 |
| 启动 = O(脏区域) | `read_all` 全表读 → 全量回放 → 全量 `refresh_structure` → 同步全量检查点（W:655, 679-680） | 每次启动都是 O(世界) 两遍 |
| 检查点 = O(脏区域) | 检查点重编全部 `snapshots` 区域，写全量元数据，DB 端 DELETE ≤P 加全量 INSERT（Log:297-327；OLS:37-60），每 60 s 一次 | 推断：可改为按区域 upsert 行，元数据也按区域分行 |
