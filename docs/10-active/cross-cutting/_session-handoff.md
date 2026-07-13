# 当前会话接力：Voxia 扩展里程碑 A

> 当前上位 resume：[`2026-07-12-pure-3d-voxel-shell-migration.md`](../voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md)；当前主攻任务：[`A10 WorldGen 驱动的完整客户端 3D 滑动世界`](../voxel-far-field/2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md)。原 A1-A5、流送性能、near/far handoff 与视觉专项均已归档；被推翻的 2.5D 三维窗口/VHI baseline 路线已置废。

## 当前判断

- **仍在里程碑 A，B/C 均未开始。** A 已从“8km 客户端渲染正确”扩展为“完整 3D near/far LOD + 可持续客户端流送 + 原子 presentation”。
- 普通 `-VoxiaWorldGenPreview` 现在只启动唯一 `AVoxiaUnifiedVoxelWorldActor` / `production_all_features` 顶层 root：成熟 near 滑窗/数据泵与 Pure3D far 同场，根级 ready 要求 near settled、far live 与 XYZ center aligned。legacy/VHI/SVO/Pure3D standalone 均为显式 probe/compatibility，不是第二正式主线。
- 当前根仍由两个迁移期子模块组成，没有共享 near/far provider/residency/coverage generation；但 Pure3D far 已完成 WorldGen/H-gated `local_disk` request、diff/residency/cancellation、source-bound shared artifact、parallel resolved surface、worker coverage plan、预算化 lease release 与 stable-XYZ-patch 首轮链路，不再每个 center 全量 materialize/aggregate。相邻 Real-RHI worker 约 `0.91-0.95s`。A10 下一步收敛统一 transaction、反向依赖/full oracle、离群帧和完整 route；服务器/HTTP/在线 authority 流送不进入 A10。服务端 authority、baseline/H gate 和 confirmed truth 边界没有变化。
- 当前代码与文档均有未提交改动；以下证据只绑定对应工作树时点，最终交付前需重跑。

## 已完成成果

### 既有流送与表现基础

- near 连续 producer/apply、compact confirmed store、per-chunk 可复用组件、bounded pump/observe 已落地。
- far patch-native dirty 更新、后台 aggregation/bounds/fingerprint/DynamicMesh prepare 与 bounded GameThread submit 已落地。
- near/far 双向 XYZ ownership、near retirement lease、垂直呈现带活性、快速折返与相邻 tile 联合性能已收口。
- 当前兼容路径的完整 1600×900 near+far 相邻移动最终证据约 137 FPS，20 秒 p50/p95/p99/max=`7.250/8.148/8.644/16.569ms`，无 `>16.67ms` 帧；只代表当前验证机与该路径。

### 完整 3D near/far LOD 单代内核

- `FVoxiaFarFieldCubeShellPlanner`：XYZ ring/span/LOD、负坐标量化、underlap、唯一 owner、预算/溢出。
- `FVoxiaCanonicalVoxelPageBatch`：identity 与 pages 不可拆分；page 支持 resolved air/uniform/dense，missing 不等于 air。
- 六向 material mip、coverage-resolved exact surface、canonical→UE adapter 与世界坐标材质路径已落地。
- `FVoxiaVoxelPresentationGenerationCoordinator`、真实 `FRenderCommandFence` resource set、`UVoxiaVoxelPresentationSceneHost` 已闭环 hidden/live/retiring 生命周期。
- `AVoxiaPure3DVoxelWorldActor` 已完成地面 `[11,0,-51]` → 高空 `[11,12,-51]` Real-RHI 手动整代切换：worker 期间旧代持续可见，新代 near=`0`、far=`291021` quads，整代提交后才退役；scene submit 总计约 `3.599ms`。这不证明正常场景 lifecycle、滑动窗口或连续数据流送。

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
- 2026-07-13 可见唯一根手动实跑中，首代在 `[11,0,-51]` 正确提交并使根 `ready=true`，但普通交互式冷启动端到端为 `233.496s`，显著慢于受控 `5.0-5.8s` 证据，须复现归因。真实用户随后飞出 `adjacent_x` 开发包覆盖，generation 2-7 因 manifest 缺请求页而硬失败；旧 `live_generation=1` 保留、无 WorldGen fallback，但中心失配使根 `ready=false`。这确认失败契约有效，同时确认当前本地包只是有限 route fixture，S6 仍须补 `six_axis`/连续路线或本地按需 pack resolver。

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

1. 唯一根已能正常入场、联合 near/far 和 pawn XYZ 跟随；Pure3D far 有 scene phase/cancel/EndPlay，但 root-owned 两个迁移期 actor 尚未共享 source identity、page residency、coverage generation 与原子 transaction。
2. far 已按 page/artifact/patch 增量，shared artifact ref、parallel surface、async plan 和预算化回收已落地；但仍每代扫描完整 dependency fingerprint，相邻 dirty closure 重建 `4219` surface，desired→live 约 `0.91-0.95s`。缺反向依赖索引、增量/full oracle、离群帧上界和长巡航预算。
3. 尚缺出生、X/Y/Z、对角、连续移动、快速折返、传送、高空再回地面的统一 `frame_perf + generation trace + Real-RHI` 用户长巡航。
4. opaque world-aligned 路径已证明；dither/透明/发光材质族与 near/far 同点 audit 未收口。
5. H-gated 本地 request provider 已完成 far 首轮，但 near 尚未消费；当前 `stationary/adjacent_x/six_axis` 产物仍是有限 route fixture，自由飞出 manifest 覆盖会显式缺页并保留旧 far，尚未形成任意方向连续本地世界；在线 authority provider、delta 合并、source revision 失效、重连/续租和旧二维兼容代码退役均未完成。服务器相关工作不阻塞 A10 客户端闭环。

## 下一步顺序（仍属 A10）

1. S0b 补出生→水平六向→垂直→对角→折返→传送 route driver、HUD 与 lag 分位数。
2. S1b 把两个迁移期模块收敛为共享 source/residency/coverage transaction；Pure3D hidden near 已消除，不要回退。
3. S4 继续做反向依赖索引与增量-full oracle，把约 `0.9s` worker 延迟和偶发 `16ms+` 帧压入巡航预算；shared artifact ref 已完成，不要重复立项。
4. S5 补跨 patch key 边界产生 removed 的 Real-RHI route、gap/overlap 计数；当前 retained/rebuilt 已验证。
5. S6 用真实 pawn完成 X/Y/Z/对角/折返/传送/高空再回地面的连续路线，记录 provider、worker、cache/diff、scene submit、fence 与 `frame_perf`。
6. S7 收敛材质连续性并完成 A10 验收；服务器/HTTP/在线 authority provider 仍后置，只有 A 退出后才开始 B。

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
- 旧三维窗口：[`2026-07-11-3d-lod-sliding-window.md`](../../90-obsolete/voxel-far-field/2026-07-11-3d-lod-sliding-window.md)
