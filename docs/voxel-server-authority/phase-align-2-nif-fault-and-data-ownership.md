# 对齐迁移 · 梯队 2:NIF 故障与数据归属

> 上层索引:[`2026-06-14-architecture-triage-and-alignment.md`](./2026-06-14-architecture-triage-and-alignment.md)
> 规范依据:NIF-1/2/3/5/6/8/11/12/15、BND-1/5、PRIN-2、ANTI-3/13/15。
> 纪律:决策稿先行 → 逐 step commit(`mix format` + Rust rebuild + scene 回归)→ 进度日志 → 不 push → 不留兼容。

## 目标

把 Rust NIF 从"无故障隔离 + 数据每 tick 序列化进出 Elixir"提升到规范的
**FFI 故障隔离(catch_unwind / 无 panic 源)+ 节点级 SimRuntime 统一调度 + 场/体素本体常驻
ResourceArc(数据留 Rust,命令队列/事件回传/水位背压)**。这是 BND-1/PRIN-2 数据归属与 NIF 故障
模型的承重契约。

## 现状锚点(2026-06-14 审计)

- **panic 策略**:6 crate 无显式 `[profile]`(默认 panic=unwind,Rustler `#[rustler::nif]` 生成的
  wrapper 已在 FFI 边界 catch_unwind → 默认安全);`scene_ops/character/movement.rs` 3 处
  `SystemTime::now().duration_since(UNIX_EPOCH).unwrap()`(时钟回退即 panic,真实运行时风险);
  `octree/octree_node.rs` 2 处内部不变式守卫(always 8 children,实际不可达);其余 `.unwrap()` 均在
  `#[cfg(test)]` 断言内(安全);`coordinate_system` 整 crate 梯队4 删除(忽略其 panic)。
- **节点级 SimRuntime**:不存在;场 tick 每 region 一个 `FieldTickWorker`(Elixir GenServer,
  `Process.send_after` 自调度 10Hz + 同步调 NIF),无统一 CPU 预算/线程池(违 NIF-1/5、ANTI-15)。
- **field_kernel**:无状态数学 NIF,0 ResourceArc,场数据(FieldRegion/FieldLayer)留 Elixir,
  每 tick 序列化进出(违 BND-1、PRIN-2、ANTI-3、NIF-3/8)。
- **scene_ops**:rapier3d 角色碰撞,2 ResourceArc;rapier parallel 线程池未交 SimRuntime。
- **octree**:空间索引 ResourceArc,只回 id 列表(留用,BND-1/5 合规)。
- **movement_core/movement_engine**:纯 f64 确定性积分核 + NIF 薄壳(留用,DET-1/2/3 反作弊基准)。

## 改造顺序(子步)

- **2.5(本梯队首步,NIF-6/11/15 故障隔离)**:
  - **2.5a** 移除生产 panic 源:`scene_ops/character/movement.rs` 的 `SystemTime::now()...unwrap()`
    改不 panic 的 `now_millis()`(`.map(...).unwrap_or(0)`);octree 不变式守卫保留(不可达 + Rustler
    catch_unwind 兜底,改 Result 会污染 insert 签名,过度工程)。
  - **2.5b** FFI 故障隔离守卫:留用 NIF crate(scene_ops/octree/field_kernel/movement_engine/
    movement_core)显式 `[profile.release] panic = "unwind"`,文档化"NIF panic 必须 unwind 让 Rustler
    wrapper 在 FFI 边界 catch_unwind 转 Elixir 错误,禁 abort"(NIF-11/15;guard 未来误设 abort)。

- **2.6(NIF-1/5 节点级 SimRuntime)**:新建节点级 `SceneServer.SimRuntime`,统一 CPU 预算 + 线程池
  调度所有场 tick(取代 per-region FieldTickWorker 各自 send_after 自调度);rapier parallel 线程池
  也交 SimRuntime。FieldTickWorker 编排逻辑保留,调度交 SimRuntime。**大子步,独立设计细化。**

- **2.7(BND-1/NIF-2/3/8 数据归属)**:场/体素本体迁入 `ResourceArc<CellSim>`(Rust 常驻),
  field_kernel 从"无状态数学 NIF"改为"持 CellSim 资源 + 命令队列入 + 事件回传出 + 水位背压"。
  数据不再每 tick 序列化进出 Elixir。**最大子步,独立设计细化(可能需多个 sub-commit)。**

> 排序理由:2.5 故障隔离最小、与数据归属解耦,先做;2.6 SimRuntime 是 2.7 的调度底座;2.7 数据归属
> 最大、依赖 2.6。2.6/2.7 各自落地前补充独立设计细化(本文件追加或单独决策稿)。

## 测试矩阵(每步)

- `mix compile`(触发 rustler 重建相关 crate,0 warning)。
- 各 crate `cargo test`(movement_core 39+ 等)。
- scene_server 全量回归(918,排除已知 observe-log flaky,见 memory)。
- 已知预存失败 `world_server/.../authority_observe_test.exs:35`(Windows path)不动。

## 验收

- NIF 故障隔离:生产路径无 panic 源(SystemTime 等),panic=unwind 显式守卫 FFI catch_unwind(NIF-11/15)。
- 节点级 SimRuntime 统一场 tick 调度 + CPU 预算(NIF-1/5)。
- 场/体素本体常驻 ResourceArc<CellSim>,命令队列/事件回传/背压,数据不每 tick 序列化(BND-1、NIF-2/3/8)。
- scene 全量 0 净回归。

## 进度日志(时间倒序)

- 2026-06-14:**step 2.5(NIF 故障隔离,NIF-6/11/15)完成**。2.5a:`scene_ops/character/movement.rs`
  3 处 `SystemTime::now()...unwrap()` 改不 panic 的 `now_millis()`(时钟回退退化为 0,不再越 FFI 边界
  panic)。2.5b:scene_ops/octree/field_kernel/movement_engine 4 个 cdylib NIF crate 加显式
  `[profile.release] panic = "unwind"`(movement_core rlib 由根 crate profile 覆盖,不加)。`mix compile`
  确认 4 crate **release 模式**重建成功(守卫生效)、无 profile-ignored 告警;scene 918 全绿 0 回归。
  octree 不变式守卫(always 8 children,不可达)保留 + Rustler catch_unwind 兜底。**剩余 2.6 SimRuntime、
  2.7 ResourceArc<CellSim>。**

- 2026-06-14:决策稿落定。panic 源审计完成(生产真实风险仅 movement.rs SystemTime ×3;FFI 边界默认
  已由 Rustler catch_unwind 保护,补显式 panic=unwind 守卫)。拆 2.5(故障隔离)/2.6(SimRuntime)/
  2.7(ResourceArc<CellSim> 数据归属)。先执行 2.5。
