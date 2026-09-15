# Voxim B3 活动计算增量

分类：Global system 设计与实现记录；规模实验和 Demo 属 Test-only。

## 附近观察续接（2026-09-15，实施中）

按 Voxim R7 §5.4.1，先完成冷入场 HP，再接直接攻击与已有温度。复用 World 原子快照/订阅和可靠 voxel 流：属性批次携带会话、窗口、提交点、定义摘要、已启用默认值、稀疏状态及宏格 epoch；完整帧结束才替换确认副本，随后消费有序增量。最低层 occurrence 继续由 World 的 property_state/component_max_hp 结算，相关性取实际占用区域；删除取提交前后区域并集。Replica 只投影这些不可变结果。无关事务仍传递进度。观察客户端移至现有世界复制 owner，HUD 只读。

依据：[etcd API guarantees](https://etcd.io/docs/v3.5/learning/api_guarantees/) 的 revision 与有序完整 watch，适用于快照 N 加 N 之后变化的接缝；这里不引入 etcd、另一日志或新订阅框架。可观测面：批次范围/N/状态数/字节/接纳时间、就绪后 HP、查询数、缓存释放、输入及 HUD 时刻。验证覆盖冷默认与受损、跨区叶子、删除/替换、进出窗口、迟到与跨 Scene、双端及恢复；按可运行增量推进。

性能评估覆盖 scene/world 的生成、模拟、事务与观察。现有两个 app 已依赖 Rustler 0.37.3，生成使用 DirtyCpu。依据 [ERTS NIF 官方文档](https://www.erlang.org/doc/apps/erts/erl_nif.html) 与 [Rustler nif](https://docs.rs/rustler/latest/rustler/attr.nif.html)：超过约 1 ms 的 CPU 内核应使用 DirtyCpu；它不会自动解除调用 World 的等待。先测数值 Map/编码拷贝、回调/排队、持久化及广播，再决定连续数组内核或有界计算任务；计算只输入不可变 canonical 数据并返回结果，World 仍校验身份/版本、持久化、确认。不迁移旧通用 FieldRuntime，不把未来天气需求当成先造框架的理由。

目标：保持既有守恒导热、50 ms 步进、先持久后确认及旧世界恢复语义，让小热区计算不再随历史损伤记录数量增长。先在独立 B3 实例恢复已有玩家结构并加热，再补规模与编辑失效验证。

依据：[OpenVDB 官方 Overview](https://www.openvdb.org/documentation/doxygen/overview.html) 的 Active and Inactive Voxels / active-only iterators：活动标志与保存的值分离，只遍历有兴趣的单元。这里仅采纳活动集合与数值分离的组织方法，不引入 OpenVDB、树网格或新的世界真值。几何摘要按实际编辑及相邻面失效，沿 World 现有几何提交接缝维护；热公式仍使用首片的守恒通量离散。

实现决定：World 增加不持久化的 thermal_work，包含未平衡单元索引、当前求值集合的只读几何摘要及接触对。温度/HP仍只存damage。启动、环境配置变化时从持久状态重建索引；每步从实际结果更新活动集合；几何变化只失效受影响格及邻格摘要；每批沿实际访问节点收集变化键，不再遍历整个damage。缓存随活动集合收缩，不随世界历史无限增长。当前不改变权威进程边界、数值步进、wire或耐热规则。

观察：结算日志增加hot/candidates/geometry_builds；测试必须覆盖冷缓存与复用缓存结果一致、邻格编辑失效、热前沿进入新格、替换身份、平衡保留及重启重建。规模实验分别增加历史冷记录、同时活动格数，记录结算、持久化、派生内存；小Demo不能冒称大规模容量验收。网络过滤与默认状态完整快照沿Voxim R7 §5.4.1推进，不把模拟活动集当玩家观察范围。

进度：本增量已实现并在独立实例 voxim-b3-demo 实跑。两次五木块脉冲各 271 次提交，双客户端温度/HP 逐条一致；热中采掉上层块后只重建 7 项摘要，付费重建消耗回收的 512 单位木材，新身份 2804 重新导热。seq 3077 重启前后温度、HP、身份、库存、占用一致，全新双端恢复五条状态。当前 2 kW / 10 kJ 小脉冲没有追加过热损伤，既有损伤保留；过热实跑见首片记录。

完整五格脉冲只在首批构建 24 项摘要，后 270 批构建数为 0；结算 p50/p95/max 为 0.306/0.968/2.534 ms，持久化为 7.298/9.469/13.147 ms。工作结构活动时 9544 B、平衡后 312 B；权威稀疏状态不删除。仍是十个 50 ms 步、完成后等待 500 ms 再提交，实际提交间隔 p50 508.605 ms。网络发送格式和观察范围未变。

规模夹具在独立 BEAM VM 对比基线 28c92774，五次热批中位数：5 活动+10 万冷历史由 219.243 ms 降为 0.150 ms；1000 活动由 174.291 降为 112.426 ms；10000 活动由 2746.670 降为 2062.257 ms。六组温度误差均为 0，HP/身份一致。此对照排除真实持久化与网络成本；首次冷批没有统一改善。大量活动格仍超过节奏，不能宣称大世界容量验收。尚未接区域分桶、区域完整属性快照/观察及卸载生命周期；后续数值内核与调度改动以本次瓶颈测量为依据。

验证：在 apps/voxel_region，MMO_DB_PORT=5433，mix test test/damage_world_test.exs --only b3 --no-start --seed 0 为 8 通过；test/thermal_test.exs 为 3 通过；damage_world_test.exs 全文件 44/45，唯一失败为既有 B2 缺失 GateServer.Session.Sink.quic/2。新增测试覆盖局部失效、热前沿缓存/强制重建数值一致、热中恢复活动索引。

完整说明和可复现工具在 Voxim 的 Docs/R7/B3-active-thermal.md、Docs/R7/tools/b3_active_scale.{py,exs}、b3_active_measure.py。原始证据在 Voxim Saved/R7/B3/active-* 及 Server/active-scale/results.json；最终编译及旧 beam 备份在 Server/active-build-final。客户端实际二进制为 5b86388，服务端为 28c92774 加本增量。仅部署 B3，未触碰青岚关卡、文件或容器。

后续修正（2026-09-15）：上文唯一失败已修复。将 B2 的 Ready 前库存查询和作者权限拒绝用例移到 Gate 的 `voxim_production_dispatch_test.exs`，保留真实 Dispatch/Sink/World 与原始断言，仅以空世界启动夹具替代无关损伤夹具。不添加 voxel_region → gate_server 依赖。依据是现有两 app 的 mix.exs 依赖方向与 Gate 会话层 README 的职责归属，运行时未改。各自 app 下以 MMO_DB_PORT=5433、--no-start --seed 0 运行：Gate 迁移用例 1 通过，World 原损伤文件剩余 44 项全部通过。日志位于 Voxim Saved/R7/B3/b2-dispatch-fix-{gate,world}.log；无需重部署或重跑未受影响的双客户端热实验。

## 附近属性增量与模拟内核评估（2026-09-15）

分类：Global system实现与Test-only验证记录。World原子canonical快照/增量新增property_context与宏格epoch；PropertyObservation按完整XYZ窗口筛选宏格及完整叶子汇总，删除保留旧占用范围。Replica保留上下文、身份与按新窗口更新订阅；Player用新M1 kind5 PropertyBatch在同一可靠流发布，完整帧是完成边界。无订阅者不构造观察投影，热活动不受玩家观察控制。未改变持久化先于确认及停机不补算。

独立voxim-b3-demo双端已冷入场直接读HP/温度、零自动查询直接攻击、271次热提交共1355条双端完全相同；最终两次攻击破坏、回收512、付费原位重建，重建epoch3354/HP100，平衡seq3355。服务端重启前后HP/温度、能量、库存、占用及epoch相同。World测试46通过，Player/transfer9通过，新协议261B跨语言golden通过；UE8项相关用例通过。详情与可复现工具/限制见Voxim `Docs/R7/B3-observation.md`。真实步行窗口退出/重进、远隔玩家及独占性能仍待验收；固定范围Demo不替代这些门槛。

Rustler已存在，建议下一步做连续节点/边数组与批量十步内核实验，尚未部署热NIF。独立VM插桩：1万活动格批总耗时中位1114.943ms、Thermal.step中位573.871ms，其余逐批相减中位541.072ms，所有温度与原路径相同；假日志、无广播、共享机器，不作独占容量验收。只搬算术即使理想零耗时也难满足500ms。世界参数/场模拟仍归服务端scene/world；需一并测状态组织、拷贝、World接纳/落盘/广播及邮箱等待。DirtyCpu不解除调用World的等待；若用有界计算任务，输入不可变、结果按身份/版本接纳，唯一authority先持久后确认。不要引入第二世界真值或为未来场类型预建框架。


## 真实多人流送与 Rustler 批量模拟（2026-09-15）

附近 HP／温度的真实步行退出／重进、远隔过滤、无人观察仍模拟、Scene 1→2→1 已通过真实 UE 双端验收，证据在 Voxim Saved/R7/B3/streaming-*。窗口和 HUD 延迟已测量；B3 整体物理范围、独占帧时间与容量仍未验收。

保持显式 Euler 固定 50 ms 步进与逐步 HP 扣减，DirtyCpu NIF 接收不可变节点／边数组；活动种子变化立即交还 World 重建六邻域。World 是唯一提交者，先持久化再确认。独立 voxim_thermal crate 不持有 Rust 世界资源，不修改世界生成器或 content_version。

依据 Erlang NIF 的 dirty scheduler 语义与 Rustler 0.37.3 的 schedule 属性：https://www.erlang.org/doc/apps/erts/erl_nif.html 和 https://docs.rs/rustler/0.37.3/rustler/attr.nif.html 。DirtyCpu 释放普通调度器，但调用 World 仍等待；现有 Thermal.step 保留为数值参考，未加入异步任务或通用场框架。


实验完成：新 voxim_thermal/ThermalNative 与 World 数值批次已部署 B3，真实双端热变化/远隔过滤/1→2→1通过，旧世界保留至seq4152且再次重启一致。热源删除导致旧活动种子无原生节点时，先执行单步让 World 收缩邻域；源耗尽/热前沿变化也在正确步末返回。初始相关52项、补充后B3九项和原生四项通过。客户端/Player只补日志，未改协议。

最终1万活动格同输入无数据库中位1232.835→116.285ms；独立voxim_b3_rustler_perf真实Db事务/回放、近远canonical观察者投影/编码、GenServer排队读取中位892.630→103.949ms，温度差0、HP身份一致。准备29.311ms、NIF含解码编码3.692ms、World接纳16.996ms、落盘35.178ms；排队读取中位103.796ms。后续性能重点为数据组织、持久元数据、观察投影，不能从本次共享机实验宣称大世界容量或1万状态真实UE吞吐验收。原始证据与命令归Voxim Docs/R7/B3-observation.md及Saved/R7/B3/Server/rustler-{experiment,pipeline}-final，部署记录rustler-build-clean。
