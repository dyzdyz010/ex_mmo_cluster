# 世界真值分页持久化：外部依据查证（2026-10-24）

标注约定：
- **【已核实】**：本次亲自打开原始页面/PDF 并读到引文原句（PDF 为扫描件时按页图逐字核对）。
- **【已核实·存档】**：原站已下线或拦截，经 Wayback Machine 存档快照读取原文。
- **【二手】**：原文未打开，只来自二手报道或搜索摘要；引用不作为决策依据。
- **【未核实】**：找不到可靠原文。
- 「推断」段落是我们对设计的解读，**不是原文观点**。

---

## 1. 数据库 buffer pool + WAL

### 1.1 ARIES（Mohan, Haderle, Lindsay, Pirahesh, Schwarz, ACM TODS 17(1), 1992, pp.94–162）
来源 PDF（扫描版，逐页图像核对）：https://people.eecs.berkeley.edu/~brewer/cs262/Aries.pdf 【已核实】
（DOI：10.1145/128765.128770）

- steal / force 定义（§1.4, p.104）：
  > "If a page modified by a transaction is allowed to be written to the permanent database on nonvolatile storage before that transaction commits, then the steal policy is said to be followed by the buffer manager … Otherwise, a no-steal policy is said to be in effect."
  > "If a transaction is not allowed to commit until all pages modified by it are written to the permanent version of the database, then a force policy is said to be in effect. Otherwise, a no-force policy is said to be in effect. With a force policy, during restart recovery, no redo work will be necessary for committed transactions."
- 支持灵活 buffer 策略、偏好 steal（§2, pp.106–107）：
  > "The recovery method should make the least number of restrictive assumptions about the buffer management policies (steal, force, etc.) in effect."
  > "Even with large main memories, it must be noted that a steal policy is still very desirable. This is because, with a no-steal policy, a page may never get written to nonvolatile storage if the page always contains uncommitted updates …"
- 脏页后台持续写回（§1.4, p.103）：
  > "A page in the buffer pool is said to be dirty if the buffer version of the page has some updates which are not yet reflected in the nonvolatile storage version of the same page."
  > "[96] discusses the role of BM in writing in the background, on a continuous basis, dirty pages to nonvolatile storage to reduce the amount of redo work that would be needed if a system failure were to occur and also to keep a certain percentage of the buffer pool pages in the nondirty state so that they may be replaced with other pages without synchronous write I/Os having to be performed at the time of replacement."
  > "While performing those writes, BM ensures that the WAL protocol is obeyed. As a consequence, BM may have to force the log up to the LSN of the dirty page before writing the page to nonvolatile storage."
- WAL 协议（§1.1, p.97）：
  > "The WAL protocol asserts that the log records representing changes to some data must already be on stable storage before the changed data is allowed to replace the previous version of that data on nonvolatile storage."
- fuzzy checkpoint（§5.4, p.121–122）：
  > "Periodically, checkpoints are taken to reduce the amount of work that needs to be performed during restart recovery."
  > "Checkpoints can be taken asynchronously (i.e., while transaction processing, including updates, is going on). Such a fuzzy checkpoint is initiated by writing a begin_chkpt record. Then the end_chkpt record is constructed by including in it the contents of the normal transaction table, the BP dirty_pages table, …"
  > "ARIES does not require that any dirty pages be forced to nonvolatile storage during a checkpoint. The assumption is that the buffer manager is, on a continuous basis, writing out dirty pages in the background using system processes."
- redo 起点 = 脏页表最小 RecLSN，只检查脏页（§6.1–6.2, pp.123–125）：
  > "The RedoLSN is the minimum RecLSN from the dirty_pages table at the end of the analysis pass. The redo pass can be skipped if there are no pages in the dirty_pages table."
  > "The redo pass starts scanning the log records from the RedoLSN point."
  > "Thus, the RecLSN information serves to limit the number of pages which have to be examined."
  > "Since redo is page-oriented, only the pages with entries in the dirty_pages table may get modified during the redo pass. Only the pages listed in the dirty_pages table will be read and examined during this pass."
- repeating history（Abstract, p.94）：
  > "We introduce the paradigm of repeating history to redo all missing updates before performing the rollbacks of the loser transactions during restart after a system failure."
- 多份日志需两阶段提交（§1.1, p.96）——与第二阶段"按空间分进程、每区一份日志"直接相关：
  > "If more than one log is used for storing the log records relating to different pieces of data, then a form of two-phase commit protocol (e.g., the current industry-standard Presumed Abort protocol [63, 64]) must be used."
- 页面级恢复独立（§2 "Recovery independence", p.107）：
  > "The recovery of one object should not force the concurrent or lock-step recovery of another object."

推断：L0 区域 ≈ ARIES 的 page；"脏区域写回 + 冷区淘汰" = steal/no-force 下的后台写回；"检查点只记脏区域表、重放只看脏区域" = fuzzy checkpoint + RedoLSN=min(RecLSN)。我们是单写者、无事务回滚，所以 undo 部分（CLR、loser 事务）基本不需要——只用 redo 半边。

### 1.2 PostgreSQL（WAL Configuration, current）
https://www.postgresql.org/docs/current/wal-configuration.html 【已核实】
> "Checkpoints are points in the sequence of transactions at which it is guaranteed that the heap and index data files have been updated with all information written before that checkpoint. At checkpoint time, all dirty data pages are flushed to disk and a special checkpoint record is written to the WAL file."
> "In the event of a crash, the crash recovery procedure looks at the latest checkpoint record to determine the point in the WAL (known as the redo record) from which it should start the REDO operation."
> "To ensure data page consistency, the first modification of a data page after each checkpoint results in logging the entire page content." （full_page_writes）
> "With the default value of 0.9, PostgreSQL can be expected to complete each checkpoint a bit before the next scheduled checkpoint … This spreads out the I/O as much as possible so that the checkpoint I/O load is consistent throughout the checkpoint interval."

推断：PG 的 checkpoint 是"刷所有脏页"但分摊在整个间隔内（checkpoint_completion_target），与"只刷脏区域、分批写"一致；full_page_writes 提示：区域写回若非原子，需整区快照写入（或写临时文件后 rename）。

### 1.3 MySQL InnoDB
Buffer Pool：https://dev.mysql.com/doc/refman/8.0/en/innodb-buffer-pool.html 【已核实】
> "The buffer pool is an area in main memory where InnoDB caches table and index data as it is accessed."
> "When room is needed to add a new page to the buffer pool, the least recently used page is evicted and a new page is added to the middle of the list. This midpoint insertion strategy treats the list as two sublists:" （new/young 子表 + old 子表）
> "Eventually, a page that remains unused reaches the tail of the old sublist and is evicted."

Checkpoints：https://dev.mysql.com/doc/refman/8.0/en/innodb-checkpoints.html 【已核实】
> "InnoDB implements a checkpoint mechanism known as fuzzy checkpointing. InnoDB flushes modified database pages from the buffer pool in small batches. There is no need to flush the buffer pool in one single batch, which would disrupt processing of user SQL statements during the checkpointing process."
> "During crash recovery, InnoDB looks for a checkpoint label written to the log files. It knows that all modifications to the database before the label are present in the disk image of the database. Then InnoDB scans the log files forward from the checkpoint, applying the logged modifications to the database."

推断：InnoDB midpoint LRU 是为防扫描污染缓存；我们的"玩家窗口 pin + 有界缓存 LRU"可直接对应（窗口内区域 = fix count>0 不可替换，见 ARIES §1.4 fix/unfix）。

---

## 2. 体素游戏的区域存储与按需加载

### 2.1 Minecraft（Minecraft Wiki，社区维护，非 Mojang 官方）
Region file format：https://minecraft.wiki/w/Region_file_format 【已核实】
> "Each file stores a group of 32×32 chunks called a region."
> 文件名 "r.x.z.mcr"（Anvil 后为 .mca）；"These sectors are 4KiB large."；位置表每项 "the first 3 bytes referring to the offset in sectors from the start of the file" / "The last, and least significant byte giving us the size in sectors of the chunk's data."
> "Chunk data begins with a (big-endian) four-byte signed length field." 之后 1 字节压缩类型（GZip/Zlib/不压缩/LZ4/自定义），即**逐 chunk 压缩**。
（"按 chunk 单独读写"原文未直说；每 chunk 有独立偏移+长度，属推断。）

Chunk（加载等级与 ticket）：https://minecraft.wiki/w/Chunk 【已核实】
> "A chunk is a 16×16 segment of a world." / "the game loads only certain chunks in order to make the game playable."
> "Levels are numbers that determine what load type the chunk is in." / "A lower level represents a higher load type."
> "Load levels above 44 are instantly unloaded in vanilla."
> "Unloaded chunks are unprocessed by the game and do not process any of the game aspects."
> Player loading ticket："Tickets of this type define the area players load around themselves."
> Forced ticket："This type of ticket is created by the /forceload command." 持久化 ticket："The ticket is persisted when the world is shut down, meaning when the world starts up again, the ticket is restored."
> 等级随距离传播："each time it increases its level by 1 until the maximum of 44."
（Wiki 该页没有"卸载时写盘"原句——**未核实**。）

Commands/save：https://minecraft.wiki/w/Commands/save 【已核实】
> "/save-all … Saves player data immediately. Marks all chunks as needing to be saved." "They get saved over time to the data storage device."
> "/save-all flush … All the players and chunks are saved to the data storage device immediately, freezing the server for a short time."
> "/save-off … All level changes are temporarily queued."

Server.properties：https://minecraft.wiki/w/Server.properties 【已核实】
> view-distance："The amount of world data the server sends the client, measured in chunks in each direction of the player (radius, not diameter)."
> simulation-distance："If entities are outside of this radius, then they are not ticked by the server and they are not visible to players."
> sync-chunk-writes："Whether to enable synchronous chunk writes. This prevents data loss and corruption after a crash." "This can slow down the server due to I/O slowdowns."

【二手】SpigotMC 维护者 md_5 在 SPIGOT-6383 说 vanilla "/save-off" 时 "chunks do not unload at all to prevent data loss"（https://hub.spigotmc.org/jira/si/jira.issueviews:issue-html/SPIGOT-6383/SPIGOT-6383.html ，仅搜索摘要，未打开）。若成立，说明 vanilla 的卸载路径必经写盘——即"脏块不写回不得淘汰"。

推断：Minecraft 是"标记脏 → 后台逐渐写回、手动 flush 才全量同步"的 no-force 模型；区域文件 32×32 chunk、逐 chunk 定位与压缩，对应我们"L0 区域为持久化单位"。

### 2.2 Luanti（原 Minetest）
设置说明（引擎源码 builtin/settingtypes.txt）：https://raw.githubusercontent.com/luanti-org/luanti/master/builtin/settingtypes.txt 【已核实】
> active_block_range："The radius of the volume of blocks around every player that is subject to the active block stuff, stated in mapblocks (16 nodes). In active blocks objects are loaded and ABMs run. This is also the minimum range in which active objects (mobs) are maintained." 默认 4
> server_unload_unused_data_timeout："How long the server will wait before unloading unused mapblocks, stated in seconds. Higher value is smoother, but will use more RAM." 默认 29
> server_map_save_interval："Interval of saving important changes in the world, stated in seconds." 默认 5.3
> max_block_send_distance："From how far blocks are sent to clients, stated in mapblocks (16 nodes)." 默认 13
> active_object_send_range_blocks："From how far clients know about objects, stated in mapblocks (16 nodes)." 默认 8
> client_mapblock_limit："Maximum number of mapblocks for client to be kept in memory." 默认 9300

世界格式：https://raw.githubusercontent.com/luanti-org/luanti/master/doc/world_format.md 【已核实】
> "Luanti maps consist of MapBlocks, each holds 16x16x16 nodes."
> "map.sqlite is an SQLite3 database, containing a single table, called blocks."（5.12 前 schema：`CREATE TABLE blocks (pos INT NOT NULL PRIMARY KEY, data BLOB);`）
> "pos = (z << 24) + (y << 12) + x;"
> 版本 29："the entire block is first serialized and then compressed (except version byte)."

数据库后端：https://docs.luanti.org/for-server-hosts/database-backends/ 【已核实】
> "The map database stores mapblock data. The backend is set using the backend setting in world.mt."（SQLite3 默认；LevelDB/Redis/PostgreSQL 可选；文档称 PostgreSQL "can more efficiently manage very large map databases"，LevelDB 有可靠性问题）

推断：Luanti 是与我们最贴近的先例——**三维**块（16³）为持久化单位、KV 表（坐标哈希→BLOB）、玩家周围"活跃半径"、不用的块按超时卸载、脏改动按固定间隔保存；且"活跃范围"（模拟）与"发送范围"（网络）是两个独立参数。

### 2.3 Vintage Story
https://wiki.vintagestory.at/Modding:VCDBS_format 【已核实】（官方 wiki 的 modding 页）
> "The VCDBS file holds the main save game data." "At the top level it is a sqlite database"
> "A row in the chunk table covers a 32x32x32 section of the world."（键为 ChunkPos 整数）
> mapchunk："Each mapchunk row has 2d data for a column of chunks"；mapregion："Each row contains 2D data for a 16x16 section of mapchunks."
（卸载/保存策略原文**未核实**。）

### 2.4 Space Engineers
**未核实**：未找到 Keen 官方关于"只存修改体素/按距离加载"的原文。KeenSWH 支持论坛 "Mined voxels appear filled in" 帖（https://support.keenswh.com/spaceengineers/pc/topic/42169-mined-voxels-appear-filled-in ，仅搜索摘要）提到大 VX2 文件导致客户端不同步，属【二手】，不建议引用。

---

## 3. 空间分区 authority 与跨边界

### 3.1 SpatialOS（Improbable，产品已停止；文档站下线）
Authority and interest 简介：http://web.archive.org/web/20210928051000/https://documentation.improbable.io/spatialos-overview/docs/authority-and-interest-introduction 【已核实·存档】
> "To ensure that only one worker instance at a time sends updates to the entity database about an entity component, SpatialOS has the concept of write access authority."
> "Which worker instance has write access authority during runtime depends on how you set up your load balancing configuration."
> "Because worker instances might need to know the status of entity components that they don't have write access authority over, they can have interest in those entity components."

Workers and load balancing：http://web.archive.org/web/20210803171255/https://documentation.improbable.io/spatialos-overview/docs/workers-and-load-balancing 【已核实·存档】
> "So when you're writing the code for server-workers, you need to write code that can cope with only knowing about part of the world. Writing code to deal with an arbitrary and not-necessarily-contiguous part of the world is the biggest difference from standard game development. It is the largest paradigm change when using SpatialOS …"
> "Zoning is a grid-based load balancing strategy that divides computation up for multiple server-worker instances by areas of authority. Offloading is an alternative load-balancing strategy, which divides computation up by entity type."
> "We recommend trying to scale your game early. You should test with at least two server-worker instances running your world. Some problems won't be obvious until you have multiple server-worker instances behind your game world."
> "client-workers can see across server-worker boundaries"

Handing over write access authority：http://web.archive.org/web/20210928051122/https://documentation.improbable.io/spatialos-overview/docs/handing-over-write-access-authority 【已核实·存档】
> "write access authority over a component can pass between different server-worker instances. This could happen if the ACL of a component changes, if load balancing switches which worker instance has write access authority, or if the entity moves into another worker instance's area of authority."
> "Latency between the Runtime and worker instances can cause lost updates"
> "By default, the timeout is set to 0 milliseconds (meaning there's no time for worker instances to send updates)." "If the timeout is less than this, updates might still be dropped"

推断：SpatialOS 的教训正好支持"第一阶段不分进程"：分区 authority 的最大代价是所有逻辑都得能"只知道部分世界"，且交接窗口存在丢更新风险。第一阶段仍是单写者，只把**存储与常驻**分页，不引入 authority 交接。

### 3.2 EVE Online
CCP Mindstar, "My node was equipped with the following...", 2008-10-06：https://www.eveonline.com/news/view/my-node-was-equipped-with-the-following... 【已核实】
> "The cluster is divided across 90 - 100 SOL blades which run 2 nodes each."
> "Node - a single EVE server process."
> "Dedicated SOL blade - These are SOL blades that we dedicate to one system only." "Systems such as Jita, Motsu and Saila reside on these."
> "we will be proactively working to place fleet fight systems onto a dedicated node at downtime."

CCP, "Introducing Time Dilation (TiDi)"：https://www.eveonline.com/article/introducing-time-dilation-tidi 【已核实】
> "Time dilation slows down time so the server can keep up with what y'all are doing."
> "the idea here is to slow down the game clock enough to maintain a very small queue of waiting tasklets"

"一个星系不能跨节点拆分"：**未核实**官方原句（只在玩家论坛与二手报道中出现）。可引用的事实只到"节点=单进程、星系被分配到节点、热点星系独占节点、过载时靠时间膨胀"。
推断：EVE 是"以天然隔离的空间单元（星系）为 authority 单位、单元内单线程串行、按负载把单元重映射到节点"的工业先例，对应我们第二阶段"按区域分进程"。

### 3.3 Dual Universe（CSSC，Continuous Single-Shard Cluster）
MMOs.com（Matt Chelen, 2016-08-16）转述 Novaquark 视频：https://mmos.com/news/novaquark-explains-how-dual-universes-server-works 【二手，已打开该二手页】
> "The server software dynamically splits clusters of players into cube-shaped shards based on location"，并 "distribute the load across multiple servers"
（注意：任务里写的 "CSSO" 应为 **CSSC**。Novaquark 一手技术文档/视频原文**未核实**；边界交接机制原文**未核实**。）

### 3.4 跨区域事务/边界
- ARIES §1.1（见 1.1）：多份日志需两阶段提交（Presumed Abort）。【已核实】——第二阶段若每区域进程各自 WAL，跨区操作要么 2PC，要么交给单写者串行。
- SpatialOS：interest（只读视图）跨边界、authority 单一、交接可能丢更新。【已核实·存档】
- 区域交接/边界可见性的学术资料（MM-VISA 论文、"Slide" 换区模型、arXiv 0807.2328 正文）：**未核实**（只看到搜索摘要；0807.2328 摘要只提到 "server load balancing and zone partitioning"，https://arxiv.org/abs/0807.2328 【已核实】）。
- "ghost/halo" 这一术语在游戏服务器公开文档中的一手出处：**未核实**。

---

## 4. Erlang/BEAM 侧可行性

### 4.1 进程堆与 GC
ERTS Garbage Collection：https://www.erlang.org/doc/apps/erts/garbagecollection.html 【已核实】
> 收集器为 "a per process generational semi-space copying collector"
> "Each Erlang process has its own stack and heap which are allocated in the same memory block"
> "the garbage collection algorithm used is proportional to the amount of live data on the heap"
推断：GenServer 状态里持有整个世界 = 该进程的活数据随世界线性增长，每次 major GC 复制全部活数据；把冷区域移出进程状态直接降低 GC 成本。（"大堆导致 GC 昂贵"这一句原文未直说，属由"与活数据量成正比"推出。）

### 4.2 Binary
Efficiency Guide – Constructing and Matching Binaries：https://www.erlang.org/doc/system/binaryhandling.html 【已核实】
> "Heap binaries are small binaries, up to 64 bytes, and are stored directly on the process heap." "They are copied when the process is garbage-collected and when they are sent as a message."
> Refc binary 的数据体："The binary object itself, stored outside all process heaps." "The binary object can be referenced by any number of ProcBins from any number of processes." "The object contains a reference counter …"
推断：区域的序列化体（>64 B）作为 refc binary 存放时，GC 只复制 ProcBin 头，不复制数据体——"区域以压缩 binary 驻留缓存"在 GC 上便宜。

### 4.3 ETS
https://www.erlang.org/doc/apps/stdlib/ets.html 【已核实】
> "These provide the ability to store very large quantities of data in an Erlang runtime system, and to have constant access time to the data."
> "Notice that there is no automatic garbage collection for tables."
> "In the current implementation, every object insert and look-up operation results in a copy of the object."
> "When the process terminates, the table is automatically destroyed."（可用 heir / give_away 转移）
Memory 指南：https://www.erlang.org/doc/system/memory.html 【已核实】把 ETS 单列："Initially 768 words + the size of each element (6 words + the size of Erlang data). The table grows when necessary."
推断（原文未直说"off-heap"四字）：ETS 数据不在进程堆、不参与进程 GC；代价是每次读写复制对象（大 binary 例外，按 refc 共享）。适合存"区域 id → 压缩 binary"，不适合每 tick 取出大 map 再改。

### 4.4 persistent_term
https://www.erlang.org/doc/apps/erts/persistent_term.html 【已核实】
> "The lookup will be made in constant time and the value will not be copied to the heap of the calling process."
> "is suitable for storing Erlang terms that are frequently accessed but never or infrequently updated."
> "Updating or deleting a persistent term will trigger a global GC if the term does not fit in one machine word." "All processes in the system will be scheduled to run a scan of their heaps for the term that has been deleted."
> "Storing or updating a term (using put/2) is proportional to the number of already created persistent terms"
结论：可编辑世界数据**不应**放 persistent_term；只适合启动后不变的材质表/配置。

### 4.5 DETS / Mnesia
DETS：https://www.erlang.org/doc/apps/stdlib/dets.html 【已核实】
> "The size of Dets files cannot exceed 2 GB."
> "Notice that type ordered_set in Ets is not yet provided by Dets"
> "The Dets functions are therefore much slower than the corresponding ets functions"
> "If a table is not properly closed, Dets automatically repairs the table."
Erlang FAQ – Mnesia：https://www.erlang.org/faq/mnesia 【已核实】
> "Mnesia is primarily intended to be a memory-resident database."
> "For ram_copies and disc_copies, the entire table is kept in memory, so data size is limited by available RAM."
> "Note that for disc_copies tables, the entire table needs to be read from disk to memory on node startup, which can take a long time for large tables."
> "disc_only_copies tables are limited to 2 GB each." "the Dets file format uses signed 32-bit integers for file offsets."
推断：Mnesia disc_copies 等于"全量常驻+启动全量加载"，正是要摆脱的模式；disc_only_copies 受 DETS 2GB/慢的限制。

### 4.6 嵌入式 KV（Elixir/Erlang 生态）
- CubDB：https://cubdb.hexdocs.pm/readme.html 【已核实】 "CubDB is an embedded key-value database for the Elixir language."（页面另述：ACID 原子事务、读写并发不阻塞、崩溃不损坏、可压缩、append-only 树——此处为页面要点概述，非逐句原文）
- erlang-rocksdb（hex 包 `rocksdb`，benoitc 维护）：https://hex.pm/packages/rocksdb 、https://github.com/EnkiMultimedia/erlang-rocksdb 【已核实】 "Erlang wrapper for RocksDB."；要求 "Erlang 22+ with dirty-nifs enabled"；hex 页显示总下载 259,280、最新 3.1.2（2026-10-24 查看）。
- mnesia_rocksdb（Aeternity）：https://github.com/aeternity/mnesia_rocksdb 【已核实】 "A RocksDB backend plugin for mnesia, based on mnesia_eleveldb."；README 称 dets "limited to 2 GB per table"。
- Riak eLevelDB：https://docs.riak.com/riak/kv/latest/setup/planning/backend/leveldb/index.html 【已核实】 "eLevelDB is an Erlang application that encapsulates LevelDB, an open-source, on-disk key/value store"；"This design and implementation provide the possibility of a storage engine without Bitcask's RAM limitation." / "Bitcask stores keys in memory, so for databases with large number of keys it may exhaust available physical memory"。basho/eleveldb README：https://github.com/basho/eleveldb 【已核实】 "This project provides erlang bindings to a LevelDB datastore heavily optimised for Riak workloads."
- leveled：https://github.com/martinsumner/leveled 【已核实】 "A pure Erlang Key/Value store - based on a LSM-tree, optimised for HEAD requests"，定位为 Riak KV 后端候选。
**更正任务前提**：Riak/leveled 并不使用 RocksDB——Riak 用 eLevelDB（LevelDB 绑定）或 Bitcask，leveled 是纯 Erlang LSM。RocksDB 在 BEAM 上的例子是 erlang-rocksdb 与 Aeternity 的 mnesia_rocksdb。LMDB 的 Elixir/Erlang 工业用例：**未核实**（本次未查到可靠一手出处）。
推断：Riak 文档对 Bitcask（键全常驻）vs LevelDB（键不必常驻）的对比，正是"全量常驻 vs 分页"在 BEAM 工业系统中的同一取舍。

---

## 5. 网络：只发变化 / 兴趣管理

### 5.1 Valve Source 引擎
Source Multiplayer Networking：http://web.archive.org/web/20261011091858/https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking 【已核实·存档】（原站返回反爬页）
> "Game data is compressed using delta compression to reduce network load. That means the server doesn't send a full world snapshot each time, but rather only changes (a delta snapshot) that happened since the last acknowledged update."
> "Usually full (non-delta) snapshots are only sent when a game starts or a client suffers from heavy packet loss for a couple of seconds."
Networking Entities：http://web.archive.org/web/20260411145930/https://developer.valvesoftware.com/wiki/Networking_Entities 【已核实·存档】
> "Whenever a networked member variable changes, the Source engine must know about it to include an update message for this entity in the next snapshot broadcast."
> "A player's PVS is usually used to filter entities before transmitted to the client, but more complex filter rules can also be defined in an entity's UpdateTransmitState() and ShouldTransmit() virtual functions."
（"instance baseline / 只发与默认值不同的字段"原文**未核实**——本次未在两页中找到 baseline 原句。）

### 5.2 Unreal Engine 官方文档
Actor Relevancy：https://dev.epicgames.com/documentation/en-us/unreal-engine/actor-relevancy-in-unreal-engine 【已核实】
> "Unreal Engine levels can be very large." "At any time, a player might only see a small fraction of the total number of actors in a level." "Unreal Engine only replicates actors to a client if they are relevant for that client."
> NetCullDistanceSquared："Square of the maximum distance from the client's viewport that this actor is relevant and replicates."
Actor Network Dormancy：https://dev.epicgames.com/documentation/en-us/unreal-engine/actor-network-dormancy-in-unreal-engine 【已核实】
> "An actor's network dormancy controls whether the actor is added to the connection's gathered actors list."
> "This saves time otherwise spent considering the actor for replication and comparing its properties."
> "Until a dormant actor is awoken or has its dormancy flushed, the actor is not considered for replication"
> DORM_Initial："This actor is initially dormant on all connections."
推断：dormancy 是"静止物体不进每帧复制候选"的服务器 CPU 优化，对应"冷区域不进入每 tick 工作集"；DORM_Initial 对应"关卡/世界初始内容默认不发，变化后才唤醒"。

### 5.3 学术：兴趣管理
Boulanger, Kienzle, Verbrugge, "Comparing Interest Management Algorithms for Massively Multiplayer Games", NetGames 2006（DOI 10.1145/1230040.1230069）。PDF：https://www.sable.mcgill.ca/~clump/papers/boulanger-06-comparing.pdf 【已核实，首页图像逐字核对】
> "Broadcasting all state changes to every player of a massively multiplayer game is not a viable solution. To successfully overcome the challenge of scale, massively multiplayer games have to employ sophisticated interest management techniques that only send relevant state changes to each player."
> "We show that interest management algorithms that take into account obstacles in the world reduce the number of update messages between players by up to a factor of 6, and that some computationally inexpensive tile-based interest management algorithms can approximate ideal visibility-based interest management at very low cost."
> "Interest management (IM) is the process of determining which information is relevant to each player [16]."

---

## 汇总：可直接写进决策稿的结论 vs 仍缺口

可用（一手、已核实）：
1. ARIES：steal/no-force、后台持续写回脏页、fuzzy checkpoint 只记脏页表、redo 从 min(RecLSN) 起且只看脏页——是"脏区域写回、检查点只做脏区域"的理论依据；同一论文指出多日志需 2PC。
2. PostgreSQL/InnoDB：检查点后从 redo 点前滚；InnoDB 分小批刷脏页、midpoint LRU 淘汰。
3. Luanti：16³ mapblock 为持久化单位、SQLite KV（坐标哈希→BLOB）、active_block_range、超时卸载（默认 29 s）、定期保存（5.3 s）。
4. Minecraft：32×32 chunk/region、逐 chunk 偏移与压缩、ticket/load level 只加载玩家周围、save-all 只"标记脏后逐步写"。
5. Vintage Story：SQLite，32³ chunk 一行。
6. BEAM：进程 GC 与活数据量成正比；>64 B binary 离堆引用计数；ETS 无自动 GC、读写复制；persistent_term 更新触发全局 GC；DETS 2 GB；Mnesia disc_copies 全量常驻且启动全量读。
7. SpatialOS：单写者 authority、zoning、"只知道部分世界"是最大范式变化、交接可能丢更新。
8. Valve delta 快照 + PVS 过滤；UE relevancy/dormancy；Boulanger 2006 兴趣管理。

缺口（未核实）：EVE"星系不可跨节点"官方原句；Dual Universe 一手技术资料与边界交接；Space Engineers 体素存储；Minecraft 卸载必写盘的一手原文；Vintage Story 卸载策略；"ghost/halo"游戏一手出处；Valve baseline 原句；LMDB 在 Elixir 的工业用例。
