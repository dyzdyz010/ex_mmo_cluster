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
| `MmoContracts.VoxelSpatialContract` | 完整 XYZ tile/near window 与 full32km pack 边界的共享纯空间契约 | AUTH-2、VOXEL baseline gate |
| `MmoContracts.WorldPackIndex` | 32km full-authority baseline pack/index 覆盖校验、payload shard grid / 线性全 shard 摘要 / 单 shard 计划与 radius 滑动窗口数学 | AUTH-2、PERS-5、VOXEL baseline gate |
| `MmoContracts.WorldPackShard` | `.vxpack` payload shard footer-table 编码、按 local coord 读取、footer entry 覆盖摘要 | AUTH-2、VOXEL baseline payload |

## 纪律

- **只放契约**(类型、struct、校验、版本字段),不放运行时行为,不依赖任何 sibling app。
- 现行 Session/Voxel 的纯字节编解码也在此库；Reducer、World、鉴权与会话状态仍由业务 app 持有。
- 信封演进遵循 FROZEN-2/4:envelope 与兼容规则冻结,payload 走版本化;字段**只追加不破坏**。

## 测试

```
mix test apps/mmo_contracts/test
```

纯库,无需 Postgres。

## Voxim M1 G1：现行 wire owner

当前客户端主线为同级 `Voxim`；`clients/Voxia` 是算法和历史行为参考。实施边界见
[`2026-09-08-voxim-m1.md`](../../docs/10-active/movement-sync/2026-09-08-voxim-m1.md) 与
[`G1 brief`](../../../Voxim/Docs/M1/briefs/G1.md)。此次依据原生产 serializers 和 G0 的 31 个冻结向量做机械抽取，
没有设计新字节布局。纯编解码不依赖 sibling app；直接使用的 OTP `:crypto` 已声明，无监督树。

公共接口保留原 arity、tuple/map 形状与返回类型：

- `MmoContracts.Session`：当前 request/reply 类型；`Session.Codec.decode/1` 返回 `{:ok, tuple}` 或原错误，
  `encode/1` 返回 `{:ok, iodata}` 或原错误。只承接 auth/enter/heartbeat 与 result，旧 Enter Position 仍是 **UE/cm**。
- `MmoContracts.Voxel`：coord/skins/coarse/entry/transaction 类型；`Voxel.Codec.decode/1`、`encode/1`
  承接 `0x70/0x76/0x78` 上行和 `0x68/0x77/0x79` 下行（及原有单编辑编码）。帧字段保持大端，日志内容原样透传。
- `Voxel.Codec.encode_request/2`、`decode_request/1`、`encode_reply/2`、`decode_reply/1`：VXRQ/VXRS，小端；
  编码返回 iodata，解码返回 `{:ok, content_version, items}` 或原错误。
- `Voxel.Codec.payload_header_bytes/0`、`encode_payload/5`、`decode_payload_header/1`、`decode_payload_body/1`、
  `stamp_payload_seq/2`、`body_hash/1`：VXR4 头、zlib 和原 MD5 内容 hash；未改变 body、压缩或 content_version。
- `Voxel.Codec.encode_entry/1`、`decode_entry/1`、`encode_transaction/1`、`decode_transaction/1`、
  `encode_coarse/1`、`decode_coarse/1`：现行小端日志、事务与六面粗格表皮。
- `Voxel.Payload`：从旧 `VoxelRegion.Payload` 原样迁入的不可变 struct；保留 `extent/0`、`origin/1`、
  `cell_index/1`、`local/2`、`in_span?/1`、`decode/1`、`decode_body/1`、`material/2`、`skins/3`、`value/2`、
  `encode/4`。CSR 编解码、材质覆盖派生与贴图池去重只在此实现；业务 World 直接消费此值。
- `Voxel.Skins.uniform/1`、`canonical/1`、`trivial?/2`：原 Reducer 的纯值表示规则；Reducer 仍独占 LOD reduction。
- 两个 codec 的 `is_opcode/1`、`is_message/1` 是路由 guard；常量跟随字节 owner，Gate 无重复 opcode 表。
  `Voxel.Fields` 保留旧字段边界检查 `u8!/2`、`u16!/2`、`u32!/2`、`u64!/2`、`world_micro!/1`、`face_normal!/1`，
  当前编辑和旧 surface-element 编码共用，避免重复同一字段规则。

Gate 的既有 `Session.Dispatch.decode/1` 与 `Session.Sink.encode/1` 只按 guard 选择上述 owner，
其他消息交给仍有活调用方的 `GateServer.Codec`；TCP/WS 共用，旧 UDP fast-lane 保持原路径。
旧 Gate codec 保留 movement/time-sync/fast-lane、玩家/NPC、聊天/战斗、Scene chunk/object/field/prefab 等协议，
不保留当前 Session/Voxel 字节逻辑或 delegate。旧 `VoxelRegion.Codec`/`Payload` 已无调用方并删除。
新 Movement、固定 60 Hz 权威联调、QUIC 集成、bootstrap runtime 均待后续阶段实施；不要求兼容旧移动协议。

G0 普通测试直接调用新 owner，期望仍为同级 Voxim 的原 31 个二进制文件；不再 require sibling 源码。
历史 manifest 中的旧源路径/hash 只是捕获来源，不是现行所有权或测试前置条件。历史捕获由 Voxim 工具从固定 Git
版本读原 serializers，写临时 corpus；不再用现行 owner 冒充抽取前来源。Windows scoped 验证：
`mix test --no-start`（本 app）；跨 app 回归见 Voxim `Docs/M1/reports/G1.md`。
