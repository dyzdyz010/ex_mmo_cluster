# Voxia Gameplay 旧渲染器与性能证据归档

> 归档日期：2026-07-19。以下内容从现役客户端的 `Source/Voxia/Gameplay/README.md` 迁出。
> 它只用于源码考古、历史性能对照和旧 artifact 定位，不构成当前设计、兼容运行时、
> CI 门禁或生产验收入口。现役口径以 `clients/Voxia/Source/Voxia/Gameplay/README.md` 与
> `docs/00-current-truth/` 为准；旧 XZ/VHI/heightmap/SVO/raymarch 路径不得恢复为生产路径。

### 已归档的 XZ 远景预览

`L_WorldGenVhiPreview`、VHI、heightmap、underlap/sink 与对应 launcher 是旧 XZ
实验的历史证据。它们不得再作为可启动 preview 或 production renderer；旧参数到达 live
bootstrap 时必须显式失败 `unsupported_legacy_contract`。需要回看旧性能或画面时只读归档
产物，不得把旧预览成功当成纯 3D far shell 验收。

`-VoxiaVhiPreview` is also an explicit composition selector for the legacy VHI
probe, so this dedicated script does not enter the canonical all-features root.
The same rule applies to `-VoxiaSvoPreview` and the zero-argument SVO preview
map. Probe evidence cannot be used as root-level milestone evidence.

Near voxel rendering incrementally maintains one reusable procedural-mesh
component per rendered confirmed chunk in the current active tile window;
the root `Mesh` is only a parent and no longer owns one global section table.
Updating one chunk therefore rebuilds only that chunk's scene proxy, and retired
components enter a bounded pool (`VoxiaNearMeshFreeComponentLimit=256`). Defaults are
`VoxiaNearMeshBuildBudgetMs=4` and `VoxiaNearMeshBuildMaxChunks=512`; the builder
skips compact empty chunks and fully occluded uniform-solid chunks. It filters
input chunks to the active near window before meshing, so stale chunks that are
still waiting for transport cleanup cannot render. Chunks that have not been
processed by the near mesh are built first, so a sliding tile window shows the
newly entered slab before it spends work revalidating retained chunks. During
local WorldGen tile-window streaming, voxel revision bumps extend the current
near mesh queue instead of restarting it; if no build is active, the catch-up
build only queues unprocessed chunks. When the whole window settles, a distinct
non-coalescible revision performs a complete small-budget revalidation so chunks
meshed before their neighbours arrived cannot leave stale boundary faces. The
streaming and settled paths cap the game-thread budget with
`VoxiaNearMeshStreamingBudgetMs=0.5` and `VoxiaNearMeshStreamingMaxChunks=32`.
流式 catch-up 与 settled revalidation 不论来自 WorldGen、正式服务器 voxel delta 或
field-only revision，都统一用
`VoxiaNearMeshStreamingMaxVisibleMutationsPerFrame=1` 限制真实可见变化，默认每帧只允许
一个 chunk 的 `create`、`replace` 或 `clear`；旧的
`VoxiaNearMeshStreamingMaxNewRenderableChunksPerFrame` 只保留为兼容参数名。settled
revalidation 不再清空整窗呈现账本，而是比较当前 chunk 的局部 field content revision
以及自身和六个相邻 chunk 的 render-content 指纹；依赖未变化时直接复用原呈现决策，
不消耗可见 mutation 预算。`near_mesh.publish_budget` 暴露 build kind、预算值、最近一帧
processed/visible mutations、三类累计数、指纹复用数、整窗账本重置数与预算违例帧；
`material_profile` 暴露 clean UV 与 far-unlit override。near mesh 始终消费完整
`FVoxiaNearVoxelWindow`，不得配置独立 vertical render radius。任何深层 chunk 是否
为空/遮挡只能由 confirmed content 与 mesh 判定得出，不能用有限 Y band 从 coverage 中
删除。旧 `VoxiaNearMeshVerticalChunkRadius` 参数属于不支持的旧契约。

The pending queue and presentation-ready ledger are independent. Queue refreshes
only deduplicate against the unconsumed suffix, so a chunk that leaves and later
re-enters the active window cannot be blocked by a historical processed prefix.
Empty and fully occluded chunks are presentation-ready decisions too; missing or
out-of-coverage chunks revoke readiness。Y 方向移动与 X/Z 使用同一三维 window diff；不再
存在 finite WorldGen vertical render band 或按 column 补洞的特殊路径。

online 与 WorldGen 的 near-window recenter 共用完整 XYZ 预测预取状态机。Pawn 根据
canonical 三维位置/速度和 `VoxiaNearPrefetchLookaheadSeconds=12` 选择最先到达的
X/Y/Z tile 边界；并列轴合并为 edge/corner 目标。单轴目标请求 9 tiles / 3087 chunks
的 entering slab；低于
`VoxiaNearPrefetchMinSpeedCmPerSecond=100` 时不预取。Transport 先以 scene、XYZ target、
source、content/hash 与 failure epoch 组成的完整 key 维护
`pending / ready / superseded`，WorldGen 内部再分离
`active / loading / ready_to_activate / cleanup`：预取 chunk 可以提前进入
store，但 near mesh、编辑 gate 与 Interest near region 始终只读 active window。
speculative 预取使用跨 target 的 `2.5s` 全局 attempt 冷却；旧的
`LastNearPrefetchTile` 永久去重状态已删除。Pawn 记录每次 attempt（包括 Transport 仍在冷却时的拒绝），
并分别缓存 speculative 与 required 的完整 exhausted-key fingerprint；同一 exhausted key
不再周期性撞 Transport，content/hash/failure epoch 或 target 改变后自动解锁。Transport
负责 pending/ready 复用、per-key 失败账本、双 intent 有界重启和结构化耗尽拒绝；预取预算
即使耗尽，也不能阻止真实跨界的 required activation 使用一次独立、有限的接管预算。
旧 speculative token 只有在同一完整 key 确认 ready 后才清除；若 required 最终也耗尽，
speculative 同样收到 `Exhausted`，不会退化为周期性低优先级拒绝。
一次 speculative 成功不会提前清除 Transport 的跨 target 冷却，因此高速预测也不能在
`2.5s` 窗口内连续启动多个不同 target。pack/WorldGen 航班默认最多占用逻辑 worker `30s`；
超时后只撤销匹配 ticket/serial，并隔离迟到结果，使真实跨界的 required activation 最终
能够接管，而不是永久卡在已经 supersede 的预取任务后面。跨 PIE/GameInstance 生命周期
复用的进程级共享物理账本最多容纳两个尚未
真实返回的任务：一个 slot 可被悬挂预取占用、另一个留给 required；两者都挂住后显式熔断，
不再启动新任务，迟到返回才自动恢复容量。
玩家跨界时只追加 activation intent；目标整窗 ready 后才切 active，再按
`VoxiaNearWindowUnloadMaxChunksPerTick` 清理旧 slab。
online 的 60 秒 lease renewal 和同 tile 缺块重试只重发 active window + filtered known，
绝不调用 baseline prepare；tile 内移动不重订阅。`terrain_baseline.near_window_prepare`
暴露 source、target、serial、pending/ready、superseded count，`near_window_prepare_passes`
和 `near_window_lease_renewals` 可直接证明续租没有触发 baseline reload；
`terrain_baseline.near_window_pack_prepare` 进一步暴露 online `.vxpack` 单航班 worker、
容量 1 completion mailbox、stale/failure/timeout、worker age/timeout、late-result policy 与
GameThread missing-only merge 计数；`terrain_baseline.tile_window_stream` 继续暴露 WorldGen
activation/cleanup 及 worker timeout 隔离状态；两处都暴露 shared physical in-flight、
abandoned、limit 与 fuse 状态；
`near_prefetch ...` 是无 GUI 测试入口。

### 性能证据的适用范围

2026-07-11 同规格 1600x900、`t.MaxFPS=0`、`r.VSync=0`、near-only Real-RHI
两次干净复测中，9261 chunks 数据 ready=`1779.9-1862.4ms`，最终几何均稳定为
`855 sections / 78451 quads`。从首帧到完整 near mesh 收敛的样本均值
`131.230-135.272 FPS`，p95=`9.907-10.208ms`；随后 10 秒稳态均值
`136.012-138.634 FPS`，p95=`9.743-9.969ms`，没有帧超过 16.67ms。相邻
3087-chunk slab 预取=`429.7ms`，跨界后复用 `256` 个组件；跨界窗口平均
`134.279 FPS`，p95/p99/max=`10.211/11.545/15.257ms`，同样没有
`>16.67ms` 帧。
这证明均值已超过 120 FPS，但不能表述为所有帧都锁在 120 以上；加载期仍有
极少数首次资源提交尖峰，跨 tile SVO patch/DynamicMesh 也是独立待优化项。

以下 near+far 数据来自已经归档的 XZ SVO renderer，只能作为迁移前历史基线。同日曾在
`L_WorldGenSvoPreview` 世界中同时启用 confirmed near mesh、72-tile 半径 SVO、
默认 `PartitionedDynamicMesh`、Lumen、Ultra Dynamic Sky 与硬件光追，严格不传
任何 raymarch 参数。首窗 9261 chunks data ready=`2778.2ms`，near mesh 最终仍为
`855 sections / 78451 quads`；远景在 `9157.1ms` 内构建 21016 macro-cells、
1329713 quads，估算可见距离 `8064m`、`seam_status=pass`，361 个 patch 在
`3504.9ms` 内完成上传，日志明确为 `raymarch_mode=none`。完整环境收敛后的 12 个
连续 FPS 日志样本平均 `106.0`、范围 `98.3-109.9`，没有达到综合 120 FPS 目标；
首次 361-patch 上传出现 `113.69ms / 8.8 FPS` 尖峰，相邻 tile 的 82-patch 增量
上传仍出现 `30.15ms / 33.2 FPS`。这些数字不证明纯 3D far shell、跨 LOD seam 或
production source materialization。新的综合性能结论只能来自完整 XYZ near + 纯 3D
far live 场景。

每个新 near chunk 的独立 component 在 `PublishNearMeshChunkSections` 完成时立即可见，
`VoxiaNearMeshProgressivePublishMs=200` / `VoxiaNearMeshProgressivePublishChunks=64`
只控制 revision/progress ledger 的推进和日志节流，不是批量 reveal 开关。相邻 handoff
期间的新可见 chunk 另受上述每帧预算约束；unchanged chunks 保留已有 section，不会在
progressive publish 前被清空。Exited chunks 随 transport unload batch 按各自坐标移除。
`near_mesh` / `snapshot` 暴露 `live_sections`、`live_quads` 与 `rendered_chunks`，
用于验证新窗口流送期间 retained near 仍驻留。初次 near 尚未可见时不得启用旧
heightmap/VHI fallback 填洞；production far shell 若未完整 ready，状态必须显式保持
unavailable。

far recenter presentation 消费显式 XYZ near-readiness contract。单轴相邻移动的 entering
集合是 9 tiles / 3087 chunks，而不是旧 XZ column 口径的 3 tiles / 1029 chunks。
`near_mesh.legacy_svo_handoff` 仅为归档字段，暴露旧 deferred/revision/target center 与
required/ready/pending counts；现役交接以 `publish_budget.chunk_transaction` 与
`far_presentation` 为准。
far candidate generation 只有整体准备并原子晋升 live 后，才允许对应退出侧 chunk
transaction 逐个揭开；初次 cold generation 也不得绕过 source 完整性与身份 gate。

当前 near/presentation 组合根完成了双向呈现所有权交接。进入集合按
near chunk 的真实 submitted epoch 在 N+1 更新 XYZ ownership mask；退出集合先进入
`FVoxiaNearRetirementRegistry`，按完整三维 tile 合并为少量只读 draw batch。batch 的
`FDynamicMesh3` 在 ThreadPool 构建，GameThread 只提交组件；原 near chunk 组件保持
注册但隐藏，因此相同版本折返时可立即恢复。matching far revision live-visible 后，
退场不再按 tile/batch 一次揭开：先恢复逐 chunk source，默认按
`VoxiaNearRetirementReleaseMaxChunksPerFrame=1` 在帧 N 解除对应 far ownership mask，
至少到 N+1 才清该 near chunk 与租约，全部完成后才释放整窗 ownership。排队释放项同时
绑定 far revision、`LeaseId` 与 `Generation`，折返或 rebase 后的陈旧工作不能清掉新租约。
退休块重新进入 active window 时还必须匹配冻结时的完整 presentation fingerprint（自身与六
邻居 render-content identity 加自身 field identity）；wire chunk version 相同但邻块、权威修正
或 field 已变化时必须重建，不能把旧 mesh 盖上新指纹后永久复用。
上述每一步必须是完整 chunk handoff transaction，而不是分别提交 component、mask 或
fence。tile 合批只压缩 draw call，不是退场粒度；近远景内部细分不同也不改变 ownership 的逐
chunk 裁剪与释放契约。该合批不改变 active near 的逐 chunk 加载粒度、confirmed truth、
编辑/碰撞或 3.5m collar 的 LOD 粒度。

ownership R8 atlas 只上传脏矩形，材质绑定只在 texture、mask generation 或受影响
patch 集变化时刷新；常用相邻盒应在首个纯 3D far generation live 后预热，避免首次移动
创建纹理。
`near_mesh.legacy_svo_handoff.ownership` 仅为归档证据，暴露旧 upload region/bytes/count、texture/material timing、
prewarm、pinned rebase 与 discontinuity；`retirement` 暴露 batch/source component、
snapshot/worker/submit timing、restore 计数，以及逐 chunk release protection、pending、
far reveal/near clear 与累计完成/跳过计数。最终 1600×900、完整 8km near+far
相邻移动为 `136.982 FPS`，20 秒 frame p50/p95/p99/max 为
`7.250/8.148/8.644/16.569ms`，没有 `>16.67ms` 帧；三次 250ms 间隔快速移动为
`136.213 FPS`、最低采样 `129.108 FPS`，最终 near/SVO revision 自动收敛；快速折返
恢复 3 个 batch、266 个 chunk，`batch_restores_total=3`。这些是完整场景证据，不由
near-only profile 外推，但它使用旧 XZ far renderer，现只保留为 handoff 性能历史证据，
不得作为纯 3D production 验收。

## 已归档的 XZ SVO / raymarch 记录

以下段落只用于定位迁移前 artifact、日志和旧算法，不再提供可执行入口。旧
`L_WorldGenSvoPreview`、WorldGen SVO、v1 column source-pages 与 raymarch 不得由默认地图、
launcher 或命令行启动；传入旧参数应显式返回 `unsupported_legacy_contract`。

历史实验曾使用独立地图：

```text
/Game/Voxia/Maps/L_WorldGenSvoPreview
```

旧地图、创建脚本与 `launch_worldgen_svo_preview.js` 仅作为源码考古索引，不得运行。
历史 cold build、patch 数和 8km 截图也不得作为当前 far ready 证据。

历史脚本曾添加 `-VoxiaSvoPreview`。以下英文说明中的 default/current/live 均指归档版本，
不代表现役入口：The near field remains the complete
3x3x3 tile voxel window and is described by `FVoxiaNearVoxelWindow`; the far
field reads that contract and builds a visual-only SVO macro-cell mesh proxy
outside it. SVO artifact generation is off-thread and coalesces in-flight
center/config changes before publishing a new `svo_revision`, so crossing a
tile no longer has to synchronously rebuild the full +/-8 km proxy on the game
thread. `svo` / `snapshot` expose `source_kind`, `source_complete`,
`expected_source_chunk_count`, `present_source_chunk_count`,
`missing_source_chunk_count`, and `build_error`. The default source is
deterministic WorldGen; adding `-VoxiaSvoConfirmedSource` makes the builder read
the current confirmed `FVoxiaVoxelStore` snapshot. In local WorldGen preview,
the transport can pre-load missing confirmed-source chunks up to
`-VoxiaSvoConfirmedSourceMaxChunks`; requests above that budget are rejected
with a diagnostic SVO snapshot instead of bulk materializing millions of chunks.
Incomplete source coverage never falls back to WorldGen or implicit air.
SVO upload keeps live patch sections by mesh fingerprint; moving one tile only
uploads changed patches and leaves unchanged sections in place. Removed patches
are staged while replacement patches upload and are committed only after
`MarkUploadFinished`, so a coverage identity flip cannot clear the visible far
set before its replacement exists.
The default mesh runtime also consumes macro-cell artifact views through the
persistent compact patch cache: it no longer concatenates a full aggregate mesh,
only rebuilds patches touched by dirty/new/removed cells, and runs a bounded
dirty-boundary seam check. Full aggregate/full seam remains available through
`-VoxiaSvoFullAggregateValidation`. `runtime_resource_ready=false` is expected
for the default partitioned mesh path. The current route strictly forbids
raymarch execution; the remaining raymarch flags and sections below are
historical diagnostics only, not supported validation commands.
历史 SVO preview 曾注册为客户端 `far_svo` layer：
Interest runtime: it remains low-frequency visual map sync by default, and a
remote interaction must create a `focus` region that hydrates confirmed data
before becoming interactive.
`VoxiaWorldActor` now consumes Interest coverage for heightmap LOD / VHI / SVO
far proxies: when interactive focus coverage changes, the relevant far visual
patches are re-evaluated and upload paths filter focus-covered quads, tiles, or
macro-cells out of the low-fidelity proxy. Logs expose `suppressed_quads`,
`suppressed_tiles`, `suppressed_macro_cells`, and `suppression_serial` for CLI
regression checks.
`-VoxiaSvoRenderBackend=HISM` switches the SVO far-field visual upload to the
first real `UHierarchicalInstancedStaticMeshComponent` backend. It converts each
patch quad into one plane instance, records HISM render artifacts through the
same uploader, and remains a specialized profile rather than the generic
default.
历史 mesh 实验对 WorldGen、confirmed-store 与 source-pages 使用 partitioned
`UDynamicMeshComponent` + `StaticDraw`。Its mesh builder restores
the same primary UV mapping as the near ProcMesh path, uses component-level
flat shading without a resident normal overlay, and shares the terrain component
descriptor (including CastShadow) with near rendering. The fade material is
derived from `M_VoxelVertexColor`, preserves the same texture chain, and uses a
frame-stable screen-space mask instead of `DitherTemporalAA`.
`-VoxiaSvoRenderBackend=RuntimeMesh` (or `DynamicMesh`) switches SVO far-field
visual upload to the UE built-in `UDynamicMeshComponent` backend. It rebuilds one
`FDynamicMesh3` from the live SVO patch set, records RuntimeMesh render artifacts
through the same uploader, and logs `runtime_mesh_vertices` /
`runtime_mesh_triangles` for smoke verification. `-VoxiaSvoSourcePages` now uses
this single-component debug backend explicitly; it is no longer the default.
Use `-VoxiaSvoRenderBackend=ProcMesh` (or `ProceduralMesh`) to force the old
debug baseline. This is a runtime visual backend only; it is not a Nanite bake,
Lumen distance-field path, collision path, edit truth source, or H-gate input.
The builder also emits a CPU SVDAG artifact summary (`svdag_node_count`,
`svdag_unique_node_count`, `svdag_merged_node_count`,
`svdag_compression_ratio`) from the same occupancy tree, as a data-side step
toward a future GPU resource. The first runtime-resource data plane is also
available in `svo` / `snapshot` as `runtime_resource_ready`,
`runtime_root_count`, `runtime_node_count`, `runtime_child_ref_count`,
`runtime_gpu_bytes`, `runtime_node_word_count`, `runtime_root_word_count`,
`runtime_payload_bytes`, and `runtime_compression_ratio`. `AVoxiaWorldActor`
now wraps that fixed-stride payload in render-thread ByteAddress buffers and
logs `rhi_ready` / `rhi_bytes` on SVO queued/streamed events.
The same snapshot also reports `presentation_revision`,
`presentation_consumed`, `upload_complete`, and `upload_queue`, so CLI smoke
can distinguish "SVO data was built" from "the current SVO revision was
consumed and fully uploaded by the renderer".
`FVoxiaSvoRaymarchCS` can consume those SRVs, bind a dispatch output UAV, submit
the default 1x1 global shader dispatch under a real RHI, and optionally run a
bounded preview grid readback with `-VoxiaSvoRaymarchPreviewGrid=N` (`N` is
clamped to 16). The queued log and `svo` snapshot now also expose
`raymarch_mode`, `raymarch_dispatched`, `raymarch_groups` / `raymarch_grid`,
`raymarch_samples`, `raymarch_readback`, `raymarch_visual_pixels`,
`raymarch_nodes`, `raymarch_roots`, `raymarch_hit_samples`,
`raymarch_miss_samples`, and `raymarch_invalid_samples`. The preview grid
readback is converted into a CPU-visible color buffer, so it can be used as the
first visual integration surface. Adding `-VoxiaSvoRaymarchWorldSpace` also
applies the world-space camera-ray parameters to preview-grid / screen-probe
dispatches and exposes `raymarch_world_space`, `raymarch_root_lookup`, and
`raymarch_root_lookup_grid` in `svo` / `snapshot`. `-VoxiaSvoRaymarchScreenProbe`
reuses the same debug path with a viewport-derived output buffer bounded by
divisor/pixel budget and reports `raymarch_mode=screen_probe`. This is still a
GPU-side observability probe. `-VoxiaSvoRaymarchComposite` registers a debug-gated
`FWorldSceneViewExtension` on the Tonemap post-process pass and logs the first
pass plus the first pass that sees non-zero SVO runtime nodes. It now writes a
new SceneColor through a global pixel shader that selects roots through a
screen atlas, traverses the SVO root/node ByteAddress payload top-down to the
first non-empty leaf, and blends material color with hit-depth attenuation over
the current scene. The composite pass binds scene textures and, by default,
samples scene depth before writing each hit; `-VoxiaSvoRaymarchNoDepthOcclusion`
keeps the old always-overdraw debug path, while
`-VoxiaSvoRaymarchDepthBias=`, `-VoxiaSvoRaymarchNearDeviceDepth=`, and
`-VoxiaSvoRaymarchFarDeviceDepth=` tune the debug depth mapping. The
preview-grid readback uses the same traversal helper and packs fixed hit/miss
words for automation. Adding `-VoxiaSvoRaymarchWorldSpace` switches the debug
composite traversal from root-atlas UV selection to a first camera-ray path: the
post-process pass uploads the current view origin/axes/FOV in SVO macro space,
and the shader now prefers an uploaded root lookup grid plus XZ DDA before
reusing the same top-down leaf traversal. `-VoxiaSvoRaymarchNoRootLookup`
forces the older bounded root-AABB scan, capped by
`-VoxiaSvoRaymarchWorldRootScanLimit=N`, for comparison. This is still an
opt-in debug path and intentionally bounded; it is not yet the final production
renderer. Composite stats are now fed back into the same `svo` / `snapshot`
metrics: `raymarch_composite_pass_observed`,
`raymarch_composite_scene_color_written`, `raymarch_composite_output`,
`raymarch_composite_nodes`, and the composite depth/world/root-lookup flags
make the screen-pass write path directly waitable from CLI.
历史实现曾验证独立关卡、8km WorldGen coverage、
confirmed-store source boundary/preflight, upload-level section reuse, SVDAG
statistics, seam diagnostics, and CLI observability with `svo` / `until_svo`;
render-readiness smoke should use `until_svo_uploaded` so the current revision
has `presentation_consumed=true`, `upload_complete=true`, and `upload_queue=0`.
Screen-pass smoke should then use `until_svo_composited` so the debug-gated
raymarch composite has observed a post-process pass and written SceneColor.
For screen-output proof, append the stdio helper's
`capture_screenshot <file> [timeout_ms] [show_ui]` and
`audit_png <file> [min_unique_colors] [min_non_black_ratio]` steps. The current
8km overview smoke uses `show_ui=0` after a high camera teleport/look-at and
writes `Saved/voxia_svo_8km_overview.png`; the audit records a 1423x889 PNG,
`non_black_ratio=0.578711`, and `unique_colors=51970`.
The composited pass is still a debug-gated client visualization. The default
mode remains root-atlas screen mapping with parameterized SVO device depth; the
world-space mode now has a root-lookup DDA acceleration slice, but is still not
part of collision, editing, raycast, production protocol, or H-gate validation.
Do not execute these historical raymarch readback commands in current validation.
The last explicit Real-RHI probe completed readback and then reproduced the
D3D12 3D/Compute queue timeout that caused the route to be disabled.
`render_perf` and the helper step
`sample_render_perf [duration_ms] [interval_ms] [min_average_fps] [min_samples]`
provide structured stable-frame evidence once the target SVO revision has
finished upload/composite。历史 8km overview perf smoke 曾等待 revision 2
after the high-camera teleport and records `sample_count=10`,
`average_fps=69.014`, `min_fps=42.790`, `max_frame_ms=23.370`, and
`passed=true`; the final `render_perf` sample reports `average_fps=85.843` at
viewport 1423x889.
Historically, ultra-large raymarch validation used `-VoxiaSvoRaymarchOnly` /
`-VoxiaSvoSkipProxyMesh` keeps the runtime SVDAG GPU payload and composite pass
but skipped the traditional SVO proxy mesh upload。这是已禁用且不再受支持的历史
large-terrain renderer profile；ProcMesh/HISM/RuntimeMesh 当时仅是 debug proxy backend。
归档的 max-radius real-RHI smoke 把请求 radius 108 clamp 到
radius 96 (about 10.752 km), records `macro_cell_count=37240`,
`quad_count=4779271`, `runtime_payload_bytes=9322308`, `upload_queue=0`, and
`raymarch_composite_scene_color_written=true`, and passes `sample_render_perf`
with `average_fps=120.807`. The screenshot audit for
`Saved/voxia_svo_max_raymarch_overview.png` records `non_black_ratio=0.875069`,
`unique_colors=3390`, and `passed=true`.
历史 cross-tile 8km real-RHI smoke 使用 `move 12000 0 0`，随后等待
`until_svo_uploaded 240000 1000 2` and
`until_svo_composited 240000 1000 2`; the final `svo` snapshot records
`revision=2`, `center_tile=[12,0,-51]`, `reused_macro_cell_count=20760`,
`cache_hit_rate=0.988`, `upload_queue=0`, and
`raymarch_composite_scene_color_written=true`.
The current compatibility-mesh 8km smoke profile uses `-VoxiaSvoTileRadius=72`,
`-VoxiaSvoNearSkipRadius=1`, `-VoxiaSvoMacroCellTiles=1`,
`-VoxiaSvoLodRings=3.5@4,7@8,14@24,28@40,56@72`, and `-VoxiaSvoTargetFps=120`;
if the lod-rings flag is omitted, the runtime default is the same five-ring
tier table. The legacy `-VoxiaSvoSamples` /
`-VoxiaSvoNearLodRing` / `-VoxiaSvoMidLodRing` flags are removed and rejected
with an explicit diagnostic; malformed ring specs are rejected without fallback.

HUD work uses an isolated duplicate level:

```text
/Game/Voxia/HUD/L_HUD_Test
```

Recreate it from the ThirdPerson level when needed:

```powershell
& "D:\UE\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" `
  ".\Voxia.uproject" `
  -ExecutePythonScript=".\scripts\create_hud_test_level.py" `
  -unattended -nop4 -nosplash
```

Run a local HUD smoke without server dependencies:

```powershell
& "D:\UE\UE_5.8\Engine\Binaries\Win64\UnrealEditor.exe" `
  ".\Voxia.uproject" `
  /Game/Voxia/HUD/L_HUD_Test?game=/Script/Voxia.VoxiaClientGameMode `
  -game -windowed -resx=1280 -resy=720 -nosplash -nop4 -nosound
```

Expected log evidence:

```text
VoxiaHUDWidget: constructed UMG HUD from layered HUD_Assets
```
