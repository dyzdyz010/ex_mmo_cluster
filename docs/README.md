# 文档地图（docs/）

本目录按**功能**分五层。每层一个文件夹、各有 README 说明用途与收录标准。**找"此刻为真"看 `00-current-truth/`；动手前的决策稿放 `10-active/`。**

> 结构由 2026-07-08 文档大重构确立，决策稿见 [`10-active/infra/2026-07-08-docs-restructure-design.md`](10-active/infra/2026-07-08-docs-restructure-design.md)。

## 五层一览

| 层 | 用途 | 何时看 / 何时往里放 | 数量 |
| --- | --- | --- | --- |
| [`00-current-truth/`](00-current-truth/README.md) | **当前事实·唯一权威**（此刻为真的状态） | 想知道"现在到底是什么样"——只信这里 | 11 |
| [`10-active/`](10-active/README.md) | **活跃工作**（在执行 / 下一步 / 让路待恢复 的决策稿与阶段计划） | 要动手做某主线前先读；新决策稿落这里 | 24 |
| [`20-archive/`](20-archive/README.md) | **已完成·有效历史**（已收口的阶段记录 / 决策 / 诊断） | 追溯"某功能当初怎么做的、为什么" | 111 |
| [`30-reference/`](30-reference/README.md) | **长稳参考**（工程指南 / 线协议 / 术语 / 契约 / 架构概览） | 查规范、契约、协议真值 | 27 |
| [`90-obsolete/`](90-obsolete/README.md) | **已失效**（被推翻 / 废弃，仅存 provenance） | ⚠️ 不要作为现行依据；每篇顶部有失效横幅指向现行 | 13 |

## 分层决策树（一篇文档属于哪层）

按顺序命中第一条：

1. 被**推翻 / 反转 / 废弃 / 实验冻结后弃用** → `90-obsolete/`（盖失效戳 + superseded_by）
2. 否则是**长稳参考**（工程指南 / 线协议 / 术语表 / 契约 / 冻结架构规范 / 仍权威的架构概览） → `30-reference/`
3. 否则用途是陈述**"此刻为真 / 当前状态"** → `00-current-truth/`
4. 否则工作**已收口 / 完成**（有 closure / 进度日志已收） → `20-archive/<子系统>/`
5. 否则（进行中 / 下一步 / 让路待恢复） → `10-active/<子系统>/`

## 子系统（10 / 20 / 90 层内的二级目录）

`voxel-authority`（权威化 phase / prefab / object）· `voxel-far-field`（VLOD / SVO / worldgen / streaming / LOD）· `field-emergence`（局部场 / 化学 / 结构 / 光 / 正交）· `movement-sync`（移动同步）· `client`（voxia / bevy / web）· `combat-npc` · `infra`（部署 / CI / 框架 / 升级）· `cross-cutting`（跨子系统）

## 状态标记（文档 frontmatter）

`status: current-truth | active | archived | reference | obsolete`。**失效文档**额外带 `superseded_by` 与顶部醒目横幅。

## 维护约定

- 阶段 / 架构改动**先在 `10-active/<子系统>/` 落决策稿**，再动手；收口后移入 `20-archive/<子系统>/`。
- 某文档被取代时，移入 `90-obsolete/` 并盖失效戳（frontmatter + 横幅指向现行）。
- `00-current-truth/` 是唯一"当前为真"来源，代码 / 结论变化必须回写，避免 drift。
