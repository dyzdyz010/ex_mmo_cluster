# Voxim Region 真值

M4a 区域部署采用 `Replica` 只读物化视图：每个 Scene 节点在本地运行该服务，驻留显式 `l0_box` 的完整 payload 与碰撞 chunk。
唯一 `World` 继续分配事务序号、规约、写日志；Replica 没有生成器、日志或编辑入口。Scene 的 `world_api` 为
`VoxelRegion.Replica`、`world_ref` 为本地 Replica PID；比较世界身份时调用 `authority_ref/1`，两份区域服务返回同一个上游 World PID。
配置 `Application.put_env(:voxel_region, :replica, authority_ref: world_pid, l0_box: box)` 后启动应用；该配置优先于 root，避免在 Scene 节点误启动第二个可写 World。

启动从上游原子获取快照并订阅，之后同一个 World 发出连续的 `CanonicalDelta` 与受影响区域的完整压缩 payload。
Replica 只替换不可变结果，并在自己的 mailbox 内原子提供 `canonical_snapshot_and_subscribe/5`；新订阅者的快照与后续 delta 同源有序。
含 ring 的 payload 使用 World 既有事务投影判定受影响区域，材质改变但 occupancy 未变也会更新 payload。越出驻留 box 显式拒绝。
上游 monitor 结束时 Replica 退出，使 Scene 已有 world monitor 立即失效；本轮不做故障接管或将旧缓存升格为 authority。
`canonical_deltas_after(replica, N)` 返回启动快照以后、严格大于 N 的有序 `CanonicalDelta`；N 早于启动快照返回 `{:error, :before_replica_snapshot}`。
该历史供跨区移交按切点前缀补齐已到达编辑，保留不可变 transaction/chunk，不保存 native physics world。
`stats/1` 暴露 `authority_ref / transaction_seq / baseline_seq / retained_deltas / regions / chunks / payload_bytes / occupancy_bytes / update_payload_bytes`，可验证实际驻留与增量流量。

决策依据（2026-09-11）：[Microsoft Materialized View](https://learn.microsoft.com/en-us/azure/architecture/patterns/materialized-view)
将缓存定义为可丢弃、由唯一数据源更新的查询视图；这里按已批准 M4a 固定区域驻留，直接传源端完成物化的字节，避免复制 reduce/replay 算法。
[OTP 进程信号顺序](https://www.erlang.org/doc/system/ref_man_processes.html#signals)只保证同一发送者到同一接收者顺序，故快照边界与全部后续更新都在 World 内发布，Replica 的读取边界也由其自身 GenServer 串行维护。
代价是每个 Scene 节点保存一份区域 payload/chunks，编辑额外传送受影响区域完整压缩 payload；其余区域保留原字节，只在读快照时将头序号标到当前前缀。
真实跨节点测试与字节/排队测量由 Voxim `Docs/M4a` 的统一入口完成，单元测试不能代替该验收。

`World` 拥有 baseline ⊕ 日志真值、订阅与内存载荷缓存；`GeneratedStore` 按显式 manifest 调用 DirtyCpu Rust NIF 并保存可丢弃的 baseline 磁盘缓存；`Bake` 是就绪门：L1–L5 全世界 baseline 齐全之前应用不完成启动、auth / gate 不开始监听；`Reducer` 只规约材质和表皮；`Payload` 只处理 66³ cells / CSR；`Codec` 只处理线格式。gate 只解码、路由和回执，auth HTTP 只调用 `World.serve`。旧 `FileStore` 只保留给既有烘焙 fixture 测试，正式运行没有文件 fallback。

`apply_edits([{coord, material}, ...])` 同一坐标最后一个值生效，先写完全部 canonical 值，再按级去重父格。某父格的材质与表皮均未变，不向上继续。一次有效批次一个 seq；全 no-op 不递增；canonical 源缺失整批不提交。原 `apply_edit` 共用此规约路径，但仍发旧 `0x77 kind=0`。

no-op 只向发起且已订阅的连接回现有 `0x79` 空事务，seq 是当前全局游标；不广播、不落盘。该确认与 backlog/实时条目同由 World 发送，连接邮箱保持 FIFO，所以不会跳过本连接应先处理的事务，也不会因最后一个全局事件在订阅外而让账本永久 pending。

事务 `0x79` 小端：`seq u64 / entry_count u32 / {length u32, LogEntry bytes} / coarse_count u32 / coarse[]`。`kind=1` 条目是 `seq u64 / kind u8 / 完整 VXR4`；`kind=0` 字节不变，批次的 canonical 条目 coarse 为空，粗格只在事务 coarse 数组出现一次。按 owned `(level, region)` 分组，精确比较 sparse 字节与 `13 + VXR4大小`，严格大于才用 region。客户端把 region 的 owned 64³ 投入所有相交 resident ring，不能只替换自己的 66³。

日志磁盘只保留选定的 region 快照和剩余 sparse 值；region 事务后自动 `compact`，也可显式调用 `World.compact`。检查点是完整累积投影，seq 等于压实前缀末尾；任意 `have_seq < checkpoint.seq` 都收到完整检查点再接 suffix。region 恢复时 owned 内部直接读快照、边界值同时更新相邻 ring。没有另存一份全量 sparse 磁盘日志。

复用旧物化快照时，只把 VXR4 头中的 seq 改成检查点 seq（不改 body/hash），使 `transaction.seq == entry.seq == payload.seq`。否则客户端会拒绝整个检查点；测试覆盖「dense seq1 → 无关编辑 seq2 → compact → 重启」。

HTTP `kind=entries`：`transaction_count u32 / {length u32, 无 opcode 的事务信封}`，均小端。每个 region 只记录最近一次完整下发的 `(seq,hash)`；请求 `have_seq > 0` 且头匹配、之后只有 sparse、精确编码更小时才回 entries。客户端把它应用在磁盘副本的解码结果上，不改原文件；服务端保留原头以支持重复读取。首次拉取、头不匹配、服务端重启丢失头、跨过影响本 region（含 ring）的 region 替换都回完整载荷。此处没有历史 payload 缓存或 LRU。

批量入口 `0x78` 大端：`request_id u64 / client_intent_seq u32 / logical_scene_id u64 / count u32 / {canonical i32×3, material u16}`；一条 `0x68` 回执，`result_ref=seq`。`Docs/R6/tools/gate_client.py explode x y z radius` 发送一个批次。r50 是 523305 格、约 7.33 MB 请求，现有 TCP `packet_size` 从 2 MB 调到 8 MB。

从 umbrella 根运行：

```powershell
mix compile
MMO_DB_PORT=5433 mix cmd --app voxel_region mix test --no-start   # WorldTest 走 DataService 表后端：需要 Postgres（test 配置 → mmo_test，test_helper 自动建库 + 迁移）
mix run --no-start apps/voxel_region/bench/s3.exs
python apps/voxel_region/bench/http_probe.py
```

跨实现 oracle 测试显式设置 `VOXIM_ORACLE_DIR=<Voxim>/Saved/S4Oracle`；如还设置 `VOXIM_SERVER_PAYLOAD_DIR=<Voxim>/Saved/S4ServerPayloads`，测试会把 NIF body 包成同名 VXR4，供 UE 的 `VoximOracle.S4.ImportServerPayloads` 再通过正式 codec 核对。

oracle 默认由 ExUnit 排除，显式运行时加 `--include oracle --only oracle`。

T-2（决策稿 §12，随机 200 region）：UE 先跑 `VoximOracle.S4.ExportRandomSample`（固定种子，写 `<Voxim>/Saved/S4OracleT2/`），再
`MIX_ENV=test VOXIM_T2_ORACLE_DIR=<Voxim>/Saved/S4OracleT2 VOXIM_STORE_ROOT=<Voxim>/Saved/S4CacheAuthority VOXIM_STORE_MANIFEST=<Voxim>/Docs/R6/runtime/s4_worldgen_manifest.json VOXIM_SERVER_PAYLOAD_DIR=<Voxim>/Saved/S4ServerPayloadsT2 mix cmd --app voxel_region mix test --no-start --only t2 test/generated_store_test.exs`——
每份用 `GeneratedStore.read`（就绪门文件 / 合成常量 / 在线 L0，即实际会发的字节）与 UE fixture 解压后逐字节 + 逐格比较，并写出同名载荷；之后 Rust `VOXIM_ORACLE_MANIFEST=<Voxim>/Saved/S4OracleT2/manifest.json cargo test --release --test oracle -- --ignored`、
`python Docs/R6/tools/t2_compare.py`、UE `VoximOracle.S4.ImportRandomSample`。2026-09-07 四方 200/200，记录在 `Voxim/Docs/R6.md` §S4 第六切片。

**就绪门（`VoxelRegion.Bake`）**：世界是以原点为中心、半边长 `world_half_extent_m` 的正方形。启动时（`Application.start`，在 `World` 之前）对 L1–L5 每一级枚举世界内所有 XZ 列，
用 kernel 的折叠边界 `Native.column_bounds`（列内最低 / 最高地表与岩性省份范围）配合 `Native.mixed_rows` 找出不能证明均匀的 ry，只有这些 region 需要生成并落盘；
纯空气 / 纯岩石的 region 不落盘，读取时 `Native.classify_region` + `Native.uniform_body` 合成常量载荷（Rust 测试保证与 `generate_region` 逐字节相同）。列边界写在 `baseline/index.etf`，
之后每次启动只加载索引、核对文件、补缺。本机 Demo 世界首次烘焙：16 km × 16 km（`world_half_extent_m` 8192）21,824 列、78,536 个 mixed region，本次生成 48,578（复用 29,958）534 s，从零约 13 min；32 km 全量约 303k region、约 1 h；之后启动核对 78,536 个 region 每级列一次目录核对 225 ms（逐文件 stat 时 91 s）。
离线执行同一段代码：`mix run --no-start apps/voxel_region/bench/bake.exs <manifest> <root> [concurrency]`。

L0 不在门内：它按玩家位置在线生成（单块几十毫秒）。`World.serve` / `apply_edit(s)` 先在调用方进程用 `Task.async_stream` 并发调用 `GeneratedStore.ensure`
把本批缺失的 L0 物化到磁盘（每请求并发上限 `VOXEL_REGION_GENERATION_CONCURRENCY`，默认 8），再进 GenServer；同一 BEAM 里对同一 region 的并发生成由 ETS 锁表去重，
跨进程仍靠硬链接发布。mixed 的 L1+ 缺文件是硬错误 `:not_baked`，不在线生成。`World.stats/0` 返回 `generated`（NIF 实际调用次数）。

`World` 内有一个内存载荷缓存 `(level, region) → {bytes, header}`：source 原样字节与 overlay 物化字节都进它；L0–L3 按最近使用淘汰，字节上限
`VOXEL_REGION_PAYLOAD_CACHE_MB`（默认 512），L4+ 常驻不计入上限；条目碰到的 region（含 ring 邻居）立即失效，region 快照重放时整个清空。命中不读盘、不解压。
`stats` 里有 `entries / lru_bytes / resident_bytes / hits / misses / evictions`；本机可用 `elixir --sname probe --cookie <cookie> -e ':rpc.call(node, VoxelRegion.World, :stats, [])'` 读取。

缓存生成先写入同目录、含 OS PID 与 BEAM 唯一值的临时文件，再用 [`File.ln/2`](https://www.erlang.org/doc/apps/kernel/file.html#make_link/2) 建立同文件系统 hardlink，完成拒绝覆盖的原子发布；目标已存在的生成者删除自己的临时文件并读取、校验胜者。文件系统不支持 hardlink 时明确返回 `cache_publish_failed`，没有 rename 或运行时生成 fallback。缓存命中会完整解压并复核 body 长度与 hash，避免截断或损坏的生成结果被永久复用；warm serve 的重复解压成本留给后续性能切片处理。

最后一个命令需要本地服务，临时改变 `(40,504,39)` 一格后恢复原材质。S4 服务启动必须同时设置 `VOXEL_REGION_ROOT=<空的生成缓存根>` 和 `VOXEL_REGION_MANIFEST=<s4_worldgen_manifest.json>`；Demo manifest 的当前导出位于 `Voxim/Docs/R6/runtime/s4_worldgen_manifest.json`。另设 `DEV_AUTO_LOGIN=true`、隔离的 `AUTH_PORT` / `GATE_TCP_PORT` 与所需数据库配置后，在 umbrella 根运行 `mix phx.server`。旧 ChunkProcess 开发世界默认不初始化；仅运行历史探针时显式设 `VOXEL_DEV_REGION_BOOTSTRAP=true`。`start_s4.ps1` 明确设为 `false`，不会继承调用 shell 的旧值。不要把 `VOXEL_REGION_ROOT` 指向原 `WorldBake`；生成 baseline cache 写入该根下的 content-version 目录，权威 overlay 写入数据库并按 `content_version` 隔离。

manifest schema 是 `voxim-worldgen-v1`，显式包含 `kernel`、完整且有序的 `materials` 24 项表、`world_half_extent_m`（世界半边长，米；只决定就绪门枚举范围，不进 content_version）与八项 config：`seed/min_height/sea_level/max_height/soil_depth/lowland_amplitude/mountain_amplitude/cave_max_depth`。`GeneratedStore.open/1` 在创建版本目录前要求 manifest 表与 `MmoContracts.VoxelMaterialCatalog` 完全相等。`content_version` 使用 `voxim-content-version-md5-64-v2`：输入依次为规则名、Rust NIF 提供的完整 kernel identity（算法名 + 构建时源码 digest）、按 id 排序的紧凑 `[[id,name],...]` JSON（当前 327 bytes），三段以 NUL 分隔，再跟 seed i64 LE、四个高度/土层 i32 LE、两个 IEEE754 f64 LE、洞穴深度 i32 LE；MD5 首 8 字节按 little-endian u64 解释。

当前 Demo manifest 配合未变的 kernel identity `worldgen_density_v3@1+sha256:72f1d31c81c337daf54e5f700fc07d1efe4dacf9e6e0df6f7f8c377fa7ee22dd` 得到 `content_version = 256b33610344964f`。旧 `0e31fc80e3ff9e17` baseline 与 overlay 命名空间保留为历史证据，不由新版本读取。源码 digest 覆盖 `build.rs`、NIF 参数映射与全部生成源文件，因此 kernel 代码或形状常量变化会进入新的缓存目录。

**权威 overlay 日志在 DataService 表里**（第七切片，决策稿 §9 第 1 项）：`voxel_overlay_log(content_version, seq, ordinal, kind, level, region_x/y/z, payload)`，一行一个条目（kind 0 = L0 cell 线格式、1 = 完整 VXR4 region、2 = 粗格线格式），
`DataService.Voxel.OverlayLogStore` 读写；`VoxelRegion.World` 通过 `VoxelRegion.OverlayLog` behaviour 追加 / 重放 / 压实（压实 = 一个数据库事务里替换成检查点）。正式启动注入 `OverlayLog.Db`（dev 库先 `MMO_DB_PORT=5433 mix ecto.migrate -r DataService.Repo`）；
`OverlayLog.File`（`<root>/<cv>/overlay.log` ETF 帧）只给不起数据库的测试。seq 仍由 World 内存计数分配（no-op 不消耗、重放取 max）。

远景资产包（决策稿 §6.2）：`mix run --no-start apps/voxel_region/bench/pack.exs <manifest> <root> <out_dir> [min_level]` 把 L ≥ min_level（默认 4）的全世界 region 按 level 打成 `<out_dir>/<content_version>/L<n>.vxpack`（`MmoContracts.WorldPackShard` footer-table，条目 = region 坐标 → 完整 VXR4；范围 = 世界列 × [mixed ry − 1, +1]，均匀 region 也在内），放进 Voxim `Content/VoxelWorld/`。16 km Demo 世界 L4 47.7 MB + L5 11.4 MB，3.9 s。

实测与验收证据在 `Voxim/Docs/R6/runtime/s3_server_*`、`s4_lean_*`（D-9 线格式）与 `s4_asset_*`（资产 + 写回），设计决策与边界见 `docs/10-active/voxel-far-field/2026-09-02-voxim-region-payload-and-overlay-log-design.md` 的 S3 记录。

当前 S4 首切片只把正式 baseline 来源替换为在线 kernel，锁住生成、编辑、重启和 unchanged 闭环。DataService 日志、全 catalog 统一、LRU、L4+ 资产与完整 S4 benchmark 仍属于后续收口，不能据此宣称整个 S4 完成。
