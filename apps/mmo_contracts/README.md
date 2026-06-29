# mmo_contracts

Hemifuture 体素 MMO 服务端**承重契约的单一来源**(纯库,无监督树)。

承载冻结架构规范(`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`,含 v2.0.2 反哺修订)中
跨 app 共享的**信封与分类**,使 gate / world / scene / data 各层引用同一份定义。

迁移主线见 `docs/voxel-server-authority/2026-06-14-architecture-triage-and-alignment.md`;
本 app 由其**梯队 0 · 契约骨架前置**引入(`docs/voxel-server-authority/phase-align-0-contract-skeleton.md`)。

## 模块

| 模块 | 职责 | 规范 |
|------|------|------|
| `MmoContracts.StateClass` | PERS-5 状态四分类(durable_authoritative / runtime_authoritative / derived / ephemeral)单一来源与校验 | PERS-5/6/8、AUTH-2/15 |
| `MmoContracts.Envelope.*` | FROZEN-5 信封 typed struct 骨架(命令/系统命令/事件/时间/复制/持久化分类 + subtype) | FROZEN-5、AUTH-1/3/11、EVENT-2、TIME-* |
| `MmoContracts.CellId` | cell_id `(level, morton)` 与 v2.0.2 `region_id` 聚合等价 | CELL-2/3 [v2.0.2] |
| `MmoContracts.StateRegistry` | 状态持有者分类登记与"未分类禁入生产"完备性校验 | PERS-5 |
| `MmoContracts.WorldPackIndex` | 32km full-authority baseline pack/index 覆盖校验、payload shard grid / 线性全 shard 摘要 / 单 shard 计划与 radius 滑动窗口数学 | AUTH-2、PERS-5、VOXEL baseline gate |
| `MmoContracts.WorldPackShard` | `.vxpack` payload shard footer-table 编码、按 local coord 读取、footer entry 覆盖摘要 | AUTH-2、VOXEL baseline payload |

## 纪律

- **只放契约**(类型、struct、校验、版本字段),不放运行时行为,不依赖任何 sibling app。
- 信封演进遵循 FROZEN-2/4:envelope 与兼容规则冻结,payload 走版本化;字段**只追加不破坏**。

## 测试

```
mix test apps/mmo_contracts/test
```

纯库,无需 Postgres。
