# 体素 Tile 预算与运行期 Diff 决策记录

日期：2026-06-28

## 结论

后续讨论体素 streaming、near window、LOD、diff 数据量时统一使用以下口径：

| 单位 | 定义 |
| --- | --- |
| chunk | `16x16x16` macro cells，边长 `16m` |
| tile | `7x7x7` chunks，边长 `112m`，共 `343 chunks` |
| 生产近场预算窗口 | `27 tiles = 3x3x3 tiles = 9,261 chunks` |
| 跨 tile 边界新增 | 旧窗口保留时新增一片 `3x3 = 9 tiles` |
| 穿过一个 tile 时间 | 按 `6m/s` 约 `18.67s` |

运行期目标不是从零同步全窗口体素数据。进入场景前，启动器和入场流程必须已经完成
`world pack / region manifest / chunk baseline / diff chain` 校验。进入场景后只流送已验证
基线之上的 `runtime diff`、`semantic diff`、`prefab/object/event diff`。

## 工程约束

- 缺包、hash 不匹配、diff chain 断裂表示客户端数据不可被信任，必须拒绝进入场景。
- 禁止用运行时 `ChunkSnapshot`、resync、自愈逻辑或静默 fallback 绕过基线校验。
- snapshot 只能是已验证基线上的权威同步消息之一，不能当 baseline 兜底。
- “同步数据量可能很大”不再作为当前可操作区域不刷新、编辑无效或 LOD 不跟随的默认解释。
- 数据量问题后期实际碰到吞吐瓶颈再处理。处理前必须先用 observe/CLI 量化：
  `tiles_changed`、`chunks_changed`、`ops`、`bytes`、`encode_ms`、`send_queue_bytes`。

## 后续含义

当前排查优先级应放在订阅窗口跟随、权威 routing、projection materialization、diff/dirty 调度和
客户端 confirmed store/LOD 表现衔接上。只有当上述链路有证据显示吞吐成为瓶颈时，才进入压缩、
分片、多 channel 或预算策略设计。
