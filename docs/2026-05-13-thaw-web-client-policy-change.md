# 2026-05-13 解冻 web_client 策略变更（ex_mmo_cluster 单页摘要）

- **日期**：2026-05-13
- **状态**：已生效
- **来源**：goal `voxel-authoritative-and-field-minimum` 推进中，Phase 1 客户端验收口径需要重新确定
- **完整决策记录**：`../../TheWorldBook/docs/2026-05-13-解冻-web_client-决策.md`（跨仓决策入口，单一真相源）

## 撤销内容

撤销 2026-04-26 起在本仓 `CLAUDE.md` 末尾「客户端策略（2026-04-26 后冻结）」段落中固化的以下纪律：

- `clients/web_client` 冻结，不再新增改动；
- 所有新功能 / bug fix / 重构只动 `clients/bevy_client`；
- 不再为 `web_client` 做协议同步、parity 测试或字节序对齐；
- audit / sweep / 设计文档凡涉及"双端同步"统一缩到只 bevy 一端。

## 新纪律

- 体素权威化主线（**Phase 1 / 2 / 3 / 5**）客户端 decoder / parity 验收口径以 `clients/web_client` 为准；
- `clients/bevy_client` 保留为参考实现，**不作为主线 parity 测试目标**，可滞后跟进或暂缓；
- 协议层只追加字段、不破坏 wire layout 的纪律仍然适用；**双端 parity 不再强制**——但新协议字段需先在 `web_client` decoder 上落地并通过 parity / 字节序验收；
- 任何 audit / sweep / 设计文档若需要"客户端端到端验证"，默认指向 `web_client`；引用 `bevy_client` 行为时需在文档中显式标注其参考性质。

## 影响 Phase

- **Phase 1**（体素权威化最小目标）：客户端 decoder 验收口径直接受影响，以 `web_client` 为准。
- **Phase 2 / 3 / 5**：后续主线 Phase 沿用同一口径；`bevy_client` 不阻塞这些 Phase 的 parity 验收。
- 历史 Phase（含 `docs/2026-04-26-bevy-client-audit-*.md` 等历史决策文档）按其当时口径归档，不回溯改写。

## 风险与待 audit 项

- **协议漂移窗口**：2026-04-26 至 2026-05-13 约 17 天内，服务端协议层若新增字段或调整 codec，`web_client` decoder 未必同步演进，可能存在解码缺失或字节序错位。恢复主线前需对 `clients/web_client` 与 `GateServer.Codec` / `docs/2026-04-10-线协议规范.md` 做一次对照 audit，列出需要补齐的字段。
- **测试基线**：`web_client` 端的 parity 测试 / smoke 用例在冻结期间可能停滞，恢复主线前应重新确认其本地运行口径与 CI 接入状态。
- **bevy_client 参考性质的明确化**：现有引用 `bevy_client` 行为的文档（包括 `apps/scene_server/lib/scene_server/voxel/README.md`、`docs/2026-05-07-体素服务器权威化架构进度检查.md`）仍保留为描述性 / 代码证据用途，本次不回写；后续主线 audit 触及时再按需补注"参考实现"标记。

## 不在本次范围

- 不改任何客户端代码（`clients/web_client/`、`clients/bevy_client/`）；
- 不动历史决策文档（`docs/2026-04-26-bevy-client-audit-*.md`）；
- 不动 `apps/scene_server/lib/scene_server/voxel/README.md`、`docs/2026-05-07-体素服务器权威化架构进度检查.md`、`docs/2026-04-10-线协议规范.md`。

本次提交只动 `CLAUDE.md` 末尾段落与本单页摘要。
