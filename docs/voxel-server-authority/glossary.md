# 体素数据链路术语表(base / delta / truth / snapshot)

> 日期:2026-07-06 状态:拍板口径(用户定稿)
> 定位:统一体素数据链路的四层名词,消除"客户端该持有什么数据"类讨论中的口径漂移。本表只管**数据链路分层口径**;实施机制词汇(H、H gate、canonical、checkpoint、golden fixture、content_version 等)仍以 [`2026-06-30-voxel-generation-streaming-client-plan.md`](./2026-06-30-voxel-generation-streaming-client-plan.md) 的名词解释表为准。
> 两表冲突时以本表为准:6-30 表个别词条(如 D"可参与本地 baseline 重算")带有客户端本地推导时代的假设,该路径已被 S4 仲裁挂起,重启五条件见 [`2026-07-06-gpt55-lod23-proposal-review.md`](./2026-07-06-gpt55-lod23-proposal-review.md) §2。

## 1. 四个核心词

| 词 | 定义 | 存在位置 | 生产渲染消费者 |
| --- | --- | --- | --- |
| **base** | WorldGen 确定性函数(`seed + control_maps + coord`)直出的程序化世界。真值的生成**原料之一,不是真值**——单独渲染 base 得到的是一个缺了全部 D 内容(洞穴/水体/天空岛/巨构)的不存在的世界。 | 算法本体:服务端 NIF(权威唯一实现);客户端 C++ 副本已故意 3D 分叉,仅限 `-VoxiaWorldGenPreview` 开发预览 | **无**(S4:客户端 base 禁止驱动生产渲染) |
| **delta** | 单次**已提交**体素变化事件(committed voxel event)。D=设计师 delta(开服前冻结),P=玩家 delta(运行时)。客户端 intent 在服务端裁决落库前**不是** delta。 | 服务端 canonical(event log + checkpoint),**全世界永久全存**;wire `0x63` 是它对近窗的投递形式 | 近窗 confirmed store(窗内增量维护) |
| **overlay(压扁修改层)** | 全部 delta 按提交序合并压扁后的**净效果**(compacted delta):从 base 到 truth 的最小差集,只覆盖被修改体素;未修改区在 overlay 中**不存在条目**。 | 服务端存储配方(6-29 baseline=delta 决策;canonical store 瘦身后的形态即 `truth = base ⊕ overlay` 懒物化)。**wire 上不传输 overlay**——下发的一律是投影 | 服务端物化器(生产 snapshot/page 时消费);客户端无此概念 |
| **truth(真值)** | `base ⊕ 全部 delta`(等价 `base ⊕ overlay`)的世界当前确认态。逻辑实体,只在服务端完整存在。 | 服务端(canonical + runtime hot truth) | 无直接消费者——客户端拿到的一切都是它的投影 |
| **snapshot** | truth 在(范围 × 分辨率 × revision)上的**合并后物化投影**:`snapshot = project(base ⊕ delta, resolution)`。**合并永远发生在服务端**;分辨率是参数,不同距离带用不同档。 | 三个现役实例见下表 | L0 与 L1-L4 的全部渲染输入 |

**snapshot 的三个现役实例**:

| 实例 | 分辨率 | 覆盖 | 通道 | 喂谁 |
| --- | --- | --- | --- | --- |
| canonical chunk snapshot | 1m | 全世界(过渡期形态,长期收敛为 checkpoint) | 服务端持久层内部 | 恢复/checkpoint,不下发 |
| `ChunkSnapshot`(`0x62`)+ delta 流(`0x63`) | 1m | 近窗 3×3×3 tiles(滑动) | wire | L0 confirmed store:编辑/碰撞/交互的真值副本 |
| source page(7m occupancy+material mip) | 7m(客户端再整数规约 14/28/56m) | 远区 d≤72(L4 profile 扩 d96) | launcher/update 包(初始)+ HTTP 拉取(增量,dirty 通知触发) | L1-L4 远景,visual-only |

**近窗(活跃区)**:L0 覆盖的 3×3×3 tile 滑动窗口。1m snapshot 只在窗内持有,出窗即弃;窗外任何位置客户端**不持有任何 1m 合并态**(本地 world pack shard 是磁盘上的 baseline 底座,不是窗外的运行时合并态)。

**world pack 与 checkpoint 的关系**:world pack = checkpoint 的客户端分发形态(初始包与后续 checkpoint 在逻辑上都是 `world_snapshot`),内容 = `base ⊕ 全部 delta` 的 1m 物化,天然含玩家建造。pack 新鲜度只是效率参数——正确性由登录 `known[]` 对账保证,pack 旧只意味着登录增量大。分发范围契约见设计稿 T-12(required-set 三段式)。

## 2. 两条口径推论

1. **客户端是 snapshot-only 消费者(双分辨率)**。`base ⊕ delta` 是服务端的**生产配方**,snapshot 是客户端的**消费格式**。客户端生产渲染不消费 base、不消费裸 delta——`0x63` 只是"窗内 1m snapshot 的增量维护协议",其合并顺序仍由服务端裁决决定。
2. **分辨率随距离衰减的首先是数据分发,其次才是渲染**。同一 truth,近窗投影为 1m,远区投影为 7m。远区修改的可见性由 **7m page 重发布**承载(mip 翻动 → bump `source_revision` → dirty 通知 → HTTP 重拉),**不**由 1m delta 下发承载;1m delta 永不出近窗。
3. **配方与投影的分界线在 wire——已拍板为终态契约(2026-07-06)**。服务端内部自由使用配方形态(存储瘦身:未修改 chunk 不落库,按 `base ⊕ overlay` 懒物化——单实现,无 parity 问题);跨过 wire 的一律是投影(近窗 1m / 远区 7m)。"配方跨 wire"(客户端同构)已降格为特定负载画像下的定向优化选项,见 [`2026-07-06-projection-route-final-decision.md`](./2026-07-06-projection-route-final-decision.md)。
4. **近窗全量物化是任何方案的共同终态**。碰撞/raycast/编辑预检需要对窗口内任意体素 O(1) 随机访问其合并态;"overlay + WorldGen 单点懒算"撑不住该访问模式(一次 raycast 沿线数百次采样,每次都是多 octave 噪声计算),最终都要物化成同一份全量数组。方案间的差别只在数组的**来源**(wire 下发投影 vs 本地 base 计算 ⊕ overlay 叠加),不在客户端内存占用。

## 3. 远区修改回流回路(一条 delta 如何变成远景像素)

```mermaid
sequenceDiagram
  participant E as 编辑者客户端
  participant S as scene_server(truth)
  participant W as pages writer(服务端派生)
  participant C as 远处观察者客户端

  E->>S: 体素编辑 intent
  S->>S: 裁决 → commit 1m delta 入 canonical(永久)
  S-->>E: 0x63 delta(近窗内 1m 精度,L0 立即正确)
  S->>W: chunk 变更聚合到 macro cell
  W->>W: 重算该 cell 7m mip,与持久化基准比对
  alt mip 翻动(放置必翻;挖掉 7m 格最后一块实心才翻)
    W->>W: bump source_revision,重发布 page
    W-->>C: dirty 通知(cell 列表 + revision,wire 新 opcode,C3 配)
    C->>W: HTTP 拉新 page(过 sha256 gate)
    C->>C: 落盘缓存 → 规约降采样 → 建树 → merge → 渲染更新
  else mip 未翻动(如挖掉的不是该格最后一块实心)
    W->>W: 无事发生——远景天然免疫该 delta
  end
  Note over C: 观察者走近该区 → 进近窗 → 0x62 1m snapshot 接管,<br/>远景 artifact 被 suppression 裁掉
```

## 4. 用本表术语复述的三条既有裁决(索引)

- **客户端不用 base 驱动渲染或交互(终态)**:客户端 base 已故意 3D 分叉 + S4 仲裁锁死;2026-07-06 终态裁决将投影路线定为终态、同构路线降格为定向优化选项([`2026-07-06-projection-route-final-decision.md`](./2026-07-06-projection-route-final-decision.md))。"客户端本地推导 confirmed baseline"是 6-29/6-30 的原计划(H gate 的 WorldGen fixture/D 签名校验即为它而建),该目标已正式关闭。
- **远区不发 1m delta**:窗外渲染输入是 7m mip,而 `mip = downsample(base ⊕ 全部 delta)`——降采样发生在合并**之后**,客户端窗外没有 delta 全量,合并只能在服务端做(评审稿 A-4)。
- **page 就是远区 snapshot**:payload = 7m occupancy+material mip,规约算子(any-solid/众数)与失效契约见 [`2026-07-06-voxia-lod-layering-and-technology-design.md`](./2026-07-06-voxia-lod-layering-and-technology-design.md) §3.2b/T-4、§4/T-7。
