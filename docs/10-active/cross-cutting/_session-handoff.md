# 当前会话接力：Voxia 客户端网络无关功能分阶段收口

> 当前产品总纲：[`2026-07-14-voxia-client-offline-mock-closure-design.md`](2026-07-14-voxia-client-offline-mock-closure-design.md)；当前唯一展开范围：`阶段 1 · 世界渲染与场景生命周期`。渲染实现事实继续以 [`streaming-lod.md`](../../00-current-truth/design/client/streaming-lod.md)、[`纯 3D 立方壳上位阶段`](../voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md)和 [`A10 WorldGen 完整客户端滑动世界`](../voxel-far-field/2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md)为准。

## 2026-07-14 换机检查点

- 用户已确认“先完成全部网络无关客户端功能，再接真实服务器”，并批准六阶段顺序：`世界渲染与场景生命周期 → 体素交互 → Prefab 世界运行时 → Prefab Designer → Field 表现 → 客户端整体收口`。真实服务器接入在六阶段之后另开主线。
- 本轮 `$grill-me` 已把跨阶段约束记录为 D-001 至 D-062；Prefab Designer 细节全部冻结为阶段 4 输入，不再继续扩张总稿。下一台电脑只展开阶段 1，先做设计和验收口径，不直接进入实现。
- `clients/Voxia` 是独立仓库，跨机合并已经由 `master@ad442c6` 收口；本轮开始时工作树干净、本地相对 `origin/master` 为 `ahead 4 / behind 0`。既有合并态验证产物 [`Saved/Automation/a10_cross_machine_merge_verify/index.json`](../../../clients/Voxia/Saved/Automation/a10_cross_machine_merge_verify/index.json) 记录 `60/60` automation 成功、`0` 失败；本轮只做设计与接力文档，没有重新运行 Unreal build / Real-RHI。
- 外层 `ex_mmo_cluster` 本轮把此前暂存的完整 XYZ authority、归档客户端治理、文档分层与脚本调整连同本次阶段总纲一起作为整体检查点发布。换机时必须分别拉取 umbrella 与 `clients/Voxia` 两个仓库，不能只更新外层仓库。

## 当前判断

- **仍在里程碑 A，B/C 均未开始。** A 已从“8km 客户端渲染正确”扩展为“完整 3D near/far LOD + 可持续客户端流送 + 原子 presentation”。
- 普通 `-VoxiaWorldGenPreview` 现在只启动唯一 `AVoxiaUnifiedVoxelWorldActor` / `production_all_features` 顶层 root：成熟 near 滑窗/数据泵与 Pure3D far 同场，根级 ready 要求 near settled、far live 与 XYZ center aligned。legacy/VHI/SVO/Pure3D standalone 均为显式 probe/compatibility，不是第二正式主线。
- 当前根仍由两个迁移期子模块组成；root-owned source identity 与 far 消费已落地，但 near 尚未消费同一 provider/residency/coverage generation。Pure3D far 已完成 WorldGen/H-gated `local_disk` request、diff/residency/cancellation、source-bound shared artifact、parallel resolved surface、worker coverage plan、预算化 lease release 与 stable-XYZ-patch 首轮链路，不再每个 center 全量 materialize/aggregate。相邻 Real-RHI worker 约 `0.91-0.95s`。A10 下一步收敛统一 transaction、反向依赖/full oracle、离群帧和完整 route；服务器/HTTP/在线 authority 流送不进入 A10。服务端 authority、baseline/H gate 和 confirmed truth 边界没有变化。
- 跨机代码合并已形成 nested checkpoint `ad442c6`；以下既有证据仍只证明对应历史切片，不代表新的阶段 1 完成。阶段 1 必须重新建立自己的完整 XYZ 长巡航、材质、加载恢复和三入口验收门禁。

## 已完成成果

### 既有流送与表现基础

- near 连续 producer/apply、compact confirmed store、per-chunk 可复用组件、bounded pump/observe 已落地。
- far patch-native dirty 更新、后台 aggregation/bounds/fingerprint/DynamicMesh prepare 与 bounded GameThread submit 已落地。
- near/far 双向 ownership、near retirement lease、快速折返与相邻 tile 联合性能已在旧兼容路径收口；旧“垂直呈现带活性”只保留为迁移前证据，现役路径必须由同一个完整 XYZ near window 同时维护数据、mesh、readiness、prefetch、retirement 与 handoff。
- 当前兼容路径的完整 1600×900 near+far 相邻移动最终证据约 137 FPS，20 秒 p50/p95/p99/max=`7.250/8.148/8.644/16.569ms`，无 `>16.67ms` 帧；只代表当前验证机与该路径。

### 完整 3D near/far LOD 单代内核

- `FVoxiaFarFieldCubeShellPlanner`：XYZ ring/span/LOD、负坐标量化、underlap、唯一 owner、预算/溢出。
- `FVoxiaCanonicalVoxelPageBatch`：identity 与 pages 不可拆分；page 支持 resolved air/uniform/dense，missing 不等于 air。
- 六向 material mip、coverage-resolved exact surface、canonical→UE adapter 与世界坐标材质路径已落地。
- `FVoxiaVoxelPresentationGenerationCoordinator`、真实 `FRenderCommandFence` resource set、`UVoxiaVoxelPresentationSceneHost` 已闭环 hidden/live/retiring 生命周期。
- `AVoxiaPure3DVoxelWorldActor` 已完成地面 `[11,0,-51]` → 高空 `[11,12,-51]` Real-RHI 手动整代切换：worker 期间旧代持续可见，新代 near=`0`、far=`291021` quads，整代提交后才退役；scene submit 总计约 `3.599ms`。这不证明正常场景 lifecycle、滑动窗口或连续数据流送。

### 完整 XYZ authority checkpoint（已合并，阶段 1 仍需按新门禁重验）

- 唯一空间口径是完整 XYZ：near tile 每轴 `7` chunks，默认半径 `1` 为 `27 tiles = 9261 chunks`；单轴跨 tile 时 `entered/exited=9 tiles=3087 chunks`、`retained=18 tiles=6174 chunks`。旧 `3 tiles=1029 chunks`、XZ column、有限 Y 带和 `Y=0` 均不得回到现役契约。
- near 数据、mesh、readiness、prefetch、retirement、handoff 与 far hole 只消费一个 `FVoxiaNearVoxelWindow`。生产 near chunk radius 为 `10`；Gate cap=`10`、known chunk cap=`9261`，Auth manifest 必须覆盖 `21³`。`ChunkSubscribe 0x60` 布局不变，旧 `343` 容量必须在 H gate/manifest 校验中硬失败。
- confirmed voxel truth 只来自服务端 snapshot/delta/intent result 或已通过 H gate 的 baseline；missing 不等于 air，WorldGen 仅是 dev provider。旧 far wire/VHI/v1 SVO/column API 只保留 decoder/offline/归档边界，在线 legacy far 请求显式拒绝。
- P3b far generation 同代提交、P4 canonical writer/distribution/invalidation、P5 production cutover/compatibility 归档、halo/seam、9261/3087 容量和完整 near+far 三轴 Real-RHI 均未完成。

### 最新地基：source-neutral、H-gated batch 与本地 request provider

- `FVoxiaCanonicalVoxelShellSceneBuilder` 已成为 WorldGen/磁盘/网络无关的 shell→scene stage 主干：先生成 far+near required page set，再只消费 identity-bound batch；plan/coverage/source fingerprint 漂移或缺页均整批失败。
- 历史命名的 `FVoxiaWorldGenVoxelShellBuilder` 已成为 provider-neutral request orchestrator，只为 enter/dirty page 调用冻结 provider，并从 immutable residency 复用 keep-clean page 后调用通用 builder。
- `FVoxiaCanonicalVoxelPages::LoadExpectedBatch` 已要求更高信任入口给出的 manifest SHA-256、expected identity 与 expected set；加载前后复核 manifest，任一 page hash/size/decode/identity 失败时 batch 为空。
- `OpenExpectedManifest` + `FVoxiaLocalDiskCanonicalVoxelPageProvider` 已实现 live 子集语义：外部 H/expected identity 冻结 manifest entry table，只读取请求页，逐页校验且全批成功后发布。WorldGen、scripted 与 local 走同一 Build 路径。
- VXP2 统一材质页在 wire 上仍 dense，解码后恢复 compact canonical storage；dense/compact 等价内容 fingerprint 一致，避免本地包驻留与 mip 工作量膨胀。
- 以上仍是 A 的客户端开发路径，不是 B1 生产契约冻结，也不是在线 confirmed provider。

### 唯一生产组合根（A10-S1a）

- `FVoxiaVoxelWorldComposition` 冻结 `unified_production / legacy_probe / pure3d_probe / online_compatibility`；WorldGen 默认 unified，冲突 selector 与缺 provider 硬失败。
- `AVoxiaUnifiedVoxelWorldActor` 是 GameMode 唯一顶层 world root；root-owned `AVoxiaWorldActor` 只做成熟 near，Pure3D actor 只显示 far。旧 heightmap/SVO far 请求关闭，统一根不再构建或注册 Pure3D near mesh/component。
- `voxel_world_composition_state`、`voxel_world_root_state` 与 `until_voxel_world_root_ready` 已落地；near 全空气可 settled/zero geometry，missing window 不可 ready。
- 地面默认 Real-RHI：near=`855 components / 78451 quads`，far=`33725 pages / 359397 quads`；稳定帧 p95=`6.705ms`。高空 `[8,13,-54]`：near=`3087 ready / 0 geometry`，far=`288445 quads`，root ready，无旧二维柱洞。

### A10-S1b-1 root-owned source identity

- `AVoxiaUnifiedVoxelWorldActor` 已拥有唯一 `FVoxiaVoxelWorldSourceIdentity`，并把冻结 identity 传给 Pure3D far；far worker/provider/residency/artifact 由该 identity 绑定。
- 成熟 near 仍通过独立路径供数和呈现，尚未消费 root identity 或共享 residency/coverage transaction；S1b-1 缺专门 automation，现有 compile/runtime 证据不能证明统一事务完成。

### A10-S2-S5 Pure3D far 增量链

- `FVoxiaVoxelShellIncrementalPlan`、WorldGen/scripted page provider、immutable residency/lease/LRU 已接入正式 far worker；相邻 default 只请求 `1517/33752` page。
- cancellation token 贯穿 provider/mip/surface/mesh；default 快速 supersede 实跑 `requested/acknowledged/stale=2/2/2`，ack 约 `2ms`。
- material/surface cache 按 content 与实际 coverage-owner dependency fingerprint 复用；相邻 default 为 material `32199/1526` reused/rebuilt、surface `29533/4219`。
- material/surface cache 已改为 source-bound immutable shared refs；resolved surface 使用后台优先级并行构建，stage v4 暴露 work/publish 时间。`TFuture::Consume()` 消除完整 generation 复制，coverage diff 在 worker 运行，旧 coverage 在 worker 析构，residency v2 每 tick 最多释放 `1024` 个旧 lease。
- source-neutral scene builder 按绝对 XYZ `32³` tile bucket 产出 stable patch；scene host v2 只创建 replacement，commit 转交 retained UObject。相邻 +X 为 patch `required/retained/rebuilt/removed=216/175/41/0`，`53/53` geometry components visible；Null/Real-RHI scene submit 约 `3.2/3.9ms`。
- 当前主要残余为完整 dependency 扫描与 dirty surface closure：最新 Real-RHI artifact/完整 worker 约 `0.55-0.60s / 0.91-0.95s`；far GameThread prepare/finalize/publish 分段约 `4.5-7.5ms`。near 仍有独立 transaction，运行间仍有少量 `16ms+` 离群帧。

### A10-S2L H-gated 本地 provider

- `voxel_local_pack_build` 可生成 `stationary/adjacent_x/six_axis` route union v2 开发包，写入 payload/manifest，重新通过 H gate，并返回完整 UE 参数。
- default adjacent-X 包=`35269` pages / `336571434` bytes。唯一根冷启动读取 `33752` 页，最新 Real-RHI worker 约 `5.0-5.8s`，主要成本为本地磁盘 provider；相邻 +X 只读 `1517` 页、命中 `32235` residency keep，worker 约 `0.91-0.95s`，patch=`216/175/41/0`、`53/53` visible。
- 错误 H 时根契约 `voxia_unified_voxel_world_root_v3` 报 `authorized=false`、composition/source authorization=`true/false`，generation/residency/artifact/component 均为零，根级 error 透出 expected/actual H，且 provider kind 保持 `local_disk`，无 WorldGen fallback。
- 当前成熟 near 仍使用 WorldGen，所以本地根诚实报告 `mixed_near_worldgen_far_local_disk`；这不是 near/far provider 统一完成。
- 2026-07-13 可见唯一根手动实跑中，首代在 `[11,0,-51]` 正确提交并使根 `ready=true`；`233.496s` 交互式端到端冷启动经审计主要落在启动 Python/MCP/UDS/DDC 链，而非受控 voxel worker 的 `5.0-5.8s`，两者必须分开报告，仍不能当成发布性能。真实用户随后飞出 `adjacent_x` 开发包覆盖，generation 2-7 因 manifest 缺请求页而硬失败；旧 `live_generation=1` 保留、无 WorldGen fallback，但中心失配使根 `ready=false`。这确认失败契约有效，同时确认当前本地包只是有限 route fixture，S6 仍须补 `six_axis`/连续路线或本地按需 pack resolver。

## 证据锚点

| 证据 | 结果 |
| --- | --- |
| `clients/Voxia/Saved/Logs/voxia_pure3d_final_voxel.log` | `Voxia.Voxel` 41/41 success |
| `clients/Voxia/Saved/Logs/voxia_pure3d_final_presentation.log` | Presentation 5/5 success |
| `clients/Voxia/Saved/Logs/voxia_pure3d_source_neutral_builder.log` | Gameplay 10/10 success，含 source-neutral builder |
| `clients/Voxia/Saved/Logs/voxia_pure3d_h_gate_page_provider.log` | 最新 `CanonicalPagesV2` provider 回归 success |
| `pure3d_world_high_before/during/after_recenter.png` | 高空 Real-RHI 旧代保持、整代提交、非黑屏 |
| `.demo/observe/voxia_voxel_world_composition_automation/` | composition selector automation success / exit 0 |
| `.demo/observe/voxia_unified_production_real_rhi.log/.png` | 唯一根地面 ready、默认窗口/shell、frame perf 与 PNG 审计 |
| `.demo/observe/voxia_unified_production_flight_real_rhi.log/.png` | pawn 高空后 near zero geometry + far 连续、center aligned、root ready |
| `.demo/observe/voxia_a10_s3_default_cancel.log` | default rapid supersede cancellation `2/2/2`，只有最终 generation commit |
| `.demo/observe/voxia_a10_s5_default_move_r2.log` | Null-RHI 相邻 +X page/artifact/patch 增量与根中心一致 |
| `.demo/observe/voxia_a10_s5_real_rhi_move.log` | Real-RHI `216/175/41/0` patch transaction，`53/53` visible |
| `clients/Voxia/Saved/voxia_a10_s5_production*_real_rhi.png` | 两张 1280×720 图非黑比例 1.0，unique colors 14377/15542 |
| `.demo/observe/a10_s2l_manifest_open_gate_r2.log` | `CanonicalPagesV2` immutable open gate success |
| `.demo/observe/a10_s2l_local_provider_r3.log` | WorldGen/scripted/local conformance、missing/corrupt/identity/cancel/zero-partial-publish success |
| `.demo/observe/a10_s2l_default_pack_build.log` | default local route union pack 生成与 H gate success |
| `.demo/observe/a10_s2l_default_local_root_move_r2.log` | 本地 default 冷启动 + 相邻 +X page/residency/artifact/patch 增量，根两次 ready |
| `.demo/observe/a10_s2l_local_root_wrong_h_r3.log` | 根级 source authorization 硬失败、零发布、无 fallback |
| `.demo/observe/a10_s4_shared_cache_*.log` | shared artifact、parallel surface、scene builder 定向 automation success |
| `.demo/observe/a10_s4_budgeted_residency_*.log` | residency v2 budgeted release 与 provider/builder 回归 success |
| `.demo/observe/a10_s4_async_plan_full_move_real_rhi.log` | 相邻 worker `939.854ms`；GT prepare/finalize/publish `4.527/6.421/5.911ms`；frame p50/p95/p99/max `4.507/5.591/6.260/19.767ms` |
| `.demo/observe/a10_s4_async_plan_rapid_return_null.log` | 快速 A→B→A 的 generation 2 request/ack/stale=`1/1/1`，仅 generation 3 提交 |
| `.demo/observe/a10_user_visible_local_root_20260713_082049.log` | 可见唯一根首代 ready；交互式冷启动 `233.496s` 离群；飞出有限包后缺页硬失败、旧 far live 保留且根降为 not-ready |
| [`2026-07-14-a10-uncommitted-code-audit.md`](../voxel-far-field/2026-07-14-a10-uncommitted-code-audit.md) | S1b-1 source identity 现状、A10 未提交代码审计、测试缺口与跨机分支边界 |

主要 CLI：

- `pure3d_world_state` / `pure3d_stream_state`
- `voxel_world_composition_state`
- `voxel_world_root_state`
- stdio `until_voxel_world_root_ready [timeout_ms]`
- `pure3d_world_recenter x y z [small|default]`
- `pure3d_world_auto_follow 0|1`
- `pure3d_stream_cancel`
- `voxel_local_pack_build [center_xyz] [small|default] [stationary|adjacent_x|six_axis] [output_dir]`
- stdio `until_pure3d_scene_playable [timeout_ms]`
- stdio `until_pure3d_stream_settled [timeout_ms] [min_generation]`
- `voxel_coverage_ownership_probe`
- `voxel_presentation_generation_probe`
- `frame_perf`

## 当前缺口

1. 唯一根已能正常入场、联合 near/far 和 pawn XYZ 跟随；root-owned source identity 已由 far 消费，但 near 尚未消费同一 identity/page residency，也没有共享 coverage generation 与原子 transaction。
2. far 已按 page/artifact/patch 增量，shared artifact ref、parallel surface、async plan 和预算化回收已落地；但仍每代扫描完整 dependency fingerprint，相邻 dirty closure 重建 `4219` surface，desired→live 约 `0.91-0.95s`。缺反向依赖索引、增量/full oracle、离群帧上界和长巡航预算。
3. 尚缺出生、X/Y/Z、对角、连续移动、快速折返、传送、高空再回地面的统一 `frame_perf + generation trace + Real-RHI` 用户长巡航。
4. opaque world-aligned 路径已证明；dither/透明/发光材质族与 near/far 同点 audit 未收口。
5. H-gated 本地 request provider 已完成 far 首轮，但 near 尚未消费；当前 `stationary/adjacent_x/six_axis` 产物仍是有限 route fixture，自由飞出 manifest 覆盖会显式缺页并保留旧 far，尚未形成任意方向连续本地世界；在线 authority provider、delta 合并、source revision 失效、重连/续租和旧二维兼容代码退役均未完成。服务器相关工作不阻塞 A10 客户端闭环。
6. A10 审计仍有可执行缺口：S3 cancellation quantum 硬编码、`ProviderInvalidated` 无活路径；S5 缺 per-patch budget 和 gap/overlap 强断言；planner 只覆盖单轴主要路径，residency/cancel 生命周期断言不足；S1b-1 缺 automation。
7. 外层完整 XYZ authority 与内层 Voxia 已形成同一换机检查点，但尚未按新的阶段 1 门禁完成 umbrella test、完整 XYZ 长巡航、材质 audit、加载恢复和联合 CLI / Real-RHI 验收；P3b/P4/P5 不能写成完成。

## 下一步：只展开阶段 1

1. 先从 current-truth 与 live Voxia code 建立阶段 1 的“已有 / 部分完成 / 未完成”玩家功能矩阵，重点覆盖唯一生产根、完整 XYZ 滑动窗口、near / far LOD、材质连续性、加载 / 重试 / 返回主菜单。
2. 比较 2–3 种只服务阶段 1 的模块边界，明确 WorldGen Mock、confirmed state、调度、presentation、loading recovery 与 observe 的责任；不讨论阶段 2 的体素编辑或阶段 3–5 的 prefab / field 细节。
3. 分节批准阶段 1 设计，写独立规格并做一致性自审；用户书面批准后再调用 `writing-plans`，不能从本 handoff 直接开写代码。
4. 阶段 1 实现后的门禁必须同时包含真实玩家操作、automation、CLI / 结构化日志，以及完整 near+far Real-RHI；`-VoxiaNearWindowOnly` 仍只能诊断，不能作为最终证据。

## 禁止越界

- 不修改 `apps/*` pages writer、dirty aggregator、wire opcode、HTTP endpoint 或 launcher；这些属于 C。
- 不把通用 v2 codec 当成已冻结的生产 7m page 契约；那属于 B。
- 不把 dev WorldGen 结果称为 confirmed truth，也不以 snapshot/resync 绕过 baseline H gate。
- 不恢复任何 `VoxiaSvoRaymarch*` profile；raymarch 已因真实 RHI 队列超时退出当前路线。
- 不给旧 `Y=0` / XZ near-skip 打补丁来冒充三维完成；新路径必须由同一 generation 的 XYZ owner 自维护正确性。

## 历史文档

- 原 A1-A5：[`phase-vlod-a4-seam-fade-collar.md`](../../20-archive/voxel-far-field/phase-vlod-a4-seam-fade-collar.md)
- 流送性能：[`phase-far-temporal-stability-and-seamless-streaming.md`](../../20-archive/voxel-far-field/phase-far-temporal-stability-and-seamless-streaming.md)
- 双向 handoff：[`2026-07-11-near-far-presentation-handoff.md`](../../20-archive/voxel-far-field/2026-07-11-near-far-presentation-handoff.md)
- 旧三维窗口：[`2026-07-11-3d-lod-sliding-window.md`](../../20-archive/voxel-far-field/2026-07-11-3d-lod-sliding-window.md)
