# 移交：角色能力函数库与“往世界里放 NPC”（2026-10-09，Claude → Codex）

分类：Global system 工作交接。用户 2026-10-09 要求把工作移交给 Codex。面向用户的回复一律中文。

> **Codex 收尾状态（2026-10-09）**：run07 六小时与一次短双端观察已完成取证，验收未通过；结论和证据唯一正文见[放 NPC 阶段决策稿 §6.1](2026-10-08-npc-placement-phase.md)。Demo 已停止并保留，采样器已结束；不要再按旧移交状态重启本轮。后续问题须先与用户确认。

## 1 用户目标与已拍板事项

- 目标：统一函数库（玩家操控 / 行为树 / LLM / Jev 复用同一套能力定义与同一裁决入口），然后往世界里放 AI NPC 持续开拓改造世界（“24 小时搞建设”）。
- 已拍板（全部写在下面两份决策稿里）：死亡门对玩家生效；原始编辑后门 0x70/0x78 **保留**给创世 NPC 用（创世能力 `fill_box` / `set_cells` 走同一 World 入口）；正式服 NPC 取料规则未定；NPC 注册表/重启恢复已做；
  LLM 用 `gpt-6.1-sol` + effort `high`；花费上限可接受：每个 LLM NPC 每小时 20 次决策（滑动窗口）、住民每座房子设计约 10–20 万 token；
  **记忆照常记**（现有 npc_memories 是过渡，后期接独立记忆系统、与 NPC 完全解耦，不要为记忆写入加过滤/节流）；
  长跑放在机制之后；验收标准是“持续扩展”（三个 NPC 都持续扩张，不是只活着）。

## 2 代码与分支

- 服务端 worktree：`C:/Users/DYZ/Documents/dev/hemifuture/ex_mmo_cluster-capabilities`，分支 `capability-library-20261007`（基于 master f94a3d72），**全部已提交、未推送、未合并 master**。
  HEAD 见 `git log`；主要提交：I1 b363f122、I2 33377ad2、I3 60f01c75、I4 c727418f（合并 6b95d110）、v4 魔法夹具 f7438006、实跑修复 65a7f02a、注册表/创世 dd0c0f46、M3 碰撞修复 690369e0（合并 3e3b8863）、
  design_house 登记 b82109c0、wait 上限 20131e8b、花草寻路/超时/三次 look 93c6f098、micro_boxes 65cecb84、滑动窗口 ef7fd20d、expand 66470ff6、travel a8a8e1c7、run06 四缺陷 c3e76aff。
- Voxim 客户端零改动（协议 Hello 39 不变）。Voxim 主树只在 git 忽略的 `Saved/CapabilityLibrary-20261008/` 与 `Captures/CapabilityLibrary/` 下有 Test-only 脚本与证据。
- **不要**在 `../ex_mmo_cluster` 主树或 Voxim 主树里切分支 / 还原 / 提交（共享工作区，别的会话在用；主树有别人的账号副本改动）。

## 3 必读文档（权威正文）

- 能力库决策稿：`docs/10-active/cross-cutting/2026-10-07-character-capability-library.md`（§5 Abilities、§6 能力表、§7 Intent 契约、§8 后端投影、§13 拍板、§14 进度）。
- 放 NPC 阶段决策稿：`docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md`（§2 注册表、§3 创世、§7 持续扩张契约/取舍/依据、§6 进度日志——run02–run06 的全部发现与修复都在这里）。
- 接入说明：`apps/gate_server/lib/gate_server/npc/README.md`；命令表：`npc/brain.ex` moduledoc；注册表 params：`npc/registry.ex` moduledoc。

## 4 测试

- `cd apps/<app> && MIX_ENV=test MMO_DB_PORT=26909 MMO_DB_PASSWORD=p0_body_test_only mix.bat test --no-start <files>`（Windows Git Bash；完整输出写文件再看）。同一 worktree 同时只跑一个 mix。
- 已知基线失败（与本工作无关，不得据此改测试）：gate_server `T1TransportTest` 57 项（quicer 只在 Linux）；scene_server 12 项缺 E1_FIXTURE / IS_FIXTURE；voxel_region BodyContactWorldTest 10 项（魔法夹具 v2）与 ThermalDomainEquivalenceTest 1 项（HEAD 上就红）。
  c3e76aff 时：gate_server 268/325（失败只有那 57 项），scene_server 249/261。

## 5 长跑 run07（已收尾；以下保留移交背景）

- 本地 Demo 容器 `voxim-caplib-20261008`（镜像 `voxim-server:20261008-caplib-c3e76aff`，HTTP 26761 / QUIC 26763，PG 容器 `voxim-pg-caplib-20261008` 库 `voxim_caplib_run07`）移交时仍在运行；严格六小时为 21:09:09–03:09:09 UTC，观察后于 03:14:20 UTC 正常停止，容器未删除。
- 设施与证据：Voxim `Saved/CapabilityLibrary-20261008/`：`deploy.py`、`reg7.py`、`sampler7.py`、`observe07.py`、`rpc.py`；`run07/notes.md`（时间线、坐标、每小时数字）、`run07/samples.jsonl`。
  移交时采样器 sampler7.py 已随前一个值守代理停止（最后一条样本 00:11:44 UTC，elapsed 182.6 min，seq 2187，实例 114）。Codex 于 00:41:03 UTC 用 `sampler7.py --hours 6` 恢复，03:10:00 自行结束。**更正：--hours 是从 register_utc 起的总时长，不能传剩余小时。** 约 29 min 20 s 的权威采样空档及其限制见阶段稿 §6.1。
- 至 23:10 的数字（run07/notes.md）：建设者 56 → 87 块面板（第 2 小时 +31），住民 3 座房子（设计会话 18–23 万 token / 座，平整出现 uneven 跳过），创世者 7 块（729 列）整平且改用 survey 核对；成本保护 0；BEAM 407–490 MB 无上涨；Body 重启 / Player 异常 0。
- 收尾已完成：恢复采样并值守至终点；一次双端观察 198.545 s，O1–O3 通过、O4/O5 未通过；14 张实际截图均已查看，存 Voxim `Captures/CapabilityLibrary/2026-10-09/run07/`；Demo stop 保留。执行细节、限制及剩余问题统一见阶段稿 §6.1。
- LLM key 在 `C:/Users/DYZ/Documents/dev/hemifuture/ex_mmo_cluster/.env`，**不得写进任何文件、日志、报告**；容器创建时用 `docker create -e NPC_LLM_KEY` 从进程环境继承。

## 6 已知未完成 / 后续

- run07 新发现：创世者第 6 小时重复处理已完成地块，没有新增整平；B 端观察站位的原生碰撞查询 not_found，回放未完成。后续诊断 / 修复先与用户确认，不自动重启长跑。
- 住民补料：东北坡陡坡站位常 no_path / stuck，gather 多次失败后改去别处；设计会话 token 接近 24 万会话预算（每轮重发全部历史）。
- expand 平整不是事务；细化格按整格保守处理；离 NPC 竖直 > 32 m 的地块归为 region_full 一类（见 §7 取舍）。
- M4 客户端 `dead` 中文文案推迟到下次客户端发版（UE 资产，经 MCP）。
- 分支未推送、未合并 master；合并前须与用户确认（公网青岚驿仍是旧镜像，部署需同时考虑）。
- 24 h 验收在 6 h 持续扩展验收通过之后。
