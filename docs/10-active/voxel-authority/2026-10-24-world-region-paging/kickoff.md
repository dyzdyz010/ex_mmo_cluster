# 开工说明：世界真值按区域分页（2026-10-24）

给执行会话的接力说明。正文以决策稿为准：[`../2026-10-24-world-region-paging.md`](../2026-10-24-world-region-paging.md)（approved v4）。

## 已批准
- v4 全文；Q1 按稿内建议，单个电路连通分量超出 ticket 上限时取 **(c) 接线时拒绝使分量超限的连接**；Q5 接受确定序，迁移时一次性重算并逐项记录差异；
  Q2 页存 PG 新表；Q3 协议 42 与 P 系列联合设计、分开交付；Q4 先冻结测量定义，数值在 M0 之后定；Q6 留第二阶段。
- 顺序与门槛见稿内“交付顺序”“开工门槛”：M0 → M1（按子项前置）→ M2 → M3 → M4。

## 先读
1. 决策稿 v4 全文；`review-*-r3*.md` 两份交叉评审的 v4 清单（理由在那里）。
2. `D:\hemifuture\ex_mmo_cluster\AGENTS.md`（§2.2；协议 / 事务 / 持久化改动的决策稿规则——本稿即是）、`D:\hemifuture\Voxim\AGENTS.md`、`D:\hemifuture\Voxim\Docs\Testing.md`。
3. 调研附录 `recon-*.md`（file:line 级现状）。

## 环境事实
- 本机 32 逻辑核、31.8 GiB 内存。开发期服务端在 **Windows 原生**运行，不为日常改动构建 Docker 镜像（镜像只用于分发）。
- 演练副本（Docker，生产镜像 ffa336c7）仍在运行：容器 `voxim-qinglan-ruyuan-20261023`（端口 26744/26745）、PG `voxim-pg-qlry1023`（库 `voxim_qinglan_ruyuan_20261023`，
  如园 15 批已装，seq 14615）、`voxim-mail-qlry1023`。它是 M0 现成的“1 份如园”数据来源（可 pg_dump 到隔离库再用原生服务端加载）；**不要改写它**，用完是否停掉问用户。
  常驻约 2.2 GB，启动峰值 VmHWM 6.5 GB——开发机上同时跑多份要先估内存。
- 既有失败（ffa336c7 上同样失败，不计入）：body_contact_world_test 10、thermal_edit_world_test 2、thermal_domain_equivalence 1、generated_store “native returns the existing raw payload body”。
- 旧堆探针：Voxim `Saved/Playtest/release-20261023/Server/heap_probe.ex`（`:erts_debug.flat_size` 分字段）、基线 `heap-probe.json`。
- 不相干的东西别碰：ex_mmo_cluster 的 `effects-layer` 分支（另有归属，合并须问用户）；Voxim 未提交的 `Content/Playtest/Connection/session.json`（故意不提交）。

## 踩过的坑（务必避开）
- 探针 / 采样只发一次、在节点里编译成模块再跑；**rpc 返回非 JSON 时不要循环重试**——10-23 曾因此在节点上堆出数百个采样进程吃到 14 GB。
- `eval` 里的匿名函数是解释执行，逐格循环必须编译成模块。
- `:sys.get_state(VoxelRegion.World)` 会把整份 World 状态复制进调用进程；大世界上用 `:sys.replace_state` 在进程内取值。
- 避免瞬时峰值：不放宽护栏硬推；客户端启动间隔 ≥ 2 分钟；UDP < 2000。

## 工作方式
- 用户要求：本会话统筹，可用 subagent 并行提高效率；面向用户的汇报一律中文；按 Voxim AGENTS.md “执行纪律”先接通最短可运行闭环，审查不阻塞集成。
- 每个里程碑：实现 → 最小充分验证（Testing.md）→ 在稿内“进度日志”记一笔（命令、结果、证据位置）→ 向用户汇报“新增了什么可观察行为 / 在哪个真实场景验证 / 还差什么”。
- 提交须用户同意；同一可变状态（数据库、世界区域、构建目录）只有一个写者。
- 证据与媒体：日志 / 测量放 Voxim `Saved/Playtest/paging-20261024/`（或服务端仓相应 Test-only 位置），截图录屏放 Voxim `Captures/`。
- M0 结果出来后，按稿内“验收”冻结数值并给出 M1–M4 工期，交用户确认。
