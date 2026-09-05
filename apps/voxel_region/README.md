# Voxim Region 真值

`World` 拥有烘焙文件 ⊕ 日志真值、订阅与派生载荷缓存；`Reducer` 只规约材质和表皮；`Payload` 只处理 66³ cells / CSR；`Codec` 只处理线格式。gate 只解码、路由和回执，auth HTTP 只调用 `World.serve`。

`apply_edits([{coord, material}, ...])` 同一坐标最后一个值生效，先写完全部 canonical 值，再按级去重父格。某父格的材质与表皮均未变，不向上继续。一次有效批次一个 seq；全 no-op 不递增；canonical 源缺失整批不提交。原 `apply_edit` 共用此规约路径，但仍发旧 `0x77 kind=0`。

no-op 只向发起且已订阅的连接回现有 `0x79` 空事务，seq 是当前全局游标；不广播、不落盘。该确认与 backlog/实时条目同由 World 发送，连接邮箱保持 FIFO，所以不会跳过本连接应先处理的事务，也不会因最后一个全局事件在订阅外而让账本永久 pending。

事务 `0x79` 小端：`seq u64 / entry_count u32 / {length u32, LogEntry bytes} / coarse_count u32 / coarse[]`。`kind=1` 条目是 `seq u64 / kind u8 / 完整 VXR3`；`kind=0` 字节不变，批次的 canonical 条目 coarse 为空，粗格只在事务 coarse 数组出现一次。按 owned `(level, region)` 分组，精确比较 sparse 字节与 `13 + VXR3大小`，严格大于才用 region。客户端把 region 的 owned 64³ 投入所有相交 resident ring，不能只替换自己的 66³。

日志磁盘只保留选定的 region 快照和剩余 sparse 值；region 事务后自动 `compact`，也可显式调用 `World.compact`。检查点是完整累积投影，seq 等于压实前缀末尾；任意 `have_seq < checkpoint.seq` 都收到完整检查点再接 suffix。region 恢复时 owned 内部直接读快照、边界值同时更新相邻 ring。没有另存一份全量 sparse 磁盘日志。

复用旧物化快照时，只把 VXR3 头中的 seq 改成检查点 seq（不改 body/hash），使 `transaction.seq == entry.seq == payload.seq`。否则客户端会拒绝整个检查点；测试覆盖「dense seq1 → 无关编辑 seq2 → compact → 重启」。

HTTP `kind=entries`：`transaction_count u32 / {length u32, 无 opcode 的事务信封}`，均小端。每个 region 只记录最近一次完整下发的 `(seq,hash)`；请求 `have_seq > 0` 且头匹配、之后只有 sparse、精确编码更小时才回 entries。客户端把它应用在磁盘副本的解码结果上，不改原文件；服务端保留原头以支持重复读取。首次拉取、头不匹配、服务端重启丢失头、跨过影响本 region（含 ring）的 region 替换都回完整载荷。此处没有历史 payload 缓存或 LRU。

批量入口 `0x78` 大端：`request_id u64 / client_intent_seq u32 / logical_scene_id u64 / count u32 / {canonical i32×3, material u16}`；一条 `0x68` 回执，`result_ref=seq`。`Docs/R6/tools/gate_client.py explode x y z radius` 发送一个批次。r50 是 523305 格、约 7.33 MB 请求，现有 TCP `packet_size` 从 2 MB 调到 8 MB。

从 umbrella 根运行：

```powershell
mix compile
mix cmd --app voxel_region mix test --no-start
mix run --no-start apps/voxel_region/bench/s3.exs
python apps/voxel_region/bench/http_probe.py
```

最后一个命令需要本地服务，临时改变 `(40,504,39)` 一格后恢复原材质。服务启动：`DEV_AUTO_LOGIN=true`、`VOXEL_REGION_ROOT=<Voxim>/WorldBake`、`MMO_DB_PORT=5433`，umbrella 根 `mix phx.server`。不要禁用 dev reload；docker `mmo-pg` 监听 5433。

实测与验收证据在 `Voxim/Docs/R6/runtime/s3_server_*`，设计决策与边界见 `docs/10-active/voxel-far-field/2026-09-02-voxim-region-payload-and-overlay-log-design.md` 的 S3 记录。
