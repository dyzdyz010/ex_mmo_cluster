# 文档大重构 · 决策稿（2026-07-08）

> 状态：active（执行中）。本稿是 `docs/` 目录从"按时间/来源堆叠"重构为"按功能分层"的单一决策来源。
> 执行完成后本文件随重构归入 `20-archive/`（子系统 = infra/meta 或 docs-governance）。

## 1. 目标

把 `docs/` 从当前 8 处散落、有效与失效混杂、"此刻为真"不完整且带 drift 的状态，重构为**按功能分层、有效/失效清晰隔离、每层有 README 说明用途、当前事实有唯一权威专属文件夹**的干净结构。

## 2. 范围

全 `docs/`：**180 项**（179 `.md` + 1 `.docx`），覆盖 `current_status/`(12)、`voxel-server-authority/`(53)、`original/`(81)、`plans/`(19)、`design/`(4)、`superpowers/`(8)、`character/`(1 docx)、根散落 2 篇。同时更新仓外硬引用文档路径的 `CLAUDE.md` / `AGENTS.md` / 根 `README.md`。

不改任何代码；不 push（除非用户明确要求）。

## 3. 用户拍板决策项（Gate ①，2026-07-08）

| # | 决策 | 选择 |
|---|---|---|
| D1 | 重构策略 | **按功能物理重排**（git mv，保留历史，重写全部交叉链接） |
| D2 | 失效文档处理 | **移入 `90-obsolete/` + 头部盖戳**（frontmatter + 醒目横幅，保留 provenance） |
| D3 | 范围 | **全 `docs/`（180 项）** |
| D4 | 文件夹命名 | **英文 + 数字前缀**（`00-`/`10-`/`20-`/`30-`/`90-`），中文用途写在各 README 顶部 |

## 4. 目标结构

```
docs/
├── README.md              文档地图：5 文件夹用途 + 如何找"当前为真" + 状态标记规范
├── 00-current-truth/      【当前事实·唯一权威】此刻为真（由 current_status/ 升级 + 修 drift）
│   └── README.md          （内部保留 impl/、design/<域>/ 子结构）
├── 10-active/             【活跃工作】在执行/下一步就做/让路待恢复 的决策稿与阶段计划
│   └── README.md          <subsystem>/…
├── 20-archive/            【已完成·有效历史】收口的阶段记录/决策/诊断
│   └── README.md          <subsystem>/…
├── 30-reference/          【长稳参考】工程指南/线协议规范/术语表/契约真值/仍权威的架构概览
│   └── README.md
└── 90-obsolete/           【失效·仅存 provenance】被推翻/废弃
    └── README.md          <subsystem>/…
```

## 5. 分类决策树（每个文件唯一可判定）

按顺序命中第一条：

1. 被**推翻/反转/废弃/实验冻结后弃用**（VHI 冻结、71TB 全量物化旧路线、被 07-06 设计取代的早期 LOD 稿、被更晚整合稿取代的中间稿…）→ **90-obsolete**。
2. 否则是**长稳参考**（工程指南、`线协议规范`、术语表、跨仓契约、v2.0.1 冻结架构规范、仍权威的架构概览/指导思想）→ **30-reference**。
3. 否则用途是陈述**"此刻为真/当前状态"**（即现 `current_status/` 树）→ **00-current-truth**。
4. 否则描述的工作**已收口/完成**（阶段记录有 closure/进度日志已收）→ **20-archive/<子系统>**。
5. 否则（进行中/下一步/让路待恢复）→ **10-active/<子系统>**。

判定依据：文档标题、frontmatter/状态标记、进度日志尾部、"被取代的旧结论"小节、`冻结/证伪/反转/收官/结项/搁置/defer/已完成` 关键词、日期新旧、以及是否被更晚文档显式取代。

## 6. 子系统分组（10-active / 20-archive / 90-obsolete 内）

`voxel-authority`（权威化 phase1-4/align/A/prefab/object/hot-path）· `voxel-far-field`（VLOD/SVO/VHI/worldgen/baseline/streaming/LOD 设计/projection/tile-budget）· `field-emergence`（phase5-8/场 runtime/化学/结构/光/正交/sigma-R/形态）· `movement-sync`（移动同步全系）· `client`（voxia/bevy/web/prefab-microgrid/touch）· `combat-npc`（技能战斗/NPC/多技能 demo/施法）· `infra`（部署/CI/框架解耦/phoenix/rustler 升级/CLI 可观测）。

`30-reference` 可选子分组：`protocol/`（线协议）、`engineering/`（工程指南、phoenix、部署手册）、`contracts/`、`overview/`（架构概览/冻结规范/指导思想）。

## 7. 状态盖戳与 frontmatter 规范

**90-obsolete 每篇（必做）**：
```yaml
---
status: obsolete
subsystem: <子系统>
superseded_by: <现行文档 docs-相对路径>
obsoleted_on: 2026-07-08
---
```
正文首行加醒目横幅：
> ⚠️ **本文已失效** — <一句：为什么 + 被谁取代>。仅存历史 provenance，**勿作现行依据**。现行事实见 `00-current-truth/...`（对应现行文档）。

**其余每篇（机械批量，委派）**：加轻量 frontmatter
```yaml
---
status: current-truth | active | archived | reference
subsystem: <子系统 或 空>
last_reviewed: 2026-07-08
---
```

## 8. drift 修复（"清理所有 drift"的实质）

借重构把 `00-current-truth` 校准到最新事实：
- **已核实必修**：`current_status/design/client/streaming-lod.md` §17–18 仍写"overdraw=device-removal / A3–A5 未开工 / FPS 不可达" → 用 A3.0 反转事实重写（真凶=raymarch×proxy-mesh GPU 跨队列竞态、修复=raymarch 默认关、A3b 已完成 −57.3% 且 0 device-removal、远景改 Lit、A4 进行中）。
- **系统扫描**：逐篇比对 `00-current-truth` 各文档 vs `10-active`/`20-archive` 最新记录；吃重矛盾就地改，其余记入 `00-current-truth/drift-log.md`（含 field/emergence 时间戳漂移、Phase 8 字面模型 vs 正交系统落地、客户端主线口径两次未留痕反转）。

## 9. 交叉引用与外部引用重写

产出 **move-map（旧→新 全量映射）** 后：
- 重写全 `docs/` 内 `.md` 相对交叉链接（含锚点保持）；
- 更新 **`CLAUDE.md`（索引表）/ `AGENTS.md` / 根 `README.md`** 中所有指向被移动文档的路径；
- 注意顶层 `Genesis/CLAUDE.md` 也引用了 ex_mmo_cluster 文档路径（如 `docs/2026-04-19-标签语义施法系统基础设计.md`、`docs/2026-05-07-体素服务器权威化架构进度检查.md`）——一并核对（该文件在父仓，改动需谨慎，若涉及则单列告知用户）。

## 10. 执行编排（双 Gate）

- **Gate ①**（已过）：用户确认本设计。
- **分类 pass**（委派）：9 个只读 agent 分批通读全部 180 项，产出 move-map JSON（旧路径→桶/子系统/新路径/status/superseded_by/置信度/一句理由/drift_note）；主会话汇合、去重、解冲突、抽查。
- **Gate ②**：move-map 汇总（各桶计数 + 90-obsolete 全清单 + 低置信/存疑项）交用户二次确认，再动第一个文件。
- **执行**：建骨架 → `git mv` → 盖戳/frontmatter → 重写链接 → 写各 README + `docs/README.md` → 修 drift → 更新 CLAUDE/AGENTS/README。机械大户（frontmatter 批量、链接重写）委派 codex/agent 并行。
- **验证**：见 §11。

## 11. 测试矩阵（完成判据）

| 项 | 判据 |
|---|---|
| 结构 | `docs/` 顶层只剩 `README.md` + 5 个 `NN-*` 文件夹；每个文件夹有 `README.md` |
| 无遗漏 | 180 项全部有归宿；`git status` 中所有旧文件均为 rename（R），无意外 delete/新增内容丢失 |
| 历史保留 | `git log --follow` 对抽样文件可追溯到重构前 |
| 链接完整 | 全 `docs/` 内 `.md` 相对链接逐一解析目标存在（链接校验脚本 0 断链）；CLAUDE/AGENTS/README 引用可达 |
| 失效隔离 | `90-obsolete` 每篇有 frontmatter + 横幅 + `superseded_by` 指向可达现行文档 |
| 当前事实 | `00-current-truth` 无残留已被证伪的旧口径（streaming-lod device-removal drift 已修）；`drift-log.md` 存在 |
| README 覆盖 | 6 个 README（顶层 + 5 文件夹）均含中文用途 + 收录标准 + 内容索引 |

## 12. 进度日志

- 2026-07-08：Gate ① 通过（用户拍板 D1–D4）。落决策稿。启动分类 pass（9 agent）。
- 2026-07-08：分类 pass 完成（180 项，0 遗漏；期间遇 API 529 过载，经 Workflow resume + 每波 3 个重试收口）。Gate ② 通过（用户确认 #7/#8 obsolete、06-29 两篇 reference）。
- 2026-07-08：**执行完成**。`git mv` 180 项（历史保留，0 删除）；`docs/` 顶层只剩 5 个 `NN-*` 层 + `README.md`。括号文件名 `当前真相(整合)` 重命名去括号；旧 `voxel-server-authority/README.md` 重命名为 `voxel-server-authority-phase-overview.md`（消除 subsystem 内 README 歧义）。
- 2026-07-08：链接重写 + 修历史坏链，链接校验 **588 链接 / 0 坏链**（含 Voxia、TheWorldBook 跨仓链接深度修正）。9 篇 obsolete 盖失效戳（frontmatter + 横幅 + superseded_by）。6 个 README 生成（顶层地图 + 5 层）。
- 2026-07-08：drift 修复——`00-current-truth` 的 streaming-lod / known_gaps（device-removal 归因反转、A1-A3b 已收口、A4 收尾）、source_index（补 VLOD-A 条目 + 反转结论）、client_active_region（skirt 验证矛盾）、phase-overview（VLOD-A4 行）、_session-handoff（07-06 滞后提示）均校准到最新事实。`CLAUDE.md` / `AGENTS.md` / 根 `README.md` 引用与决策稿规则同步更新。
- 2026-07-08：**测试矩阵全绿**（结构 / 无遗漏 / 历史保留 / 链接完整 / 失效隔离 / 当前事实 / README 覆盖）。默认未 commit / push。
