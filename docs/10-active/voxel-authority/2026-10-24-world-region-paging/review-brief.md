# 评审任务：世界真值按区域分页决策稿（2026-10-24）

你是独立评审人，只读评审，不改任何代码或决策稿。

## 评审对象
- 决策稿：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging.md`
- 附录（调研原文，供核对，不是结论）：同目录 `2026-10-24-world-region-paging/` 下 recon-state-persistence.md、recon-operations.md、recon-observation.md、research-paging-evidence.md
- 被替代的旧稿：同目录 `2026-10-23-world-memory-compaction.md`
- 工程约束：`D:\hemifuture\ex_mmo_cluster\AGENTS.md`（尤其 §2.2：极简、DRY、SSOT、信任边界校验一次、不过度兜底、证据优先、自然数据流）与 `D:\hemifuture\Voxim\Docs\Testing.md`
- 源码：`D:\hemifuture\ex_mmo_cluster\apps\voxel_region\lib\voxel_region\`（world.ex、world/*.ex）、`apps/data_service/lib/data_service/voxel/overlay_log_store.ex`、`apps/mmo_contracts/lib/mmo_contracts/voxel/`；客户端 `D:\hemifuture\Voxim\Source\Voxim\Voxel\Net\`

## 用户目标（不可改）
超大世界、近景窗口处处是如园级复杂度时，服务端内存仍稳定：常驻 = O(活跃区域)+有界缓存；每笔成本 = O(涉及区域)；启动/检查点 = O(脏区域)。

## 请回答
1. **能否达成目标**：按稿子做完 M0–M4，三条斜率是否真的都变平？找出仍会随世界总量增长的残余项（常驻、每笔、启动、检查点、下发），给 file:line。
2. **正确性风险**：淘汰/装页与单写者事务原子性、崩溃恢复（WAL 与页写回顺序、page_seq 幂等、日志截断点）、跨区实例树与部件 HP 池（g=2）的 home 规则、ring、L1–L5 粗层页（L5 区域覆盖 32³ 个 L0 区）、液体/热/电路的 ticket 边界、订阅旧游标、全局 seq。有没有会造成真值丢失、重复或第二真值的地方？
3. **核对事实**：抽查稿中关键 file:line 断言是否与源码一致（至少 10 处），列出错误或过时的。
4. **更简单的方案**：有没有更少改动、同样满足三条斜率的做法？稿子里有没有过度设计、违背 AGENTS.md §2.2 的部分？
5. **依据**：外部依据是否足以支撑各决策；哪些决策其实是原创但没标出来。
6. **交付顺序与验收**：M0–M4 顺序、M0 基准设计是否能证伪；测试矩阵漏了什么；验收数值是否合理。
7. **Q1–Q4 决策点**：你的建议与理由。

## 输出
写到下面指定的文件（中文，按上面 7 节组织，每条标【严重】【中】【轻】，给 file:line 证据；推断标“推断”）。最后给一段 10 行以内的总评。
