# 第二阶段拆分稿 v7 复核任务（单轮）

只读复核：不改代码、不改设计稿、不提交、不运行服务或测试、不对 Docker / 数据库做任何操作、不切换 git 分支。唯一写入为你的复核报告。本轮是 v7 唯一一轮复核，之后不再交叉。

## 对象
- 设计稿 v7（未提交）：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-26-voxel-authority-sharding.md`（§0 为 v6→v7 变更表：M1–M8 合并清单、U-* 用户决定、R1–R6 统筹裁定）
- 改写报告：同目录 `2026-10-24-world-region-paging/v7-draft-report.md`
- v6 原文（未入 git，评审报告按其行号引用）：`D:\hemifuture\Voxim\Saved\Playtest\paging-20261024\sharding-v6-uncommitted.md`
- v6 评审与合并清单：`2026-10-24-world-region-paging/review-{fable,astra}-sharding-v6.md`、`review-{fable,astra}-sharding-v6-cross.md`（§6）
- 源码与约束同前轮；尤其 `D:\hemifuture\ex_mmo_cluster\AGENTS.md`、`D:\hemifuture\Voxim\AGENTS.md` 的设计 / 执行纪律（极简、只处理当前问题、评审不阻塞集成）

## 用户决定（已定，不再讨论取舍）
边缘零停顿；传送一律进加载（含同一窗口、单分区）；D13 保持 Q1 取 ②；D9 足迹触他岛排队并触发合并、不拒绝；D10 合并后保留全部过程；D7 A″ 认领期间他人编辑延后到决定后。

## 请回答
1. 合并清单 M1–M8 逐条：v7 是否已形成一致、可实施、可证伪的规则（而非 TODO）；吸收错或新引入的问题，给时序反例。
2. 起草者自报最可能被挑的 3 点（`v7-draft-report.md` 末）：迁移历史写回完备性与“提前常规切点”、交接载荷与对话结束、唯一规划者容量与转发不成环——各自是否成立。
3. 删除的 v6 机制（§0 末）有无删错、导致原问题复活。
4. 工程约束依从：是否仍有为未发生问题预建的机制、无当前调用方的参数 / 状态 / 框架、与父稿重复的内容；内容分类与“S0 可并行开工”是否成立。
5. 结论：能否批准为第二阶段方向稿。不能则列批准前最少必改（≤ 4 条）；其余放“交付步处理”。

每条标【严重】【中】【轻】，给稿内章节 + 源码 file:line 证据，推断标“推断”。不重提 v6 轮已闭合且 v7 未改动的问题。

## 输出
中文报告，末尾 8 行以内总评：
- Fable：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\review-fable-sharding-v7.md`
- Astra：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\review-astra-sharding-v7.md`
