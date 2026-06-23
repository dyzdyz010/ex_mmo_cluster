# 力学应力 · 结构支撑/坍塌(决策稿)

- 日期:2026-06-23
- 状态:**执行中**(决策稿先行;用户已拍板方向「先力学」)
- 关联:`docs/voxel-server-authority/2026-06-16-orthogonal-systems-architecture.md`(§"补缺系统"点名 力学应力 为化学之后的下一个正交域)、`docs/2026-06-23-world-content-driven-field-provisioning.md`(provisioning 框架 + 局限②)、[[field-provisioning-framework]] [[emergence-reaction-layer]]
- 触发:用户目标序列「力学 → 光场 → loop+zone」。力学是建设系统的地基(城市不能凭空浮空,要讲支撑)。

## 1. 目标

加入**第 5 个正交物理系统:结构支撑**。一个实心结构 cell 若**没有到地面的支撑路径**就**坍塌**(碎成 debris)。串联现有系统:**烧断承重梁(燃烧)→ 上方失支撑 → 坍塌**(热→化学→力学)。和其它系统一样:**属性派生激活、只经 truth 耦合、组合涌现、无 id 白名单**。

## 2. 设计(复用现成件,几乎不造新轮子)

### 2.1 关键洞察:支撑 = 连通性

「结构支撑」= 连通可达性分析:**这个 cell 有没有经实心结构邻居连到地锚**。这与电路闭合判定同构(`CircuitComponentAnalysis` 已在做连通分量)。力学复用同一范式:从地锚 BFS,可达的实心结构 cell = 有支撑,**未达的 = 失支撑 → 坍塌**。

### 2.2 材料属性(append-only)

- **`structural`**(material_default,默认 1):此材料是否**承重/传力的实心结构**。流体/气/松散(water/steam/lava/molten_iron/ember)设 0;石/土/木/铁/玻璃等 = 1。属性派生:`structural=1` 的实心 cell 才参与支撑图。
- v1 **不引入应力幅值**(`yield_strength`/超载)——只做**二元 supported/unsupported**(连不连到地)。幅值超载坍塌留 v2。

### 2.3 纯分析 `StructuralSupport`

输入 region AABB + storage(truth)。
- **地锚**:chunk 底层(local y=0)的实心结构 cell(站在地基上)。
- **BFS**:从地锚出发,沿**六向面相邻**的实心结构 cell 扩散(macro 级面相邻即可,v1 不需 circuit 那种微接触精度)。
- **输出**:可达集 = supported;region 内**实心结构 cell − 可达集 = 失支撑集**。
- 纯函数、chunk-local、O(结构 cell 数)(用已加的逐 cell O(1) header 访问)。

### 2.4 `StructuralStressKernel`

跑在 field region(同其它 kernel)。每 tick:
- 算失支撑集 → 对每个发 `{:collapse_block, %{macro_index: idx}}` 效果。
- **链式收敛**:坍一层可能让上方再失支撑 → kernel 逐 tick 收敛(每 tick 去一层),O(结构高度) tick 后稳定(无失支撑)→ region 释放。安全阀:`max_effects_per_tick` 截断(防一帧塌整城)。

### 2.5 `:collapse_block` 效果

`ChunkProcess.apply_field_effect` 加一支 `:collapse_block`:**清掉该 cell + 发 debris**(复用 `apply_damage_block_effect` 归零毁块 → ObjectStateDelta/debris 的现成路径)。客户端 `debris_render` 已能渲染碎块落下。

### 2.6 `StructuralStress` provisioner(第 3 个 provisioner)

- **active**:chunk 有**未直接坐在地面**的实心结构 cell(存在潜在失支撑)。无悬空结构(全坐地)→ inactive。探测复用 §2.3 分析:有失支撑 *或* 有离地结构即起。
- 块变更 sweep → 起 stress region → kernel 坍塌失支撑 → 稳定后释放。
- 与电路/emergence provisioner 并存(各 source_key)。

### 2.7 局限②(field-commit 触发重 sweep)——本轮一并做

**烧断梁→坍塌**要求:反应在 tick 内**毁掉**一个 block(field commit)后,**重新触发 provisioning sweep**,让 stress 重算支撑。这正是 provisioning 框架的**局限②**。本轮实现「**field 效果提交 truth 变更 → 去抖重 sweep**」:既闭合局限②(火/热自蔓延的动态续命),又让 **燃烧→坍塌** / **坍塌→连锁坍塌** 跨系统链自动成立。一个机制,两处收益。

## 3. 效率 / MMO 适配

- **事件驱动**:仅块变更 / field-commit 触发(非每 tick 永远跑)。结构静态时零开销。
- **chunk-local**:地锚 = 本 chunk 底层。**跨 chunk 大建筑的支撑 v1 做 chunk-local 近似**(同光的本地半径折中);全局连通太贵,留 v2。
- **有界**:单次 BFS O(结构 cell);链式坍塌 O(高度) tick;`max_effects_per_tick` 封顶;`VoxelSimScheduler` 节点预算兜底。
- **复制**:坍塌改 truth → ChunkDelta + debris ObjectStateDelta,走现成权威+复制路径。每次结构事件一次,不是持续负载。

## 4. v1 局限(记档,后续放宽)

① **跨 chunk 支撑**:地锚仅本 chunk 底层(浮在邻 chunk 上的结构会误判失支撑)。② **无应力幅值**:二元 supported/unsupported,不模拟「超载压垮」(留 v2 + yield_strength)。③ **坍塌 = 碎成 debris**,非「落下重新堆叠成实心」(留 v2 sand/gravel 式 settle)。

## 5. 逐 step 计划

1. **step1**:决策稿(本文件)。
2. **step2**:`structural` 属性(catalog bump)+ `StructuralSupport` 纯分析 + 单测。
3. **step3**:`StructuralStressKernel` + `:collapse_block` 效果(ChunkProcess 毁块+debris)+ 单测。
4. **step4**:`StructuralStress` provisioner(注册 @field_provisioners)+ 生产 e2e(悬空结构坍塌 / 坐地结构存活)。
5. **step5**:field-commit 触发重 sweep(局限②)+ 烧梁→坍塌链 e2e。
6. **step6**:bevy Layer-3 showcase(坍塌 → debris 上屏)。

每 step 一个 commit(co-author `Claude Opus 4.8 (1M context)`)。

## 6. 测试策略

- 单元:支撑分析(地锚可达/悬空失支撑/链式)。
- kernel:失支撑 → collapse 效果数 + 收敛。
- 生产 e2e:真 ChunkProcess 放悬空塔 → 自动坍塌;坐地塔 → 存活;烧断底梁 → 上方连锁坍塌。
- 客户端:Layer-3 像素 showcase(坍塌碎块上屏)。
