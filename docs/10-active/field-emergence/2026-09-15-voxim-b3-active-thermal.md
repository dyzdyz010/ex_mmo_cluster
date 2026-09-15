# Voxim B3 活动计算增量

分类：Global system 设计与实现记录；规模实验和 Demo 属 Test-only。

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
