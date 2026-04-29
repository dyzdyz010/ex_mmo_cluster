# 体素世界收拢为服务端权威研究 (2026-04-29)

## 1. 结论

体素世界不能直接把当前浏览器 `WorldStore` 的本地写入“同步出去”。正确目标是：

```text
WorldServer owns chunk truth.
GateServer only routes voxel wire messages.
Client owns preview, pending overlay, rendering, CLI diagnostics.
SceneServer consumes voxel truth for collision and gameplay when needed.
```

推荐把落地命名空间放在现有 `apps/world_server` 里，而不是新建一个平行
`voxel_server` app。早期 `docs/2026-04-20-体素世界服务端规划.md` 规划了
`VoxelServer.*`，但当前仓库实际已经有 `world_server` 的 supervision 和服务发现入口；
继续新增 app 会增加路由、部署和文档分叉。可采用 `WorldServer.Voxel.*` 子命名空间，未来
如果体素负载独立扩容，再从该边界拆出 app。

## 2. 当前事实

### 2.1 客户端现状

- `clients/web_client` 明确处于 `voxel_sync=offline-local`。
- `LocalVoxelWorldAdapter` 在浏览器内直接持有 `WorldStore`，`WorldEditController`
  通过 `placeBlock / breakBlock / placePrefabBoundarySnap` 直接改本地 truth。
- `WorldStore -> ChunkStorage` 已有多 chunk、normal block、refined cell、prefab instance、
  snapshot import/export 和 edit stats。
- 当前浏览器端量化是 `MicroPerMacro=8`，即单 macro 内 `8x8x8 = 512` micro slots。
- `clients/web_client/src/infrastructure/net/opcodes.ts` 已保留 `0x60..0x69` voxel opcode，
  但真实 `ChunkSubscribe / ChunkSnapshot / ChunkDelta / EditAck` 还没有连到服务端。

### 2.2 服务端现状

- `GateServer.Codec` 当前只实际处理 movement/chat/combat 等消息族；voxel opcode 尚未编码/分发。
- `AuthServerWeb.GameWebSocket -> GateServer.WsConnection` 已经证明浏览器二进制 WebSocket
  可以稳定跑 movement，因此 voxel 可复用这条入口。
- `apps/world_server` 目前基本是空壳：`Interface` 注册服务并等待 `scene_server` /
  `data_service`，`WorldSup` 没有 chunk worker，`WorldServer.World` 只保留空状态。
- `data_service` 目前没有 `voxel_chunks / voxel_prefabs / voxel_edit_log` 等 schema。

### 2.3 文档冲突

早期服务端规划写的是 `MicroPerMacro=4` 和 `u64 micro_solid_bitmap`。当前 web / bevy 客户端
已经走到 `MicroPerMacro=8`，`u64` 只能表达 64 slots，不能表达 512 slots。继续沿用旧线格式会
静默截断 refined prefab。

本轮建议把 v1 服务端权威量化定为 `MicroPerMacro=8`，并在协议中显式携带：

- `schema_version`
- `micro_resolution`
- `chunk_size_in_macro`

不要让任何一端靠旧文档猜测量化参数。

## 3. 必须先固定的原则

1. **服务端是唯一权威写入者**：客户端可以 preview / optimistic overlay，但 `WorldStore`
   的确认态必须来自 `ChunkSnapshot / ChunkDelta / EditAck`。
2. **chunk 是几何 truth 边界**：宏格、refined occupancy、material/state/provenance 都从
   chunk truth 派生；render/collision 不拥有真相。
3. **建造合法性由几何决定**：v1 仍用 `overlapSlots === 0`，可选 `contactSlots > 0`；
   tag 只用于放置后的玩法语义。
4. **prefab raster 不能信客户端**：客户端可提交 intent，服务端必须用服务端 registry 和相同
   rasterizer 重算 incoming occupancy。
5. **冲突拒绝优先于合并**：`base_hash/base_version` 不匹配时拒绝并返回 authoritative cell；
   不在 v1 引入 CRDT/OT。
6. **跨 chunk 操作事务化**：大 prefab 触达多个 chunk 时，任意 chunk validate 失败则整次拒绝，
   不能留下半个 prefab。

## 4. 建议架构

```text
Browser / Bevy client
  -> GateServer.WsConnection / TcpConnection
  -> WorldServer.Voxel.Interface
  -> WorldServer.Voxel.ChunkProcess(coord)
  -> DataService.Repo persistence

SceneServer
  -> WorldServer.Voxel query / subscription
```

### 4.1 WorldServer.Voxel.ChunkProcess

一个 chunk 一个权威进程，key 为 `{:voxel_chunk, {cx, cy, cz}}`。

状态建议：

```elixir
%WorldServer.Voxel.ChunkProcess.State{
  coord: {cx, cy, cz},
  storage: %WorldServer.Voxel.Storage{},
  version: non_neg_integer(),
  cell_versions: %{macro_index => non_neg_integer()},
  subscribers: %{client_ref => subscription_meta},
  dirty_since_ms: integer | nil,
  pending_journal: :queue.queue()
}
```

职责：

- 惰性加载 / 初始化 chunk。
- 对 `BlockBreak / BlockPlace / PrefabPlace` 做 validate + commit。
- 生成 `ChunkSnapshot / ChunkDelta / EditAck`。
- 聚合写入 `voxel_chunks` 和 `voxel_edit_log`。
- 维护订阅者，不直接知道 WebSocket 或 TCP。

### 4.2 GateServer 的职责

`GateServer` 只做连接态、鉴权态和 opcode 路由：

- 已认证且已进入场景的连接才允许 voxel edit。
- `0x60..0x69` 解码后转发给 `WorldServer.Voxel.Interface`。
- 下行只把 world_server 返回的 voxel payload 发回当前连接或订阅者。
- 不在 `WsConnection` 内保存 chunk truth。

### 4.3 Client 的职责

新增 `ServerVoxelWorldAdapter`，与现有 `LocalVoxelWorldAdapter` 并列：

- 订阅玩家附近 chunk。
- 收到 `ChunkSnapshot` 后建立确认态 `WorldStore`。
- 本地交互先产生命令和 pending overlay。
- 收到 `EditAck(applied)` 后应用 server delta 并清 pending。
- 收到 `EditAck(conflict/rejected)` 后丢弃 pending，用 authoritative cell 覆盖。

HUD / CLI 必须能读到：

- `voxel_sync=server-authoritative | offline-local`
- 订阅 chunk 数量
- pending edit 数量
- last edit ack / conflict reason
- chunk snapshot/delta 收发计数

## 5. 线格式关键点

### 5.1 endian 不要混用到同一个 codec

movement 的 `GateServer.Codec` 目前使用 big-endian；`opcodes.ts` 注释写 voxel 多字节字段统一
little-endian。两者可以共存，但必须拆成明确模块：

```text
GateServer.Codec          movement/chat/combat big-endian
GateServer.Codec.Voxel    voxel opcode dispatch only
WorldServer.Voxel.Codec   voxel payload little-endian
```

每个 voxel 消息都要有 TypeScript 和 Elixir 的 golden binary fixture，避免靠注释同步。

### 5.2 512-slot refined payload

`MicroPerMacro=8` 后，occupancy mask 是 512 bits。推荐线格式不要用单个整数字段，而用固定
8 个 `u64 little-endian` 或固定 64 bytes：

```text
micro_occupancy_words[8] u64-le
micro_material_ids[512] u16-le or compressed layer
micro_state_flags[512]  u16-le or compressed layer
micro_part_ids[512]     i32-le or compressed layer
```

v1 可以先用未压缩数组换可调试性；压缩层作为性能优化，不作为协议起点。

### 5.3 Normal block 字节数要重新定版

旧规划写 `FNormalBlockData = 10 bytes`，当前 web 类型注释写紧凑线格式是
`u16 + i32 + u16 + i16 + i16 = 12 bytes`。服务端实现前必须选定一个 canonical wire layout，
并把 web / bevy / Elixir 测试都锁到同一组 fixture。

## 6. 推荐分阶段

### S0：定协议和 golden fixtures

交付：

- `WorldServer.Voxel.Storage` 数据结构。
- `WorldServer.Voxel.Codec`。
- `clients/web_client` voxel codec。
- 共享 fixture：empty chunk、solid cell、refined 512-slot cell、prefab raster cell。

验收：

- Elixir codec round-trip。
- TypeScript codec round-trip。
- 两端对同一 fixture 的 hash 一致。

### S1：只读服务端 chunk authority

先不做编辑，只让服务端发 chunk truth：

- `ChunkSubscribe`
- `ChunkUnsubscribe`
- `ChunkSnapshot`
- `ChunkInvalidate`

客户端新增 `ServerVoxelWorldAdapter` read-only 模式，把本地 showcase world 替换成服务端 snapshot。

验收：

- 两个浏览器订阅同一 chunk，收到相同 snapshot hash。
- `window.__voxelCli.run("voxel_transport")` 能看到 subscribed chunks 和 snapshot counters。
- `voxel_sync=server-readonly`。

### S2：宏格 block edit authority

先做 normal block，不碰 prefab/refined：

- `BlockPlace`
- `BlockBreak`
- `EditAck`
- `ChunkDelta`

客户端可 optimistic preview，但确认态必须等 ack。

验收：

- A 放置方块，B 收到 `ChunkDelta`。
- A/B 同时改同一 macro，只有一个 `applied`，另一个 `conflict` 并收到 authoritative cell。
- 服务端重启后 chunk 从 DB 恢复。

### S3：refined 和 prefab authority

把当前 browser/bevy 的 prefab rasterizer 迁移/复写到服务端：

- 服务端内置 `builtin_sphere / builtin_cylinder / builtin_stairs`。
- `PrefabPlace` intent 只带 `prefab_id / anchor_micro_coord / rotation / base_hash / seq`。
- 服务端重算 raster cells，跨 chunk validate，再统一 commit。

验收：

- stairs-on-stairs 细粒度 snap 由客户端 preview，服务端用同一 anchor 重算后 ack。
- 任意 occupied micro overlap 被拒绝。
- 跨 chunk prefab 不会部分落地。

### S4：object/assembly provenance

引入 `microOwnerObjectIds` 或压缩 owner layer：

- `ObjectInstance`
- `AssemblyInstance`
- `ObjectStateDelta`
- `object_at <world-micro>` CLI

这个阶段才适合做门、窗、局部破坏、火焰传播等玩法语义。

### S5：SceneServer 集成

movement / combat 需要使用体素碰撞时，再让 `SceneServer` 消费 world truth：

- chunk collision snapshot cache
- ground / obstacle query
- destruction event 到 AOI

不要在 S1/S2 把 movement 卡死在 voxel collision 上，否则会把当前已稳定的 movement sync 再次拖入大重构。

## 7. 风险与规避

| 风险 | 影响 | 规避 |
| --- | --- | --- |
| `MicroPerMacro=4/8` 不一致 | refined payload 静默损坏 | v1 固定 8，并在 handshake/snapshot 明示 |
| 信任客户端 prefab raster | 作弊和跨端漂移 | 服务端重算 raster，客户端只提交 intent |
| 大 snapshot 堵塞 WS | 加载卡顿 | S1 先做小 AOI + counters；后续分片/压缩 |
| 跨 chunk 半提交 | 世界破洞或重复实例 | coord 排序 validate，全成功后 commit |
| 本地 optimistic 与权威状态双真值 | 卡顿/拉回/幽灵块 | pending overlay 与 confirmed WorldStore 分层 |
| 直接把 tag 用作建造规则 | 用户组合 prefab 受限 | 几何决定合法性，tag 只做玩法 |
| world_server 空壳直接堆逻辑 | 未来不可维护 | `WorldServer.Voxel.Storage/Codec/ChunkProcess/Interface` 分层 |

## 8. 最小实现切入点

下一步最小可执行任务建议是 S0+S1 的一条薄链路：

1. 在 `apps/world_server/lib/world_server/voxel/` 下建立 Storage + Codec + ChunkProcess。
2. 在 `apps/world_server/sup/world_sup.ex` 挂 `DynamicSupervisor`。
3. 在 `GateServer.Codec` 或独立 `GateServer.Codec.Voxel` 增加 `ChunkSubscribe` 解码和
   `ChunkSnapshot` 编码。
4. 在 `GateServer.WsConnection` 只对已 `:in_scene` 的连接转发 voxel subscribe。
5. 在 web client 新增 `VoxelTransport` 和 `ServerVoxelWorldAdapter` read-only 模式。
6. 增加双浏览器 smoke：A/B 订阅同一 chunk，hash 一致，CLI 能导出 snapshot。

这条链路不改变编辑语义，不碰 prefab，不碰碰撞，风险最小；但它会把“谁拥有体素 truth”从
浏览器切到服务端，是后续所有权威编辑的必要地基。

## 9. 当前研究判断

可以收拢，而且应当收拢。但不要从 prefab/place 的复杂路径开始。先做只读服务端 chunk truth，
再做宏格 edit ack，最后才迁移 refined prefab 和 object provenance。否则会同时面对：

- 量化参数冲突
- 512-bit refined wire format
- 跨 chunk transaction
- prefab registry trust boundary
- pending overlay rollback
- SceneServer collision integration

把这些一次性压到首个实现切面，会让问题不可验证。S0/S1 是最稳的起点。
