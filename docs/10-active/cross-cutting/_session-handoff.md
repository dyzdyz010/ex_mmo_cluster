# Voxel server authority — 会话间衔接备忘

## 2026-07-11 Voxia 近景冷加载与帧尖峰优化检查点

> **当前决策：raymarch 严格不用。** 不要运行任何 `VoxiaSvoRaymarch*` 参数，不把 L4/raymarch 重新列为候选。默认分组件 DynamicMesh mesh 路径是唯一继续路线。

### 本轮同步与完成范围

- umbrella 本轮从 `4138acb` 继续更新 current truth；独立 Voxia 性能改动已发布为 `482d21c perf(streaming): accelerate near-window loading`，本文件与阶段文档随本次 umbrella 发布同步收口。
- Transport 的 WorldGen preview 由“单批生成、等待队列清空、固定 reveal 延时”改为单 producer 的连续生成/应用流水线；默认 batch/high-water/reveal 为 `256/512/0`，请求级 column cache 复用相同 X/Z 的高度计算，并输出 generate/apply/queue/cache/throughput 指标。旧 active coverage 仍保持到 staged window ready，未降低 H gate 或 confirmed truth 边界。
- `FVoxiaVoxelStore` 对整块同材质实心快照使用紧凑基底 + empty/solid/refined 稀疏例外；delta 与权威纠正直接维护例外，不再把 9261 chunks 展开成约 1700 万个 `TMap` cell。
- near renderer 从单一 ProcMesh 的全局 section 表改为每 chunk 独立可复用组件；既有 chunk 原位更新，最终 settled revision 以 `0.5ms` 预算重校验。Transport pump、near upload 与 SVO upload 均保证每帧最多一次。
- SVO reuse context 共享写时复制 macro-cell artifact store，不再在 GameThread 深拷贝约 121MB 几何；observe JSONL 改为 8 MiB/4096 行有界专用 writer，模块退出前无条件 join；CLI 新增 `frame_perf [snapshot|reset]`，报告 p50/p95/p99/max 与 `>8.33/16.67/33.33/50ms` 计数。
- 安全/架构终审补齐 `macro_index` 0..4095 的 decoder/store 双层硬拒绝、snapshot `chunk_size=16` 与累计 4096 headers 上限；公开 `Pump()` 保持每次显式推进，只有 Subsystem/Pawn/CLI 自动入口使用 `PumpOncePerFrame`。

### raymarch 现场

- 2026-07-10 显式 real-RHI 小网格诊断完成 dispatch/readback（16/16 visual samples、root lookup 成功、invalid=0）后，D3D12 3D 与 Compute 队列均超时，CLI 挂住；已终止残留 UE 进程，GPU 恢复正常。
- 这复现了既有 raymarch dispatch × proxy-mesh go-live 跨队列竞态，不是本轮 patch 聚合优化引入的回归。用户已拍板严格不用，因此没有继续做 raymarch 复测，也不应在新电脑恢复后复测。

### 最新真实 RHI 证据

- 固定口径：1600×900、`t.MaxFPS=0`、`r.VSync=0`、near-only、默认 mesh renderer；最终进程正常退出，未出现 device removal。
- 优化前：9261 chunks data ready=`28423.7ms`；3087 candidates → 855 sections / 78451 quads 完成=`35400.4ms`；加载尾段约 14–19 FPS。
- 优化后两次干净复测：data ready=`1779.9-1862.4ms`，约 `15.3-16.0x`；最终几何均为 855 sections / 78451 quads。最终一轮生成/apply 总计 `320.74/174.80ms`，queue high-water=`501`，column cache=`441`，stale=`0`。
- 从 reset 到完整 near mesh：平均 `131.230-135.272 FPS`，p95=`9.907-10.208ms`，`>16.67ms=4`。收敛后 10 秒：平均 `136.012-138.634 FPS`，p95=`9.743-9.969ms`，`>16.67ms=0`。
- 相邻 slab 预取=`429.7ms`；激活后 pruned=`3087`、components reused=`256`，最终中心 `[12,0,-51]`、898 sections / 82454 quads。跨界窗口平均 `134.279 FPS`，p95/p99/max=`10.211/11.545/15.257ms`，没有 `>16.67ms` 帧。
- 结论必须保持精确：平均与稳态已超过 120 FPS，但并非每一帧都在 8.33ms 内；冷加载仍有约 64ms 单次极值，p95 仍约 10ms。

### 下一步

1. 用 Unreal Insights/CSV 复现并定位 near-only 的约 `64ms` 单次极值；当前干净复测 near mesh max tick/single-chunk 仅为 `6.823/6.352ms`，不得先验归因给 near mesh 或未启用的 SVO。
2. 在完整 near+far 跨 tile profile 中，把仍约 `72.751ms` 的 SVO compact patch 聚合同步等待与 DynamicMesh CPU build 真正移出 GameThread，只保留 bounded component submit。
3. near/collar center 继续精确跟随玩家，outer coverage center 独立增加 hysteresis，减少跨 tile 大规模 ring reassignment。
4. 用同一 `frame_perf` 口径做连续移动、跨 tile 和低端硬件矩阵；目标从“平均 120+”收紧到 p95≤8.33ms，并持续单列极值和超预算帧。
5. 生产首次入场仍应由 launcher/offline 生成 validated sharded artifact pack，H gate 后批量 hydrate；不得把 dev-only WorldGen 数据当生产已完成。

阶段全文见 [`phase-far-temporal-stability-and-seamless-streaming.md`](../voxel-far-field/phase-far-temporal-stability-and-seamless-streaming.md)，客户端根因记录见 `clients/Voxia/docs/engineering-notes/2026-07-10-svo-mesh-path-hidden-full-rebuilds.md`。

**Last updated**：2026-07-11（Voxia 近景冷加载热路径、帧时间分布与真实 RHI 收口）。
> ⚠️ 以上 2026-07-11 小节是当前接力入口；下方历史正文停在 2026-07-06。2026-07-07/08 的 VLOD-A1~A4 远景渲染里程碑进展（含 A3.0 device-removal 归因反转、A3b merge 收官、A4 收尾）见 [`voxel-server-authority-phase-overview.md`](voxel-server-authority-phase-overview.md) 与 `../voxel-far-field/phase-vlod-*.md`；当前事实见 [`streaming-lod.md`](../../00-current-truth/design/client/streaming-lod.md)。

旧 A4-bis 接力记录保留在下方；接手 Voxia 近场窗口、SVO 远景路线或客户端 near/far/focus 架构时，先看上述最新稿与 [`00-current-truth/design/client/streaming-lod.md`](../../00-current-truth/design/client/streaming-lod.md)。

## 2026-07-06 LOD 分层设计 / GPT-5.5 方案评审检查点

- 本轮为设计/评审轮，**未改任何代码**。产出两份新文档：
  - [`2026-07-06-gpt55-lod23-proposal-review.md`](../../20-archive/voxel-far-field/2026-07-06-gpt55-lod23-proposal-review.md)：对 `docs/design/` 两份外部 GPT-5.5 方案（LOD2/LOD3 架构 + LOD0-3 完整计划）的对抗评审。核心裁决：**数据源维持 source pages 主线**，GPT 的"客户端 worldgen mip 为主"在 S4 仲裁（parity 未绿禁本地推导）+ 客户端 WorldGen 已故意 3D 分歧 + 3D 内容归 delta（W-Q6=A）+ authored 未来四重约束下拒绝，重启需五个可判定条件全满足；16 条采纳矩阵（净增量 TOP-5：分带失效过滤、Event Overlay 模式、greedy meshing、自研 SceneProxy 终点、远环大容器）；UE 5.8 源码实证（`D:\UE\UE_5.8`）：Nanite 运行时构建 API 级不可行、WP HLOD 对纯运行时世界输入为空集、`UDynamicMeshComponent` 有 StaticDraw/分块更新白送杠杆。
  - [`2026-07-06-voxia-lod-layering-and-technology-design.md`](../../30-reference/overview/2026-07-06-voxia-lod-layering-and-technology-design.md)（v2.2，**待拍板**）：07-05 路线下游细化。分带 L0(1m)/L1(7m,d2-8)/L2(14m,d9-24)/L2.5(28m,d25-40,T-2 可拍掉回三环)/L3(56m,d41-72)/L4(raymarch profile)/天空；page payload=7m occupancy+material mip（any-solid+众数规约，T-4）；分带失效契约 T-7（流式重派生定位、按编辑类型命中率、最终一致性上界）；T-11 分发通道（wire 失效通知+HTTP 拉 payload）；垂直稀疏多层+3D 环距+near-skip 3D 化；**三列里程碑：A 客户端渲染正确（零服务端依赖，切分级/分组件+StaticDraw/greedy merge/seam-fade-collar）→ B 接口冻结+fixture 产真页+客户端 pages 真消费管线 → C 服务端接入（dirty 聚合/pages writer/失效 opcode）**。B1 纸面契约冻结不可推迟。
- 设计稿经 1 轮 fable 对抗评审修订（v2）：撤销 min 42.8 FPS 与 RuntimeMesh O(N²) 的错误因果（该实测出自 ProcMesh 且上传完成后采样，真实来源已立案）；补规约算子契约、T-11 分发通道、collar 的 depth clamp 1..4→5 前提、L4 需 pages 覆盖扩 d96、垂直清单需自带 revision、near-skip 3D 化、按带 merge 系数（合计 0.51-0.84M，垂直后 0.66-2.1M 含降级序列）。
- 关键代码事实（评审中核实，接手实现时直接用）：SVO depth clamp 1..4（`VoxiaSvoPreview.cpp:1381`）、LOD 环只有 near/mid 两档 boost +3/+2（`:1363-1382`）、SVO 远景逐 leaf 面 EmitQuad 无 greedy merge（近景 mask 路径已有）、`RefreshSvoRuntimeMesh` 单组件全量重建（`VoxiaWorldActor.cpp:1007-1026,2046-2049`）、source page 现为 dummy 只过 hash gate、**0x6D/0x6E 已被 Tag/AttributeCatalogSnapshot 占用**（远景失效 opcode 需另配）、服务端无区域级 dirty 聚合（只有 per-chunk outbox）、`source_revision`/`diff_chain_hash` 服务端未实现（只在客户端 fixture）、NIF 无 material 函数（C1 唯一残留契约风险）。
- 下一步：用户拍板设计稿 T- 决策项（尤其 T-2 L2.5 去留、T-4 规约算子、T-11 通道）后，从里程碑 A 的 A1（切默认分级 + 显式 tier 契约 + 第三环）开始实现；07-05 路线稿 §10 执行提示词已更新为指向设计稿三列车。

## 2026-07-05 Voxia SVO source pages / artifact 检查点

- 当前路线真值见 `docs/docs/30-reference/overview/2026-07-05-voxia-voxel-lod-production-route.md`：L0 近景继续服务端权威 3x3x3 tiles；L1-L3 远景走 SVO / SVDAG source pages + leaf-surface mesh artifact + FarField patch 上传；raymarch-only 只保留为 L4 或 A/B profile；VHI 冻结为 2.5D baseline。
- 客户端已接 `-VoxiaSvoSourcePages`：读取 `svo_source_pages_v1` manifest，校验 scene/content/source/diff/material/renderer artifact version、page 存在性和 SHA1。失败时只发布诊断，不 fallback 到 WorldGen，不把 missing 当空气。
- 客户端已接持久化 macro-cell mesh artifact cache：cache key 混入 content/source/diff/material 版本、scene、macro-cell/LOD/sample 配置、renderer artifact version 和 source kind；`source_pages` 路径只加载预物化 artifact，缺 artifact 时 `mesh_artifact_ready=false`。
- mesh renderer readiness 已与 raymarch runtime readiness 拆开：`svo` / observe / `client_network_ready.rendering_ready` 暴露 `farfield_source_ready`、`mesh_artifact_ready`、`artifact_cache_ready`、`renderer_backend`；`until_svo_uploaded` 可接受 mesh artifact ready，`until_svo_composited` 仍只代表 raymarch composite。
- 负向 gate 已补 automation：`Voxia.Voxel.SvoPreview` 覆盖缺 manifest、source page hash mismatch、macro-cell artifact missing。缺文件读取前用 `FileExists` 前置判断，避免预期诊断污染 `LogStreaming` warning。
- stdio CLI 已补 `svo_source_pages_probe`：在临时 source_pages fixture 中验证正向加载、缺 manifest、source page hash mismatch、缺 macro-cell artifact 四条路径，返回 `checks.*` 结构化结果并清理临时目录；当前复跑日志为 `clients/Voxia/Saved/svo_source_pages_cli_probe_rootdir.log`，`ok=true`。
- source_pages 生产路径默认 renderer 已切到 RuntimeMesh / `UDynamicMeshComponent`：未显式配置 `-VoxiaSvoRenderBackend=...` 且带 `-VoxiaSvoSourcePages` 或 build result 为 `SourceKind=source_pages` 时选择 RuntimeMesh；WorldGen / confirmed-store 预览路径仍默认 ProcMesh，`-VoxiaSvoRenderBackend=ProcMesh` 可显式回到调试基线。`svo_source_pages_probe` 还会把加载到的 source_pages artifact 拆成 FarField patch 并构建 RuntimeMesh 输入，当前 `runtime_mesh.vertices=3604` / `triangles=1802` / `quads=901`。
- source page manifest 与 payload root 已解耦：显式 `-VoxiaSvoSourcePageRoot=...` 时，manifest 内相对 page path 相对该 root 解析；未配置时回退 manifest 目录。automation 已覆盖 manifest/root 分离和错误 root 缺页硬失败。
- stdio CLI 已补 `svo_source_pages_fixture [tile_x tile_y tile_z] [radius_tiles] [vertical_radius_tiles] [near_skip_radius_tiles]`：生成保留型本地包，分开保存 `manifests/`、`source_pages/`、`artifacts/`，并返回可复用 `launch_args`。`vertical_radius_tiles>0` 会额外写入上下 y 层 page / artifact，并通过 `vertical_checks` 逐层验证同一个 package 在 SVO center y 改变后仍可命中。该命令不读取 live world actor / pawn，避免 stdio 命令线程依赖运行时场景。
- 验证：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding -NoUBA -MaxParallelActions=1` 退出 0；`Automation RunTests Voxia.Voxel.SvoPreview` 退出 0；`node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "svo_source_pages_probe; wait 5000"` 退出 0，最新日志为 `clients/Voxia/Saved/svo_source_pages_cli_probe_multifixture_regression.log`；`node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "svo_source_pages_fixture 11 0 -51 1 1 -1; wait 5000"` 退出 0，日志 `clients/Voxia/Saved/svo_source_pages_fixture_multiy_radius1.log` 记录 `stored_source_page_count=27`、`stored_artifact_count=27`、`vertical_checks.ok=true`、`expected_pages=9`、`artifact_loaded_macro_cells=9`、`quad_count=7435`；y=2 fixture 的真实 RHI 上传 smoke `clients/Voxia/Saved/svo_source_pages_runtime_mesh_y2_upload_smoke.log` 退出 0，记录 `source_kind=source_pages`、`renderer_backend=runtime_mesh`、`source_pages_present=1` / `missing=0`、`quad_count=958`、`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`、`seam_check.status=pass`。
- 3x3x3 source_pages 保留包的真实 RHI RuntimeMesh 上传 smoke 已通过：`clients/Voxia/Saved/svo_source_pages_multiy_radius1_real_rhi_upload_worldgenpreview_retry.log` 退出 0。启动需要带 `-VoxiaWorldGenPreview -VoxiaSvoPreview -VoxiaSvoSourcePages`，并使用 fixture 返回的真实 `source_revision=cli_fixture_source_rev_1` / `diff_chain_hash=cli_fixture_diff_hash_1`。最终 `svo` 为 `center_tile=[11,0,-51]`、`source_pages_expected=9`、`source_pages_present=9`、`source_pages_missing=0`、`artifact_cache_loaded_macro_cells=9`、`quad_count=7435`、`presentation_revision=2`、`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`、`seam_check.status=pass`。
- stdio helper 已补 source_pages 专用等待与两阶段 runner：`until_svo_source_pages_uploaded [timeout_ms] [expected_pages] [min_revision]` 会严格要求 `source_kind=source_pages`、`renderer_backend=runtime_mesh`、页数/hash/artifact readiness、presentation consumed、upload complete、upload queue 归零和 seam pass；`node clients/Voxia/scripts/run_svo_source_pages_fixture_smoke.js` 先生成保留型 fixture，再用返回的 `launch_args` 重启真实 RHI 客户端。当前 runner 日志 `clients/Voxia/Saved/svo_source_pages_fixture_runner_real_rhi.log` 退出 0，记录 `expected_pages=9`、`source_pages_present=9`、`source_pages_missing=0`、`artifact_cache_loaded_macro_cells=9`、`quad_count=7435`、`presentation_revision=2`、`upload_complete=true`、`upload_queue=0`、`seam_check.status=pass`。
- source_pages 保留包移动回归已补：`svo_source_pages_fixture [tile_x tile_y tile_z] [radius_tiles] [vertical_radius_tiles] [near_skip_radius_tiles] [movement_radius_tiles]` 的第 7 参数会预物化邻近 X/Z center 的 source page 与 artifact key 变体。`clients/Voxia/Saved/svo_source_pages_fixture_move_radius1.log` 记录 `stored_source_page_count=75`、`stored_artifact_count=75`、`movement_checks.ok=true`、`checked_centers=27`、`ready_centers=27`。`run_svo_source_pages_fixture_smoke.js` 默认会在重启上传后移动到 +X 相邻 tile；真实 RHI 日志 `clients/Voxia/Saved/svo_source_pages_fixture_runner_move_real_rhi.log` 退出 0，最终 `center_tile=[12,0,-51]`、`revision=4`、`source_pages_present=9`、`source_pages_missing=0`、`artifact_cache_loaded_macro_cells=9`、`quad_count=7606`、`presentation_revision=4`、`upload_complete=true`、`upload_queue=0`、`seam_check.status=pass`。
- source_pages RuntimeMesh focus suppression 回归已补：`svo` / observe 暴露 `suppressed_macro_cells` 与 `suppression_serial`；stdio helper 新增 `until_svo_source_pages_suppressed [timeout_ms] [expected_pages] [min_revision] [min_suppressed]`；`run_svo_source_pages_fixture_smoke.js --focus-suppress --no-move` 会创建 confirmed debug focus 覆盖 fixture tile 并等待 far SVO macro-cell 被裁掉。真实 RHI 日志 `clients/Voxia/Saved/svo_source_pages_fixture_runner_focus_suppression_real_rhi.log` 退出 0，最终 `center_tile=[11,0,-51]`、`revision=2`、`source_pages_present=9`、`source_pages_missing=0`、`artifact_cache_loaded_macro_cells=9`、`suppressed_macro_cells=9`、`suppression_serial=1`、`quad_count=7435`、`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`、`seam_check.status=pass`。该证据只证明低保真 far visual 被裁掉，不把远景提升为 confirmed truth。
- 截图证据：`clients/Voxia/Saved/voxia_svo_sourcepages_runtime_mesh_y2.png` 审计 `unique_colors=6901`、`non_black_ratio=1`、`passed=true`，人工复核可见 voxel side wall。y=0 fixture 在低相机高度切到 y=2 时按预期缺 vertical source page 硬失败，证明 source_pages gate 没有 fallback。
- 仍未完成：launcher/update 或离线工具生成真实生产 source pages 和包内 artifact；服务端 bounded materialization / 远景 source 发布 / delta dirty invalidation；真实 source package 的 launcher/offline 端到端 smoke；更长移动巡航、真实包 focus suppression、长期帧时间与低端预算验证。

## 2026-07-04 Voxia 客户端大地形渲染检查点

- 当前用户口径：先别动服务器，第一个里程碑是客户端超大地形渲染正确。Skeletal/模板角色路径不是本里程碑内容；服务端远景权威源、opcode/AOI 规则、launcher/update 和持久化 artifact 也不在本轮范围内。
- SVO readiness 已从“Transport artifact ready”收紧为“renderer presentation/upload ready”。`UVoxiaTransportSubsystem` 记录 `SvoPresentationRevision`、`bSvoPresentationConsumed`、`bSvoUploadComplete` 和 upload queue depth；`AVoxiaWorldActor` 在消费当前 SVO revision、分帧上传和上传完成时更新该状态；`svo` / `snapshot` 暴露 `presentation_revision`、`presentation_consumed`、`upload_complete`、`upload_queue`。
- CLI 新增 `until_svo_uploaded [timeout_ms] [min_macro_cells]`，要求 `revision>0`、runtime resource ready、macro/quad 非零、seam pass、`presentation_revision == revision`、`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`。旧 `until_svo` 仍只表示 SVO artifact/runtime resource ready。后续又新增 `until_svo_composited [timeout_ms] [min_macro_cells]`，在 uploaded 条件之上要求 debug-gated SVO screen pass 已 observed post-process pass、写回 SceneColor、output 尺寸非零且 runtime node 数非零。
- `client_network_ready.rendering_ready` 现在把 SVO 视觉 ready 绑定到 presentation/upload 状态：SVO 启用时如果当前 revision 未被 renderer 消费或上传队列未清空，会报告 `svo_presentation_not_consumed` 或 `svo_upload_pending`，不会把“数据已生成”误判成“渲染已就绪”。同一 JSON 的 `raymarch.composite` 会报告 `ready/subscribed/pass_observed/scene_color_written/output/nodes/root_lookup`，用于区分 compute preview-grid 和 screen-pass 写回。
- 新增大世界 signed-coordinate SVO regression：`Voxia.Voxel.SvoPreview` 覆盖接近 32km 边界、负 X / 正 Z 的 root lookup 和 root payload signed macro min encoding，避免 world-space/root-lookup 在远离原点时退化。
- 已验证：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding -NoUBA -MaxParallelActions=1` 退出 0；`Automation RunTests Voxia.Voxel.SvoPreview` null RHI 退出 0；`Automation RunTests Voxia.Net.ClientNetworkReadiness` null RHI 退出 0；真实 RHI stdio smoke：
  `node .\clients\Voxia\scripts\voxia_stdio_cli.js --real-rhi --map "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=0" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoRaymarchPreviewGrid=4" --ue-arg "-VoxiaSvoRaymarchWorldSpace" --ue-arg "-VoxiaSvoUploadMaxPatchesPerFrame=128" --ue-arg "-VoxiaSvoUploadBudgetMs=12" --cmd "until_baseline_ready 120000; until_tile_window_full 180000; until_svo_uploaded 240000 1000; client_network_ready; svo; quit"` 退出 0，记录 `macro_cell_count=21016`、`quad_count=3697692`、`runtime_payload_bytes=7282436`、`seam_check.status=pass`、`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`、`raymarch_world_space=true`、`raymarch_root_lookup=true`、`raymarch_invalid_samples=0`、`rendering_ready.ready=true`。
- 新增 screen-pass 验证：同一 8km real-RHI profile 加 `-VoxiaSvoRaymarchComposite -VoxiaSvoRaymarchCompositeAlpha=0.25` 并把命令改为 `until_svo_uploaded ...; until_svo_composited ...; client_network_ready; svo; quit`，退出 0，记录 `raymarch_composite_subscribed=true`、`raymarch_composite_pass_observed=true`、`raymarch_composite_scene_color_written=true`、`raymarch_composite_output=[1423,889]`、`raymarch_composite_nodes=96712`、`raymarch_composite_root_lookup=true`、`rendering_ready.raymarch.composite.ready=true`。
- 新增截图 / 像素审计验证：`UVoxiaDebugCliSubsystem` 新增 `screenshot [path] [show_ui]`，stdio helper 新增 `capture_screenshot` 与 `audit_png`。8km real-RHI overview smoke 在 composite ready 后执行 `fly 1; teleport 123450 -567750 220000; look_at 700000 -900000 20000`，生成 `clients/Voxia/Saved/voxia_svo_8km_overview.png`（1423×889，1303373 bytes），PNG 审计记录 `non_black_ratio=0.578711`、`unique_colors=51970`、`passed=true`。这证明真实 RHI 下已能输出大范围可见地形画面，不只是 Transport/RHI 指标通过。
- 新增移动后渲染稳定性验证：stdio helper 的 `until_svo_uploaded` / `until_svo_composited` 现在支持可选 `min_revision`。跨 tile 8km real-RHI smoke 执行 `move 12000 0 0` 后等待 `until_svo_uploaded 240000 1000 2` 和 `until_svo_composited 240000 1000 2`，最终记录 `revision=2`、`center_tile=[12,0,-51]`、`quad_count=3679821`、`runtime_payload_bytes=7268420`、`presentation_revision=2`、`presentation_consumed=true`、`upload_complete=true`、`upload_queue=0`、`reused_macro_cell_count=20760`、`cache_hit_rate=0.988`、`seam_check.status=pass`、`raymarch_composite_scene_color_written=true`、`rendering_ready.raymarch.composite.ready=true`。
- 新增稳定帧率验证：`UVoxiaDebugCliSubsystem` 新增 `render_perf` / `fps`，stdio helper 新增 `sample_render_perf [duration_ms] [interval_ms] [min_average_fps] [min_samples]`。8km overview perf smoke 在高空视角触发 revision 2 后等待 upload/composite 完成，再运行 `sample_render_perf 10000 1000 30 5`；`clients/Voxia/Saved/svo_8km_perf_smoke.log` 记录 `sample_count=10`、`average_fps=69.014`、`min_fps=42.790`、`max_frame_ms=23.370`、`passed=true`，最终 `render_perf.average_fps=85.843`，且 `client_network_ready.rendering_ready.ready=true` / `svo.upload_complete=true` / `svo.upload_queue=0`。
- 新增最大半径 raymarch-only profile：`AVoxiaWorldActor` 支持 `-VoxiaSvoRaymarchOnly` / `-VoxiaSvoSkipProxyMesh`，在保留 runtime SVDAG GPU payload 与 composite pass 的同时清理并跳过传统 SVO proxy mesh / HISM / RuntimeMesh 上传，避免把数百万 quad debug proxy 的显存压力混进 screen renderer。请求 `-VoxiaSvoTileRadius=108` 当前被 `FVoxiaSvoPreview::MaxRadiusTiles` clamp 到 radius 96（约 10.752km）。`clients/Voxia/Saved/svo_max_raymarch_only_smoke.log` 退出 0，记录 `macro_cell_count=37240`、`quad_count=4779271`、`runtime_payload_bytes=9322308`、`upload_queue=0`、`raymarch_composite_scene_color_written=true`、`rendering_ready.raymarch.composite.ready=true`；`sample_render_perf 10000 1000 30 5` 为 `average_fps=120.807` / `min_fps=96.753` / `max_frame_ms=10.336` / `passed=true`；截图 `clients/Voxia/Saved/voxia_svo_max_raymarch_overview.png` 通过 PNG 审计 `non_black_ratio=0.875069`、`unique_colors=3390`、`passed=true`。UE 原始日志记录 `SVO proxy mesh skipped ... source_quads=4779271 rhi_bytes=9322308`。
- 剩余客户端渲染风险：当前 8km smoke 已证明结构、上传、debug raymarch、真实 RHI 截图/像素审计、稳定帧率采样，以及跨 tile 移动后的 revision 2 composite 链路成立；最大半径 raymarch-only smoke 已证明当前客户端不再需要用传统 proxy mesh 承担超大远景屏幕输出。但这仍不是最终生产 renderer。下一步应继续做 camera-correct world-space screen renderer 稳定化、长期帧时间分布记录，以及后续权威源/launcher/artifact 工程。

## 2026-06-30 Voxia near-window / VHI / SVO checkpoint

- Voxia 客户端提交：`9896917 feat(voxia): integrate near-window VHI SVO streaming`；raymarch composite hook 提交为 `d67f747 feat(voxia): add SVO raymarch composite hook`；SceneColor 写回提交为 `d483e52 feat(voxia): write SVO raymarch composite scene color`。
- `FVoxiaNearVoxelWindow` 已作为当前近场窗口契约落地：输出 `center_tile` / `center_chunk` / `radius_tiles` / `tile_count` / `chunk_count` / 跨 tile diff，并提供兼容 `TileWindowJson`。
- `UVoxiaTransportSubsystem` 的 `active_tile_window` 兼容字段、VHI/SVO 近场排除区、`Snapshot().near_window` 均读同一个 near-window snapshot；旧 active tile window 字段只作为无 near-window 时的 fallback。
- `AVoxiaPawn` 的 debug snapshot、raycast/editable 判定、stream debug overlay 和 `SubscribeAround` 的 last state 回填都改为优先读取 transport near-window。
- VHI 路线已从“整块 8km 重建/上传”改为 tile artifact 复用 + patch section 分帧上传：`coverage_center_tile` 与近场 `center_tile` 分离，跨一个 tile 时只构建 dirty/upsert/remove tile；默认 `VoxiaVhiPatchTiles=8` 将 21024 tiles 合批为 361 live sections。
- SVO preview 已从同步单次调用改成 ThreadPool 后台构建 + pending coalesce，并升级为 3D occupancy octree leaf surface；2026-07-01 已接入 patch 分帧上传，8km smoke 为 361 sections / 155399 quads。SVO builder-side macro-cell artifact/cache/reuse 已落地，移动后第二次 build 可复用重叠 macro-cell；upload-level section fingerprint 复用已补第一片，跨 1 tile 的 8km SVO smoke 为 `uploaded_patches=39` / `reused_patches=322` / `live_sections=361`。CPU SVDAG artifact 统计第一片已补：snapshot 暴露 `svdag_node_count` / `svdag_unique_node_count` / `svdag_merged_node_count` / `svdag_compression_ratio`，8km smoke 为 `189144` / `70085` / `119059` / `0.371`。runtime SVDAG resource 数据面已推进到 shader 参数绑定第一片：snapshot 暴露 `runtime_resource_ready` / `runtime_root_count` / `runtime_node_count` / `runtime_child_ref_count` / `runtime_gpu_bytes` / `runtime_node_word_count` / `runtime_root_word_count` / `runtime_payload_bytes` / `runtime_compression_ratio`，8km smoke 为 `true` / `21016` / `3627` / `24416` / `1240896` / `58032` / `252192` / `1240896` / `0.019`，WorldActor 日志为 `rhi_ready=1` / `rhi_bytes=1240896`。2026-07-02 已补 `FVoxiaSvoRaymarchCS` compute dispatch probe 与 preview grid 读回：shader 独立到 `VoxiaShaders` PostConfigInit 模块，真实 RHI 下绑定 runtime SRV + output UAV，默认提交 1×1 global shader dispatch，显式加 `-VoxiaSvoRaymarchPreviewGrid=N` 时提交有界 preview grid 并读回；2026-07-03 已补 preview grid 可视像素面和 snapshot metrics，readback 样本会生成 `PreviewColors`，WorldActor queued 日志与 `svo` snapshot 都暴露 `raymarch_mode` / `raymarch_visual_pixels` / `raymarch_readback`；同日已补 `-VoxiaSvoRaymarchScreenProbe` debug screen buffer；后续已补 `-VoxiaSvoRaymarchComposite` debug-gated view extension，订阅 Tonemap post-process pass，并用 `FVoxiaSvoRaymarchCompositePS` 写回 debug raymarch tint SceneColor。SVO confirmed-store source boundary 已落地：`-VoxiaSvoConfirmedSource` 从当前 confirmed `FVoxiaVoxelStore` 快照构建，缺 coverage 时 `source_complete=false` / `expected_source_chunk_count` / `present_source_chunk_count` / `missing_source_chunk_count` / `build_error` 并不上传 mesh。WorldGen preview 下已补小范围 source preload 与 `-VoxiaSvoConfirmedSourceMaxChunks` 预算门禁，8km 超预算会在 build 前拒绝。服务端第一片也已补：`WorldPackSvoSourceMaterializer` / `scripts/world_pack_svo_source_materialize.exs` 可按同一 SVO tile/macro-cell coverage 统计 canonical source 覆盖，并在预算内经 `WorldPackBootstrapper` 写 bounded snapshots 后复查 ready。客户端 baseline pack 本地 H gate 已补两片：`world_pack_index_v1` window load 必须读取 `scene_<id>_world_pack_release_manifest.json`，并校验窗口涉及 `.vxpack` shard 的 manifest entry、`size_bytes` 和 `sha256` 后才应用 0x62 payload；`ConnectGate` / `EnterScene` 现在也会在 `entry_gate_ready=false` 时硬拒绝，observe 写 `tcp_connect_rejected` / `enter_scene_rejected` 而不是打开 socket path。当前仍不是完整 SVO traversal 的 composited screen-space GPU raymarch renderer，也无完整 launcher/update 包下载/安装 UI、8km 生产级权威源全量调度或持久化 artifact。
- 2026-07-03 后续更正：上一条中“debug raymarch tint / 尚未完整 traversal”的客户端 gap 已补第十二片。`VoxiaSvoRaymarch.usf` 现在用同一套 helper 选择 root-atlas cell，读取 root/node ByteAddress payload，按 child mask / occupancy / material id top-down 走到首个非空 leaf；preview-grid readback 第 4 word 固定编码 hit/miss，`CompositePS` 只在命中 leaf 时按 material color 与 hit depth 衰减 alpha 写回 SceneColor。真实 RHI automation 记录 `hit_samples=12` / `miss_samples=4` / `invalid_samples=0`；真实 RHI composite smoke `clients/Voxia/Saved/svo_raymarch_traversal_composite.log` 记录 `raymarch_readback=1` 与 `VoxiaSvoRaymarchComposite: scene color written output=[1920,1080] nodes=1088 max_depth=4 alpha=0.25`。该路径仍是 debug-gated 客户端可视化，不是生产 camera-correct world-space ray renderer。
- 2026-07-03 后续更正：SVO composite scene-depth occlusion 第一片已补。`FVoxiaSvoRaymarchCompositePS` 现在绑定 `SceneTextures`，默认启用 `bDepthOcclusionEnabled`，用 `SvoNearDeviceDepth` / `SvoFarDeviceDepth` / `DepthOcclusionBias` 做参数化 device-depth 遮挡，`-VoxiaSvoRaymarchNoDepthOcclusion` 可显式关闭。验证证据：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel.SvoPreview` 真实 RHI 退出 0，日志含 `hit_samples=12` / `miss_samples=4` / `invalid_samples=0`；`Automation RunTests Voxia.Gameplay.WorldActor` null RHI 退出 0；真实 RHI smoke `clients/Voxia/Saved/svo_raymarch_depth_occlusion_composite.log` 记录 `postprocess pass observed ... depth_occlusion=1` 和 `scene color written ... depth_occlusion=1`。该路径仍使用 root-atlas screen mapping 与参数化 SVO depth，不是生产 camera-correct world-space renderer。
- 2026-07-03 后续更正：SVO composite world-space root selection 第一片已补。`-VoxiaSvoRaymarchWorldSpace` 让 composite pass 上传 view origin / axes / FOV 的 SVO macro-space 参数，shader 按 camera ray 选择 root 后复用现有 top-down leaf traversal；后续已补 root lookup 加速第一片：runtime payload 生成 root lookup grid，RHI 额外上传 `VoxiaSvoRuntimeRootLookup` ByteAddress buffer，shader 优先用 XZ DDA 查 root，`-VoxiaSvoRaymarchNoRootLookup` 可回退旧的 `-VoxiaSvoRaymarchWorldRootScanLimit=N` 线性 root 扫描。当前验证覆盖命令行配置、stats、payload/RHI lookup、shader 参数面，并通过真实 RHI `Voxia.Voxel.SvoPreview` 确认 raymarch CS / composite PS 重新编译与 preview-grid dispatch/readback；真实 RHI smoke `clients/Voxia/Saved/svo_raymarch_root_lookup_composite.log` 记录 `postprocess pass observed ... world_space=1 root_lookup=1 root_lookup_cells=9 root_scan_limit=512` 与 `scene color written output=[1707,1067] nodes=589 max_depth=4 ... world_space=1 root_lookup=1`，回退 smoke `clients/Voxia/Saved/svo_raymarch_no_root_lookup_composite.log` 记录 `scene color written ... world_space=1 root_lookup=0`。该路径仍是 debug-gated 第一片，不是生产级 renderer。
- `FVoxiaFarFieldCoveragePlanner::PlanFull` 已作为第一块 FarField 公共组件落地并被 VHI/SVO 共用；VHI 的 tile dirty/reuse 判定仍留在 VHI tile artifact 逻辑中。`FVoxiaFarFieldBuildPipeline` 已收编 VHI/SVO transport 的 revision / serial / in-flight / pending coalesce/supersede 状态机；`FVoxiaFarFieldPatchUploader` 已收编 VHI/SVO patch section 池、bulk-hide、pending queue 和上传统计；`FVoxiaFarFieldMeshComponentDesc` 已收敛远景 ProcMesh 属性。
- 2026-07-03 后续更正：`FVoxiaFarFieldPatchUploader` 已补 backend-neutral render artifact contract。新增 `FVoxiaFarFieldRenderArtifactDesc`，记录 live patch 的 fingerprint、vertex/index/quad 计数、bounds、normal/color/UV 输入就绪、collision 标记、当前 render backend，以及 static / Nanite bake ready 标记；patch 上传成功时生成 artifact，删除 patch 时同步移除，只有 fingerprint/backend/collision 一致才复用 live patch。新增 `clients/Voxia/Source/Voxia/FarField/README.md` 记录职责边界。默认真实渲染仍是 ProceduralMesh section；SVO HISM / RuntimeMesh opt-in 后端见下方，Nanite bake 后端尚未接入真实渲染路径。
- 2026-07-03 后续更正：SVO HISM 渲染后端第一片已补。新增 `FVoxiaFarFieldHismInstanceBuilder`，从 patch mesh 的 quad 生成 plane instance transform；`-VoxiaSvoRenderBackend=HISM` 下 `AVoxiaWorldActor` 会创建/维护 `UHierarchicalInstancedStaticMeshComponent`，并让 `FVoxiaFarFieldPatchUploader` artifact 记录 `HierarchicalInstancedStaticMesh` backend。
- 2026-07-03 后续更正：SVO RuntimeMesh / DynamicMesh 渲染后端第一片已补。新增 `FVoxiaFarFieldDynamicMeshBuilder`，从 live patch set 合并 `FDynamicMesh3`；`-VoxiaSvoRenderBackend=RuntimeMesh`（别名 `DynamicMesh`）下 `AVoxiaWorldActor` 会创建/维护 `UDynamicMeshComponent`，并让 `FVoxiaFarFieldPatchUploader` artifact 记录 `RuntimeMesh` backend。该路径是 UE 内置 DynamicMesh runtime visual 后端，不是外部 RuntimeMesh 插件，也不是 Nanite bake / runtime distance-field / Lumen 生产照明路径。
- 验证证据：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 通过；`UnrealEditor-Cmd.exe ... Automation RunTests Voxia.Voxel` 退出 0，17 个 voxel tests 全部 success，含 `FarFieldBuildPipeline` / `FarFieldCoveragePlanner` / `FarFieldMeshComponentDesc` / `FarFieldPatchGrid` / `FarFieldPatchUploader` / `NearVoxelWindow` / `VhiImpostor` / `SvoPreview`。
- 2026-07-03 FarField artifact contract 验证证据：`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 退出 0；`UnrealEditor-Cmd.exe ... -nullrhi -ExecCmds='Automation RunTests Voxia.Voxel.FarFieldPatchUploader; Quit'` 退出 0，日志 `Test Completed. Result={Success}`；`Automation RunTests Voxia.Voxel.FarField` 找到 5 个测试：`FarFieldBuildPipeline` / `FarFieldCoveragePlanner` / `FarFieldMeshComponentDesc` / `FarFieldPatchGrid` / `FarFieldPatchUploader`，全部 `Result={Success}`。
- 2026-07-03 SVO HISM backend 验证证据：RED build 先因缺 `FarField/VoxiaFarFieldHismInstance.h` 失败；实现后 `Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel.FarFieldPatchUploader` 退出 0；`Automation RunTests Voxia.Gameplay.WorldActor` 退出 0；真实 RHI smoke `clients/Voxia/Saved/svo_hism_backend_smoke.log` 记录 `VoxiaWorldActor SVO preview queued ... render_backend=hism` 与 `VoxiaWorldActor SVO preview streamed ... render_backend=hism hism_instances=905`。
- 2026-07-03 SVO RuntimeMesh backend 验证证据：RED build 先因缺 `FarField/VoxiaFarFieldDynamicMesh.h` 失败；实现后 `Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel.FarFieldPatchUploader` 退出 0；`Automation RunTests Voxia.Gameplay.WorldActor` 退出 0；`Automation RunTests Voxia.Voxel.FarField` 找到 5 个测试且全部 `Result={Success}`；真实 RHI smoke `clients/Voxia/Saved/svo_runtime_mesh_backend_smoke.log` 记录 `VoxiaWorldActor SVO preview queued ... render_backend=runtime_mesh` 与 `VoxiaWorldActor SVO preview streamed ... render_backend=runtime_mesh ... runtime_mesh_vertices=3620 runtime_mesh_triangles=1810`。
- 2026-07-03 Interest Runtime 自动刷新检查点：`UVoxiaClientInterestSubsystem::Tick` 已改为自动读取 Transport near-window、SVO、VHI、heightmap revision 来维护 `near` / `far` visual 状态，同时推进 focus lease/cooling；快照暴露 `auto_refresh`、`last_refresh_seconds`、`last_refresh_age_seconds`，CLI 新增无副作用观察入口 `interest_raw`。这一步把客户端 near/far/focus 策略层从“CLI 触发刷新”推进为自维护 runtime；真实 focus wire opcode、server hydrate decoder、服务端租约/权限/长程命中判定仍未接入。
- 2026-07-03 客户端 focus 用户入口检查点：`VoxiaPawn` 绑定 `T` 键为 telescope/focus 请求，并新增 `DebugRequestFocus` / CLI `focus_input`。两者共用 `RequestFocusAtCrosshair`，通过 `VoxiaFocusTarget` 把 camera ray + focus 参数解析成远程 tile，调用 Interest `PromoteFocus` 后 drain 到 Transport interest outbox，再按 `-VoxiaInterestWire` 决定是否尝试 feature-gated wire flush。`snapshot.last_focus` 暴露 region id、center tile、drained/enqueued、wire flag 和 flush report。自动化新增 `Voxia.Gameplay.FocusTarget` 覆盖目标解析。
- 2026-07-03 Transport interest outbox 自动 flush 检查点：`UVoxiaTransportSubsystem::Pump` 会对 pending focus request 节流 auto-flush，`transport.interest_auto_flush` / CLI `interest_auto_flush` 暴露 attempts、interval、wire flag 和 last flush report。默认 wire disabled 只 dry-run；`-VoxiaInterestWire` 走 feature-gated sender，未进场时显式 `cannot send interest focus request before entering scene`，opcode 未分配时仍显式 `interest_focus_wire_opcode_unassigned`，两者都会保留 pending。`-VoxiaInterestAutoFlushSeconds=N` 可调整重试节奏。
- 2026-07-03 Interest Sync Scheduler 检查点：`FClientInterestRuntime` 已新增客户端同步调度面，`interest` 快照带 `sync_scheduler`，CLI 新增 `interest_sync`。调度器按 near / far / focus 的 `sync_hz`、layer/state priority 和 `-VoxiaInterestSyncBudgetPerTick=N` 计算 due / next due、scheduled、budget_deferred、stale、suppressed 与 action。默认 near / focus 高优先级，far 是低频 visual map sync；focus 覆盖 far 时不会让低保真远景抢预算。该层只表达客户端请求策略，不拥有 confirmed truth，也不绕过 Transport outbox / 服务端协议。
- 2026-07-03 focus hydrate decoder 边界检查点：`FClientInterestWireDecoder` 已新增 `TryDecodeFocusHydrateFrame` / `DecodeFocusHydrateBody`，`focus_hydrate_body_v1` body contract 已可通过 CLI `interest_decode_focus_hydrate_body` 和 `Voxia.Interest.ClientInterest` 验证。当前服务端 opcode 未分配，所以 frame decoder 不会识别任何现网帧，避免误吃 `0x62` / `0x63` 等既有协议；Transport inbound pump 已预留 `ApplyInboundInterest`，未来分配 opcode 后只需填 frame 识别并保持 confirmed payloads 走 `ApplyInterestFocusHydratePayloads`。
- 2026-07-03 focus opcode 配置检查点：客户端新增 `-VoxiaInterestFocusPromoteOpcode=0xNN` / `-VoxiaInterestFocusHydrateOpcode=0xNN`，`interest_wire_status` 暴露 assigned/valid/opcode/reason。默认 unassigned；配置为现有协议 opcode 或 promote/hydrate 相同会 invalid。合法配置后 promote 编码 `focus_promote_body_v1` framed packet，hydrate inbound 识别配置 opcode 并解 `focus_hydrate_body_v1`。这让服务端正式分配 opcode 后，客户端可先通过启动参数联调，不需要改 near/far/focus runtime。
- 2026-07-03 focus hydrate frame apply 检查点：`UVoxiaTransportSubsystem::ApplyInterestFocusHydrateFrame` 已落地，CLI 新增 `interest_apply_focus_hydrate_frame`。配置 hydrate opcode 后，该命令构造完整 focus hydrate frame payload，走同一个 Transport inbound adapter，消费 confirmed `0x62` payload，ACK outbox，并把 focus 推到 interactive。socket pump 的 `ApplyInboundInterest` 也复用该 adapter。
- 2026-07-03 focus loopback smoke 检查点：CLI 新增 `interest_focus_loopback`，配置 focus promote/hydrate opcode 后一条命令完成 focus request -> outbox -> configured promote encode -> configured hydrate frame -> confirmed payload apply -> focus interactive -> outbox ACK。后续客户端侧协议改动优先跑该命令做联网 ready 回归。
- 2026-07-03 focus coverage 检查点：Interest runtime 已新增 `QueryTileCoverage` / `QueryChunkCoverage` 与 CLI `interest_query_tile` / `interest_query_chunk`。该查询是客户端消费侧判断高保真覆盖的统一契约：near 和 confirmed focus interactive 返回 `interactive=true`，far visual 与 hydrating/cooling focus 不会放行交互。`AVoxiaPawn` 的编辑命中 gating 已接入该契约，同时仍要求命中 chunk 已由 Transport confirmed store 持有。
- 2026-07-03 focus budget 检查点：Interest runtime 已自维护 active focus 容量边界，默认最多 4 个 hydrating / interactive focus，可用 `-VoxiaInterestMaxActiveFocus=N` 调整；超额时最旧 active focus 进入 cooling，移除本地待发送请求，并在 `interest` snapshot / observe 暴露 active/max/eviction 统计。这只约束客户端关注区与 suppression，不删除服务端 confirmed truth。
- 2026-07-03 remote action facade 检查点：新增 `VoxiaRemoteInteraction`，远程技能/望远镜/CLI action 统一走 coverage gate。`remote_action_check` 只判断 confirmed near/focus 是否 ready；`remote_action` 在未 ready 时创建 focus hydrate request 并入 Transport outbox；`AVoxiaPawn` 的 `T` focus 输入已复用该 facade。这是客户端消费侧架构，不替代服务端权限、长程命中、租约和正式 opcode。
- 2026-07-04 remote action outbox / wire contract 检查点：`AVoxiaPawn` 已绑定 `R` 键为真实 remote action 输入，CLI 新增 `remote_action_input`、`remote_action_outbox`、`remote_action_flush [wire]`、`remote_action_wire_status`、`remote_action_decode_result`、`remote_action_apply_result`。`remote_action` / `R` 在 coverage 已 ready 时会创建 `FVoxiaRemoteActionIntent` 并进入 Transport remote action outbox；默认 flush 是 `wire_disabled` dry-run。`-VoxiaRemoteActionRequestOpcode=0xNN` 配置后，feature-gated sender 会编码 `remote_action_request_body_v1` framed packet；`-VoxiaRemoteActionResultOpcode=0xNN` 配置后，inbound pump 会识别 `remote_action_result_body_v1` 并更新 `transport.remote_action_result`。`snapshot.last_remote_action` 暴露 ready、intent id、coverage result 与 flush report。该 outbox/result adapter 只是客户端 intent/回执边界，不替代服务端技能 authority、租约、权限、长程命中或 confirmed truth。
- 2026-07-03 far proxy suppression 检查点：`AVoxiaWorldActor` 已消费 focus coverage。interactive focus 覆盖签名变化会强制 heightmap LOD / VHI / SVO patch 重新评估；heightmap LOD quad、VHI tile 与 SVO macro-cell artifact 上传前会过滤 focus 覆盖区域，日志暴露 `suppressed_quads` / `suppressed_tiles` / `suppressed_macro_cells` / `suppression_serial`。这只裁掉低保真 far visual proxy，不改 confirmed store、raycast、碰撞或 authority。
- LOD inner-skirt 真实画面 smoke：2026-07-02 `Voxia.Voxel.HeightmapMesher` 在真实 RHI commandlet 下 `Result={Success}`；`/Game/Voxia/Maps/L_WorldGenPreview` 加 `-VoxiaWorldGenPreview -VoxiaHeightmapLod=16x11 -VoxiaShot` 生成 `clients/Voxia/Saved/voxia_lod_skirt_16x11.png`（1280×720，888637 bytes，采样 760+ unique colors），日志 `clients/Voxia/Saved/lod_skirt_shot_16x11.log` 为 `LOD terrain (async): 1 sections, 197 quads` 后 `requested screenshot`。`16x7` smoke 也跑过，但因完整落在 inner skip 内只有 `0 quads`，不作为 skirt 视觉证据。
- LOD 默认多 tier 真实 RHI smoke：2026-07-03 `/Game/Voxia/Maps/L_WorldGenPreview` 加 `-VoxiaWorldGenPreview -VoxiaShot` 使用默认 `{2x256,4x256,8x256,16x1000}`，生成 `clients/Voxia/Saved/voxia_lod_multitier_default.png`（1280×720，679940 bytes，采样 213 unique colors），日志 `clients/Voxia/Saved/lod_multitier_default.log` 为 `4 sections, 3030140 quads`。稳定性复跑 `clients/Voxia/Saved/lod_multitier_default_stability.log` 显示首轮上传有 1-3 FPS 尖峰，但上传完成后连续样本恢复到约 112-134 FPS；若要消除入场尖峰，后续应把 LOD section 上传分帧或换 runtime mesh。
- LOD 近场 fill bridge 真实 RHI smoke：2026-07-03 `Voxia.Gameplay.WorldActor` automation 验证 `ResolveInitialLodSkipMacros` 在首个 near mesh 渲染前返回 0、渲染后恢复配置 skip；`clients/Voxia/Saved/lod_near_fill_bridge_16x11.log` 显示首轮 LOD `1 sections, 326 quads`，随后 near mesh `1 material sections, 72765 quads`，再触发 LOD 重建回到 `1 sections, 197 quads`。这关闭了初始 fill 期间的临时中心真空环。
- VHI CLI smoke：启动 `/Game/Voxia/Maps/L_WorldGenVhiPreview`，VHI build `21024 tiles / 336384 samples / 932892 quads`，`built_tile_count=21024`，`build_elapsed_ms=889.7`；等待上传完成后 `uploaded_patches=361` / `live_sections=361` / `patch_tiles=8` / `elapsed_ms=11355.1`。
- SVO CLI smoke：`/Game/Voxia/Maps/L_WorldGenSvoPreview` 下首次 build 为 `macro_cell_count=21016` / `quad_count=155399` / `seam_check.status=pass` / `built_macro_cell_count=21016` / `cache_hit_rate=0.000`；移动到 `center_tile=[17,0,-51]` 后第二次 build 为 `built_macro_cell_count=879` / `reused_macro_cell_count=20137` / `removed_macro_cell_count=879` / `cache_hit_rate=0.958` / `build_ms=87.482`，SVO patch upload 为 `uploaded_patches=361` / `live_sections=361`。runtime resource smoke 为 `runtime_resource_ready=true` / `runtime_root_count=21016` / `runtime_node_count=3627` / `runtime_child_ref_count=24416` / `runtime_gpu_bytes=1240896` / `runtime_compression_ratio=0.019`。confirmed-store source smoke：完整 1-tile coverage 为 `source_kind=confirmed_voxel_store` / `source_complete=true` / `missing_source_chunk_count=0` / `quad_count=28`；缺覆盖 radius=1 为 `source_complete=false` / `missing_source_chunk_count=2744` / `quad_count=0` / diagnostic `build_error`。coverage preflight/preload smoke：radius=1 budget 3000 为 `expected_source_chunk_count=3087` / `present_source_chunk_count=3087` / `missing_source_chunk_count=0` / `quad_count=174`；8km budget 3000 为 `expected_source_chunk_count=7208488` / `missing_source_chunk_count=7208488` / `quad_count=0` / diagnostic budget `build_error`。
- runtime payload/RHI/shader 参数 smoke：同一 8km SVO CLI 下 `runtime_node_word_count=58032` / `runtime_root_word_count=252192` / `runtime_payload_bytes=1240896`，与 `runtime_gpu_bytes=1240896` 一致；WorldActor queued/streamed 日志为 `rhi_ready=1` / `rhi_bytes=1240896`。payload 已进入 RHI ByteAddress buffer，并能生成 `FVoxiaSvoRaymarchCS` 参数绑定。2026-07-02 automation 证据：`Voxia.Voxel.SvoPreview` 在 D3D12 / `PCD3D_SM6` 下 `Test Completed. Result={Success}`，dispatch report 为 `shader_available=1` / `parameters_ready=1` / `dispatched=1` / `groups=[1,1,1]` / `nodes=986` / `roots=16` / `max_depth=4` / `output_bytes=16`，preview grid report 为 `dispatched=1` / `readback=1` / `groups=[1,1,1]` / `grid=[4,4]` / `samples=16` / `readback_words=64`；2026-07-03 automation 证据同一路径额外断言 `preview_colors=16` 且首像素非空，并断言 `SnapshotJson` 暴露 `raymarch_visual_pixels` / `raymarch_readback`。2026-07-03 hidden real-RHI 小半径 smoke `clients/Voxia/Saved/svo_raymarch_snapshot_metrics.log` 记录 `raymarch_dispatched=1` / `raymarch_grid=[4,4]` / `raymarch_readback=1` / `raymarch_visual_pixels=16` / `raymarch_nodes=1088` / `raymarch_roots=16`；screen probe smoke `clients/Voxia/Saved/svo_raymarch_screen_probe.log` 记录 `raymarch_mode=screen_probe` / `raymarch_grid=[240,135]` / `raymarch_samples=32400` / `raymarch_readback=1` / `raymarch_visual_pixels=32400`；screen-pass hook smoke `clients/Voxia/Saved/svo_raymarch_composite_pass.log` 记录 `VoxiaWorldActor SVO raymarch composite enabled alpha=0.25` 与 `VoxiaSvoRaymarchComposite: postprocess pass observed output=[1920,1080] nodes=1088 max_depth=4 alpha=0.25`；SceneColor 写回 smoke `clients/Voxia/Saved/svo_raymarch_composite_write.log` 记录 `VoxiaSvoRaymarchComposite: scene color written output=[1920,1080] nodes=1088 max_depth=4 alpha=0.25`；depth-occlusion smoke `clients/Voxia/Saved/svo_raymarch_depth_occlusion_composite.log` 记录 `depth_occlusion=1` 和 `scene color written`。`-nullrhi` 同测试 `Result={Success}`，但只验证 CPU/RHI buffer 参数面并记录 dispatch/readback skip。2026-07-02 null RHI 8km CLI smoke 为 `runtime_resource_ready=true` / `runtime_payload_bytes=3260480` / `quad_count=1166362` / `seam_check.status=pass`，WorldActor queued/streamed 日志为 `rhi_ready=1` / `rhi_bytes=3260480` / `raymarch_dispatched=0`（null RHI）。仍未接入 production camera-correct world-space SVO renderer。
- 服务端 SVO source materialization 证据：`MIX_ENV=test mix test apps/world_server/test/world_server/voxel/world_pack_svo_source_materializer_test.exs --no-start` 通过（3 tests）；`MIX_ENV=test mix run --no-start scripts/world_pack_svo_source_materialize.exs --dry-run --radius-tiles 72 --near-skip-radius-tiles 1 --macro-cell-tiles 1 --max-chunks 3000 --no-migrate` 返回非零，observe 为 `.demo/observe/world-pack-svo-source/world_pack_svo_source_coverage_20260701T035443944000.json`，报告 `macro_cell_count=21016` / `expected_source_chunk_count=7208488` / `present_source_chunk_count=0` / `missing_source_chunk_count=7208488`；`MIX_ENV=test mix run --no-start scripts/world_pack_svo_source_materialize.exs --logical-scene-id 919998 --radius-tiles 0 --near-skip-radius-tiles -1 --macro-cell-tiles 1 --max-chunks 400 --batch-size 64 --no-migrate` 退出 0，observe 为 `.demo/observe/world-pack-svo-source/world_pack_svo_source_materialize_20260701T035544052000.json`，报告 `343` chunks inserted、final missing `0`、status `ready`。
- 下一步优先级：当前用户要求先不碰服务端，且路线已调整为先把客户端架构立住。`-VoxiaSvoRaymarchComposite` 的 root/node hash debug tint 已替换为真实 SVO payload traversal / depth-aware blend，并补入 debug scene-depth occlusion、world-space root selection 与 root lookup DDA 第一片；FarField 已补 backend-neutral render artifact contract、SVO HISM 后端第一片和 SVO RuntimeMesh / DynamicMesh 后端第一片。最新客户端侧已新增 `UVoxiaClientInterestSubsystem` / `FClientInterestRuntime`：`near` 是玩家 AOI 高保真交互层，`far` 是低频 visual map sync 层，`focus` 是望远镜/超远程魔法等按需高保真区域；CLI 暴露 `interest`、`interest_focus`、`interest_focus_ready`、`interest_focus_release`、`interest_remote_focus`、`interest_remote_focus_payloads`、`interest_drain_requests`、`interest_flush`、`interest_outbox`、`interest_wire_status`。focus outbound request 已能进入 Transport interest outbox，默认 flush 为 `wire_disabled` dry-run；feature-gated `wire` 路径进场前显式返回 `cannot send interest focus request before entering scene`，进场后当前 sender 显式返回 `interest_focus_wire_opcode_unassigned`，两种情况都会保留 pending。`FClientInterestWireEncoder` 已补协议边界适配层：当前服务端 `GateServer.Codec` 没有 focus hydrate request opcode，且不能复用 `ChunkSubscribe 0x60`，因为它会改变 active/editable window 语义。receive-side 已补 `FClientInterestHydrateSnapshot` 与 `ApplyInterestFocusHydrateSnapshot`，`interest_remote_focus` 现在走 Transport adapter，且必须声明 confirmed truth 已应用才会进入 interactive；Transport hydrate 成功后会按 `request_id` 或 `region_id` ACK pending outbox，并在 `interest_outbox` 暴露 `total_acknowledged`。同日补入 `ApplyInterestFocusHydratePayloads`：未来 decoder 可先交给 Transport 消费 confirmed `ChunkSnapshot 0x62` / `ObjectStateDelta 0x6C` / `FieldRegionSnapshot 0x73` payload，再打开 focus interactive；`ChunkDelta 0x63` 暂不作为 hydrate seed，避免本地缺 base version 时假确认。下一项若继续客户端优先，只剩把服务端分配后的 focus opcode 填进 `FClientInterestWireEncoder`，并把真实 server hydrate decoder 接到 payload adapter；Nanite bake、production renderer、launcher/update UI 暂排后。
- 2026-07-04 接力补充：客户端 remote action intent 出站队列、可配置 request opcode、可配置 result opcode 和 inbound result adapter 都已立住；继续客户端优先时，下一项应是 HUD/overlay 对 pending action intent / last result 的可视化，或补和服务端正式 opcode 对齐后的端到端联调。服务端 authority 规则仍按后续阶段接，不在当前客户端 outbox 内伪造。

下个会话开始时,先读这份(landing pad),再按需读 phase-X-*.md / 设计文档。

## 已落地阶段(2026-05-09 收盘)

| 阶段 | 状态 | 关键 commit |
| --- | --- | --- |
| 1a Refined cell domain (read-only wire) | 已完成 | `872e439` |
| 1b typed VoxelEditIntent (decode-only) + VoxelImpactIntent deprecation | 已完成 | `872e439` |
| 1c Scene refined mutation API + CellRefined delta + 客户端解锁 | 已完成 | `c99d6fd` (1c-1/2/3) → `508ce1e` (1c-4) → `a02817a` (1c-5) → `07bee6b` (1c-6) |
| 1d DataService canonical 持久化 + chunk_hash 全字段覆盖回归 | 已完成 | `36b8ad7` |
| 2 refined micro edit 端到端贯通 | 已完成(被 1c 吸收) | `314ad8a` (stub + README) |
| 3 prefab v2 事务化(World/Scene transaction coordinator) | 已完成 | `a053c82` (决策稿) → `3fc9966` (3-1) → `6973843` (3-2) → `bd74e01` (3-3a) → `e91c38f` (3-3b) → `b93a10d` (3-4) → `86d9186` (3-5) |
| 3-bis fence persistence + auto-resume commit(crash safety 闭环) | 已完成 | `5e3b1e7` (决策稿) → `5cadbdf` (3-bis-1) → `f6602b0` (3-bis-2) → `d767c29` (3-bis-3) → `9db8c1d` (3-bis-4) → `d01b3d6` (3-bis-5) → `c7ef222` (3-bis-6) |
| 4 object provenance + part-health 破坏闭环(含整体销毁) | 已完成 | `067085f` (决策稿) → `df1ba93` (4-1) → `95a3330` (4-2) → `f61351c` (4-3) → `686d3cd` (4-4) → `53e4e7d` (4-5) → `330d528` (4-6) → `d800996` (4-7) → `0a5b428` (4-8) → `5352040` (4-9) → `b10e197` (4-10) |
| 4-bis ObjectStateDelta 推送链路 + 客户端碎屑粒子消费 | 已完成 | `ed16fef` (决策稿) → `0d9df62` (4-bis-1) → `3b96714` (4-bis-2) → `77f690d` (4-bis-3) → `2cb2373` (4-bis-4) → `3ca3f6e` (4-bis-5) → `a5b4eca` (4-bis-6) → `1ed8fd8` (4-bis-7) → `1e34841` (4-bis-8) → `bc89cea` (4-bis-9) → `d37598a` (4-bis-10) → `c78e04f` (4-bis-11) → `1f6cc13` (4-bis-12) → `f9906b1` (4-bis-13 docs 收尾) |
| A2 阶段 A 子 1:尺寸真实化(角色 1.7m / 跑速 6 m/s / apex 1.2m) | 已完成 | `6144408` (决策稿) → `aec8a98` (A2-1) → `05cebdf` (A2-2) → `ef5d524` (A2-3) → `03690c0` (A2-4) → `630d257` (A2-5) → `fb69661` (A2-6) → `730e6e7` (A2-final) |
| A1 阶段 A 子 2:客户端可玩 demo 必须线(prefab micro / 防覆盖 / 线框预览 / 跳跃同步 / 破坏技能) | 已完成 | `edbfbda` (决策稿) → `0275899` (A1-1 prefab catalog v2) → `d399f7c` (A1-1 progress) → `a4616e9` (A1-1 sphere e2e smoke) → `14c90a9` (A1-2 prefab 防覆盖) → `b2fe630` (A1-3 preview regression) → `b692ab1` (A1-4 ack ground_z wire) → `133bb85` (A1-4 jump arc smoke) → `7932fe2` (A1-5 voxel damage router) → `6d261d7` (A1-final) |
| A2 hotfix:client `DEFAULT_MOVEMENT_PROFILE` 同步 server max_speed=600 等 | 已完成 | `58a7a9e` |
| A1-1b Storage.put_micro_blocks/4 batch API(prefab 卡死性能优化,1.5s → 46ms,33×) | 已完成 | `0e3434c` |
| Server 启动 hotfix:TransactionRecoveryWatcher 接 plain-map stale snapshot | 已完成 | `cc3a31d` |
| Prefab 摆放精度 hotfix:server 按 world-micro 精度落 prefab + online adapter 走 boundary-snap micro 锚 | 已完成 | `a7a5bc9` (server raster) → `20f6a8a` (online adapter) |
| **A4 跨 region prefab 多 participant 事务 + 跨节点 damage / 0x6C 路由(主体)** | 已完成 | `f49c0b9` (决策稿) → `22312e0` (D7 折回) → `3f381d0` (A4-1) → `6acd37d` (A4-2) → `e6eafa3` (A4-3) → `630574b` (A4-4) → `13ef21a` (偏移同步) → `4ab6c83` (D8-D11 拍板) → `4198b8e` (A4-5) → `e3a5c01` (A4-6 + A4-final) |
| A4-bis-cluster A4-bis-1:`BeaconServer.Client` term key 全量升级 | 已完成 | 本会话 (`1fd1446`) |
| A4-bis-cluster A4-bis-2:`SceneServer.Voxel.RegionRouting` 新模块 + `BeaconServer.Client.unregister/1` | 已完成 | 本会话 (`8a6e124`) |
| A4-bis-cluster A4-bis-3:`RegionRuntime.apply_lease` 接 RegionRouting + Horde startup 移 test_helper | 已完成 | 本会话 (`c866fde`) |
| A4-bis-cluster A4-bis-4 段 1:`WorldServer.Voxel.SceneNodeRegistry` 新模块(D8.B join-order round-robin + no-failover) | 已完成 | 本会话 (`5f8aa77`) |
| A4-bis-cluster A4-bis-4 段 2a:`SceneNodeMonitor` + WorldSup 挂入 | 已完成 | 本会话 (`e317736`) |
| A4-bis-cluster A4-bis-4 段 2b:Scene 端 RPC announce 到 World | 已完成 | 本会话 (`30a7a7c`) |
| A4-bis-cluster A4-bis-4 段 2c:`MapLedger.put_region` 接 SceneNodeRegistry | 已完成 | 本会话 (`de8b4b7`) |
| A4-bis-cluster A4-bis-4 段 2d:`default_scene_opts_resolver` 按 region 解析 | 已完成 | 本会话 (`345337f`) |

测试规模(2026-05-10,prefab 微精度 hotfix 收尾):

- data_service: 71 tests
- scene_server: **378 tests** (+3 from prefab micro hotfix:mid-macro 跨
  macro / 跨 chunk / group_by_chunk 多桶 case;原 floor-divided +
  negative-anchor 用例改写)
- scene_server :smoke: 5 tests
- gate_server: 191 tests
- world_server: 72 tests (1 预存失败 Windows path,不动)
- web_client: **260 vitest** (+2 placePrefabBoundarySnap online 用例)
- movement_core cargo: 39 tests

预存失败:`apps/world_server/test/world_server/voxel/authority_observe_test.exs:35`
Windows path 大小写,不动(memory 已记)。

未 push(用户没说 push 就别 push)。本地 master 领先 origin **72 commits**
(Phase 4 末 35 + Phase 4-bis 14 + Phase A2 8 + Phase A1 9 + A2 hotfix 1 +
A1-1b 1 + watcher hotfix 1 + handoff docs 1 + prefab micro hotfix 2)。

## 已知预存失败(本环境)

- `apps/world_server/test/world_server/voxel/authority_observe_test.exs:35` Windows path 大小写比对。**不要尝试修**(本会话也没碰过 world_server)。

## 下一步候选(按 README 顺序)

按 `docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md` 阶段表:

| 阶段 | 状态 | 范围 |
| --- | --- | --- |
| A4-bis-cluster | 进行中(A4-bis-1/2/3/4 ✓ → 2 step 待办 + 段 2 收尾扩 audit + release) | 真正的多 scene_node 分布式部署。**生产路径已改**:World 按 region 路由事务到对应 scene_node,完整链路 scene 上线 → RPC announce → SceneNodeRegistry register → MapLedger.put_region 分配 → resolver 解出。剩余:**段 2 收尾(audit + release,用户决策"每 app 独立 BEAM"目标)**:跨 app 通信 audit(扫所有 GenServer.call 形式确认无隐藏"必须同 BEAM"假设)+ release 配置(让 mix release 能为每个 app 独立打包,验证可执行);**A4-bis-5** ObjectOwnerLookup / VoxelDamageRouter / ObjectRegistry default opts 改为走 RegionRouting + cold-start 走 region resolver;**A4-bis-6** 双 BEAM `:peer` 节点 e2e;**A4-bis-final** 决策稿/handoff 同步。决策来源:用户"MVP 大世界一台机扛不住",从 Phase 6 HA 提前。剩余估时 1.5-3 天。文档:`phase-A4-cross-region-prefab.md` 文末 A4-bis-cluster 段 |
| A3 | 未开始 | 阶段 A 子 3:多客户端同世界联调(本地多 tab / 多机 + chunk 订阅一致性 + 移动同步 + 破坏可见性) |
| 5 | 未开始 | 属性目录 + 温湿度基础模拟 |
| 测试隔离 | 未开始 | test_helper 加 setup TRUNCATE `voxel_transaction_coordinator_snapshots` / `voxel_chunk_pending_transactions`,避免跨 mix test stale snapshot 让 transaction 路径走 replay-skip |
| BuildTransaction snapshot 字段演进 | 待评估 | A1-1b 这次发现 stale snapshot binary_to_term 出 plain map 而不是 struct,让 watcher 启动 crash。已加 catchall fix,但根因(Phase 3-bis-3 加 intents_by_participant / Phase 4 加 scene_objects 后旧 blob 的 struct 形态变了)需要正经评估是否需要 schema_version 化 |

**阶段 A 进度**:A2 + A1 + A1-1b 全部完成 2026-05-09。剩 A3(多客户端联调)
+ Phase 5(属性目录)。A2 + A1 + A1-1b 已经把"路演 demo 必须线"全部打通:
角色 1.7m / 跑速 6 m/s / 跳跃 apex 1.2m / sphere/cylinder/stairs 形状 / prefab
防覆盖 / 线框预览 / 跳跃同步(ack ground_z wire 端到端)/ 破坏技能 / **prefab
placement < 100ms 不再卡死**。

**用户实测验证状态**:
- A1-1b 修完后 user 报 server 重启 OK,但发现客户端线框预览(micro 精度)和
  服务端实际摆放(macro 对齐)不符 — 服务端按方框位摆,丢了 micro offset。
  Prefab micro-precision hotfix 已落(`a7a5bc9` server raster + `20f6a8a`
  online adapter):server `prefab_raster` 按 world-micro 精度 per-cell 拆
  (chunk, local_macro, slot),online adapter 走 boundary-snap 出 micro 锚发
  `0x67`。**下个会话开始前先确认 user fresh demo:prefab 实际落地是否和
  线框严格一致**。如果还有偏差,可能是 wireframe 几何 vs server raster slot
  decode 顺序细节(应该不会,两端都用 `slot = x + y*8 + z*64`),或者 boundary
  snap 选锚算法选了不同候选(可在 client 端 emit `world:prefab-boundary-snap-committed`
  比对 anchorMicroCoord 与 server `voxel_chunk_transaction_committed` log 里的
  intent 起点)。

**Phase 4-bis 后剩余的 backlog**(若用户优先继续巩固 4-bis 系):

- **0x6C ChunkDelta apply 前 cache hook**(Phase 4-bis-10 deferred 到 Phase 5):
  ClearedSlotCache + DebrisSimulation pipeline 已 wired,但 cache 实际无写入,
  production 路径全走 affected_chunks_fallback(粒子在 chunk 中心点散开,
  不是沿 micro slot 散布)。Phase 5 把 owner_object_id 接进 FRefinedCellData
  之后,新增一行 cache hook(applyDelta CellRefined / CellEmpty op 之前
  diff layer.ownerObjectId)即可升级到精确档 B。
- **DebrisRenderer per-instance 颜色微抖**:Phase 4-bis-12 用单一 base 棕色;
  per-instance instanceColor 通道留待 Phase 5。
- **HUD destroyed 升级**:目前一行字 3.5s。Phase 5+ 可加屏幕红闪 / 音效 /
  destroyed object 中心爆炸 emoji。
- ~~**跨 region 多 participant 事务**(Phase 3-bis 后续)~~:**已在 Phase A4 主体闭环**(A4-1 ~ A4-final 落地 2026-05-10):BuildTransaction multi-participant + Gate per-chunk routing + 跨节点 damage RPC + 0x6C owner-driven fan-out。生产路径仍单 scene_node;真分布式部署在 A4-bis-cluster 决策稿就位。
- **Per-region coordinator**(Phase 6 留):当前单全局 coordinator 是潜在 SPOF。
- **紧凑 ChunkDelta**(取代 commit 时的 snapshot fan-out):commit 时把 batch
  内每个 intent 编成 ChunkDelta op 推送,不必走整 chunk snapshot。
- **跨进程 e2e harness**(Phase 2 决策稿 park 的 backlog):gate ↔ scene ↔
  data_service ↔ web_client 全链路 e2e 自动化。
- **fence 超时 sweeper**:`fenced_at_ms` 字段已写入,但目前没自动清理"卡死"fence。

**Phase 5 属性目录 + 温湿度基础模拟**(README 顺序下一阶段):

- 还没建决策稿。需要先和用户对齐:`AttributeCatalogSnapshot` / `TagCatalogSnapshot` 协议、温湿度计算、`PartDefinition.default_health_ratio` 字段(Phase 4 留的 1.0 ratio 旋钮)。
- 新决策稿位置:`docs/voxel-server-authority/phase-5-attributes-and-environment.md`(待建)。
- Phase 5 同时是 Phase 4 留下的若干悬挂物的"完成场":整体销毁的下游钩子(掉落物 / 任务系统 / 资源回收 / 客户端 0x6C 消费 / 结构完整性 / 塌陷规则)都是 Phase 5+ 范围。

## 工作流约定(跨会话)

参考 memory:`feedback_decision_stub_workflow.md` + `feedback_no_backcompat_unreleased.md`。简版:

1. **决策稿先行**:每 phase 在 `docs/voxel-server-authority/phase-<id>-<slug>.md` 写决策稿,列决策项(每项给推荐值)、不在范围、风险、step 列表。决策稿入仓后才动代码。
2. **逐 step commit**:每 step 单独 commit。Elixir 文件改前 `mix format`;web 端 `npx tsc --noEmit && npx vitest run`。
3. **进度日志**:每 step 完成后在决策稿 `## 进度日志` 追加一行。同步 `README.md` 阶段表。
4. **不 push**:用户没说 push 就只 commit。
5. **全新系统不留兼容**:架构重写默认按"未上线第一版"姿势,不留 wrapper / 双路径 / deprecated alias。

## 关键运行时约定(避免下次重新发现)

### Postgres / Repo

- `apps/data_service/test/test_helper.exs` 启动 `DataService.Repo` + 跑 `priv/repo/migrations`。
- **Phase 1d 后**:`apps/scene_server/test/test_helper.exs` 与 `apps/gate_server/test/test_helper.exs` 也启动 Repo + migrations(因为 ChunkSnapshotStore 走 Repo)。
- **assert_receive_timeout 调到 1000ms**(scene/gate test_helper),容忍 Postgres INSERT 延迟。
- 持久化测试要 `async: false` + `setup do Repo.delete_all(...); WriteTokenStore.reset(WriteTokenStore); :ok end`。

### Windows 测试

- `mix` 用 `cmd //c "mix ..."`(via Bash 工具)或 `mix ...`(via PowerShell 工具)。
- vitest 必须 `cd clients/web_client/`,从 umbrella 根跑会丢 globals。
- `cmd /c` 在 PowerShell 工具里 cwd 跨调用持久;Bash 工具不持久。
- `mix` 报 dependency 问题就从 umbrella 根跑(`mix test apps/<app>/test`),不从 `apps/<app>/` 子目录跑。
- `mix cmd --app` 也不行(config 加载缺 :database)。
- **vitest 不接受 `--reporter=basic`**;直接 `npx vitest run` 即可。

### 体素架构现状

- ChunkSnapshotStore 是 stateless module,直走 `DataService.Repo`(Phase 1d)。
- ChunkPendingTransactionStore 是 stateless module,新表 `voxel_chunk_pending_transactions`(Phase 3-bis-1)。
- **SceneObjectStore**(Phase 4-1):新表 `voxel_scene_objects` + `voxel_scene_object_id_seq` 全局 sequence。`covered_chunks` / `part_states` 用 `term_to_binary` 编码 server-side blob(对齐 fence_payload 风格)。
- WriteTokenStore 仍是 GenServer(in-memory);Phase 1d 加了 `reset/1` test hatch。
- ChunkProcess 是每个 chunk 一个 GenServer,持有 hot truth + lease;`pending_fence.intents` 是 list(Phase 3-3a),fence 同步持久化进 voxel_chunk_pending_transactions(Phase 3-bis-2),init 时按 lease 一致性校验 reload。**Phase 4 起 commit 后自动调 `Storage.refresh_chunk_object_refs/1` 维护 ChunkObjectRef[] 摘要**;**apply 路径异步 dispatch damage 到 ObjectRegistry**(Task.start 避免 deadlock);**新增 `destroy_part/2` + `cleanup_object_refs/2` server-internal API**(走当前 lease 持久化,不走 lease validate)。
- ChunkDirectory 注册 chunk 到 ChunkProcess pid,负责 apply_intent 路由 + handoff prewarm + transaction prepare/commit/abort 路由(Phase 3-bis-2 起 attrs 透传 `:decision_version`);**Phase 4 加 destroy_part / cleanup_object_refs 路由**。
- TransactionCoordinator 持久化走 Postgres(`voxel_transaction_coordinator_snapshots` 单行 snapshot,Phase 3-1);**`BuildTransaction.intents_by_participant` 字段随之持久化**(Phase 3-bis-3);**Phase 4 加 `BuildTransaction.scene_objects` 字段 + `:next_object_id_fn` init opt(默认绑 SceneObjectStore.next_object_id)+ replay 路径跳过 allocation 避免 sequence 浪费**。
- TransactionExecutor 加 `:prepared` fast-path(Phase 3-bis-4);**Phase 4 加 `register_scene_objects_after_commit`**(commit_decision 之后 scene_caller.register_scene_objects/2,失败非阻塞)。
- TransactionRecoveryWatcher 对 `:prepared` 通过 `:scene_opts_resolver` 自动重发 commit dispatch(Phase 3-bis-5)。
- 0x67 PrefabPlaceIntent dispatch 切到 World 事务路径(Phase 3-3b)。
- **Phase 4 新增**:
  - `MicroLayer.owner_object_id` / `owner_part_id` 在 prefab 路径填实(intents 已支持,Phase 4 让 World 端把 BuildTransaction.scene_objects 填实)。
  - `Storage.refresh_chunk_object_refs/1`:整 chunk 重算 cell 级 + chunk 级 object refs,xxHash64 cover_hash。
  - `Storage.lookup_owner_at/3`:反向查 (macro, slot) → {oid, pid} | nil。
  - `SceneServer.Voxel.PartState`:新 struct,health/state_flags + 位常量。
  - `SceneServer.Voxel.ObjectRegistry`:per-scene GenServer(默认 module-named singleton,tests 注 `:name` 起独立实例),accumulate_damage / destroy_part / destroy_object 同步 cascade 链路。
  - `BuildTransactionApplier.register_scene_objects/2`:scene-side 把 transaction.scene_objects upsert 到 ObjectRegistry。
  - `0x6C ObjectStateDelta` wire codec encode/decode + web_client decoder stub(实际 Gate 推送链路 deferred 到 4-bis)。
- **Phase A4 新增**(跨 region prefab 事务 + 跨节点 damage / 0x6C 路由):
  - `voxel_scene_objects` schema 加 `owner_region_id` / `owner_lease_id`(字典序首
    covered_chunk 所在 region 是 owner;**不**持久化 `covered_chunks_by_region`
    —— 该信息动态,改运行时 inflate)
  - `WorldServer.Voxel.TransactionExecutor`:`:scene_opts_by_participant` map
    替换 `:scene_opts`(per-participant);`register_scene_objects_after_commit`
    给每个 obj inflate `:covered_chunks_by_region`(从 `transaction.participants
    .affected_chunks` 反向推算)
  - Gate `build_prefab_plan` per-chunk routing + 按 `(region_id, lease_id)` 分组
    成 multi-participant;任一 chunk 路由失败 fail-fast `:no_route_for_chunk`
  - `SceneServer.Voxel.ObjectOwnerLookup`:per-scene ETS cache,hot path 直读
    `:ets.lookup`,miss 走 GenServer.call SELECT;register-after-commit 写入
    准确 split,destroy_object 时 evict
  - `VoxelDamageRouter`:owner_lookup → `:scene_node_resolver_fn` 解析 owner
    scene_node → 透明 `GenServer.call({Mod, scene_node}, ..., 200ms)` 跨节点
    GenServer 协议;失败 emit `voxel_damage_cross_region_failed`,成功 emit
    `voxel_damage_routed_cross_region`
  - `ObjectRegistry.dispatch_object_state_delta`:按 `covered_chunks_by_region`
    分桶,每桶通过 `:region_routing_fn` opt 解析到 chunk_directory_target
    (default `nil` 退化为本地 `state.chunk_directory`)
  - `ObjectRegistry` + `ObjectOwnerLookup` **挂入 `VoxelSup` 生产监督树**(顺手
    补 Phase 4 起一直未挂的 ObjectRegistry)
  - Gate `executor_execute` 加 `:voxel_chunk_directory_resolver` env hook
    (default `SceneServer.Voxel.ChunkDirectory`,test 注入 fn 让 participant
    路由到不同 named instance,A4-bis-cluster 后改为走 RegionRouting)
  - `TransactionRecoveryWatcher.scene_opts_resolver` 改 1-arity 接 participants
    (multi-participant resume 自然支持,因 intents_by_participant Phase 3-bis-3
    起就持久化)
  - 决策稿草稿引用的"已有 region/lease → scene_node 映射"**事实错误**(`BeaconServer
    .Client.lookup` 当前只支持 atom resource);跨节点路径在 A4 阶段是注入式
    接口,真路由在 A4-bis-cluster 落地
- **Phase 4-bis 新增**:
  - `0x6C` codec 主战场迁到 `scene_server/voxel/codec.ex`(对齐 chunk_delta /
    chunk_snapshot / chunk_invalidate);gate codec 改 binary pass-through。
  - `PartState.flag_part_destroyed = 0x04`(完成 D5 三段 state_flags 对齐
    protocol §9)。
  - `ChunkDirectory.lookup_chunk_pid/3`:read-only,**不**lazy-start。
  - `ChunkProcess.push_object_state_delta_payload/2`(GenServer.cast)+
    `fan_out_object_state_delta_payload/2` private(镜像 push_chunk_delta)+
    observe key `voxel_object_state_delta_push`。
  - `ObjectRegistry` 在 emit_damage / emit_part_destroyed / emit_object_destroyed
    之后**同步** dispatch 0x6C broadcast(D4)。`run_destroy_object` 内 bump
    object_version 保 cascade 路径版本号单调。`:chunk_directory` init opt 注入。
  - 4 个新 observe key:`voxel_object_state_delta_dispatch` /
    `voxel_object_state_delta_push` / `voxel_object_state_delta_dispatch_failed` /
    `tcp_voxel_object_state_delta_forwarded` + `ws_voxel_object_state_delta_forwarded`。
  - gate `WsConnection` / `TcpConnection` `handle_info({:voxel_object_state_delta_payload, payload}, ...)`
    forward to socket(同 chunk_delta forward 模式)。
  - **web_client**:
    - `ObjectStateDeltaConsumer`(per-object_id `last_seen_version` 去重
      + `onDelta` / `onDuplicate` 钩子)
    - `ClearedSlotCache`(per-object slots Map + TTL 2s sweep + 单 object 上限
      256;**production cache hook 推到 Phase 5**,目前数据结构 + pipeline
      已就位但 ChunkDelta apply 前 hook 未接,因为 FRefinedCellData 不含
      ownerObjectId)
    - `DebrisSimulation`(纯数据状态机,半球面随机 + 重力 + lifetime + 全局
      上限 500)
    - `DebrisRenderer`(InstancedMesh 包装,棕色 0.05m × MacroWorldSize 立方体)
    - `OnlineVoxelWorldAdapter` 持有 cache + sim,onFrame 顺序
      tickDebris → drainVoxelMessages → processObjectStateDeltaRetryQueue;
      consumer onDelta 钩子调 handleObjectStateDeltaForDebris(cache.take →
      spawn / 100ms retry / affected_chunks_fallback);emit
      `world:object-state-delta` event
    - `RenderOrchestrator` 通过 duck typing 在构造时检测
      `world.getDebrisSimulation`,实例化 DebrisRenderer 并挂到 rootGroup;
      onFrame 调 syncFromSimulation
    - `HudView` 订阅 `world:object-state-delta` event,destroyed flag 时
      `showFlash("object #N destroyed (M debris)")` 3.5s
- 客户端在线模式:storage.refinedCells 仍然是 `FRefinedCellData[]`(lossy 自 wire);Phase 1c-5 决策 5 RFC 备注了"未来改 wire-form-as-truth"。
  **特别注意**(Phase 4-bis):由于 FRefinedCellData 不携带 ownerObjectId,
  ClearedSlotCache 的 ChunkDelta apply 前 hook 还没接,debris 粒子目前
  全走 affected_chunks_fallback(chunk 中心点散开)。Phase 5 接 owner 进
  FRefinedCellData 后可升级到精确档 B(沿 micro slot 散布)。

### 前端策略冻结(2026-04-26)

- 唯一在迭代的客户端是 `clients/web_client`(memory `client_focus.md` 2026-05-07 起;CLAUDE.md 旧条目作废)。
- `clients/bevy_client` 已冻结。

## 关键文件锚点

| 用途 | 路径 |
| --- | --- |
| 阶段总表 | `docs/10-active/cross-cutting/voxel-server-authority-phase-overview.md` |
| 协议设计参考(权威) | `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` |
| 线协议规范 | `docs/2026-04-10-线协议规范.md` |
| 体素 chunk 进程 | `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` |
| 体素 chunk 目录 | `apps/scene_server/lib/scene_server/voxel/chunk_directory.ex` |
| Codec / chunk_hash | `apps/scene_server/lib/scene_server/voxel/codec.ex` |
| Storage(canonical truth) | `apps/scene_server/lib/scene_server/voxel/storage.ex` |
| **Object provenance(Phase 4)** | `apps/scene_server/lib/scene_server/voxel/object_registry.ex`、`apps/scene_server/lib/scene_server/voxel/part_state.ex` |
| **Owner lookup cache + 跨节点 damage 路由(Phase A4)** | `apps/scene_server/lib/scene_server/voxel/object_owner_lookup.ex`、`apps/scene_server/lib/scene_server/combat/voxel_damage_router.ex` |
| Postgres 持久化(1d 后) | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` |
| **Postgres scene_objects(Phase 4)** | `apps/data_service/lib/data_service/voxel/scene_object_store.ex`、`apps/data_service/lib/data_service/schema/voxel_scene_object.ex`、`apps/data_service/priv/repo/migrations/20260508000002_create_voxel_scene_objects.exs` |
| Gate 协议 codec | `apps/gate_server/lib/gate_server/codec.ex` |
| Gate ws/tcp dispatch | `apps/gate_server/lib/gate_server/worker/{ws,tcp}_connection.ex` |
| World map ledger | `apps/world_server/lib/world_server/voxel/map_ledger.ex` |
| **World transaction(Phase 4 加 scene_objects)** | `apps/world_server/lib/world_server/voxel/build_transaction.ex`、`apps/world_server/lib/world_server/voxel/transaction_coordinator.ex`、`apps/world_server/lib/world_server/voxel/transaction_executor.ex` |
| Web client 在线 adapter | `clients/web_client/src/voxel/onlineVoxelWorldAdapter.ts` |
| Web client wire decoder | `clients/web_client/src/infrastructure/net/refinedCellWire.ts`、`voxelEditIntent.ts`、`voxelProtocol.ts`、`objectStateDelta.ts`(Phase 4)、**`objectStateDeltaConsumer.ts`(Phase 4-bis)** |
| **Web client 碎屑粒子(Phase 4-bis)** | `clients/web_client/src/voxel/clearedSlotCache.ts`、`debrisEffect.ts`(simulation)、`debrisRenderer.ts`(InstancedMesh) |
| **Web client HUD(Phase 4-bis 起订阅 world:object-state-delta)** | `clients/web_client/src/presentation/hud/hudView.ts` |

## 这次会话产出(2026-05-09,Phase A2 + A1 + 性能优化 + hotfix)

A2 8 个 + A1 10 个 + A2 hotfix 1 + A1-1b 1 + watcher hotfix 1 = **21 个 commit**,
本地 master 未 push:

性能优化 + hotfix(后段加的):
```
cc3a31d   voxel(hotfix): TransactionRecoveryWatcher 接 plain-map stale snapshot
0e3434c   voxel(A1-1b): Storage batch micro_block API(prefab 卡死性能优化)
58a7a9e   voxel(A2 hotfix): 同步 client DEFAULT_MOVEMENT_PROFILE 到 A2 新值
```

A2(尺寸真实化):
```
730e6e7   docs(voxel): finalize Phase A2 (status + README + handoff)
fb69661   voxel(A2-6): magic number sweep
630d257   voxel(A2-5): scene_ops capsule 单位修正(米 → cm)
03690c0   voxel(A2-4): movement_core unit test 跟随新 profile + 注释 sweep
ef5d524   voxel(A2-3): movement profile 默认值调到现实人体数值
05cebdf   voxel(A2-2): camera 参数适配 1.7m 角色
aec8a98   voxel(A2-1): AvatarConstants + avatar mesh / ring 调到 1.7m 角色
6144408   docs(voxel): land Phase A2 plan (real-world scale)
```

A1(客户端可玩 demo 必须线):
```
本会话    docs(voxel): finalize Phase A1 (status + README + handoff)
7932fe2   voxel(A1-5): 破坏技能 → voxel damage 路由(combat 接 ObjectRegistry)
133bb85   voxel(A1-4): jump arc e2e smoke (ground_z 锁定 + apex 验证)
b692ab1   voxel(A1-4): movement ack 加 ground_z(jump arc 同步基础)
b2fe630   voxel(A1-3): prefab preview 沿 micro mask(回归测试)
14c90a9   voxel(A1-2): prefab 防覆盖(prepare-stage occupancy reject)
a4616e9   voxel(A1-1): e2e smoke (sphere prefab → 280 slots, mask pixel-perfect)
d399f7c   docs(voxel): A1-1 进度日志 + 性能 backlog(A1-1b)
0275899   voxel(A1-1): prefab catalog v2 (sphere/cylinder/stairs micro mask)
edbfbda   docs(voxel): land Phase A1 plan (playable client experience, merged)
```

A2 + A1 的核心收益:

- **角色尺寸**:1.2m → 1.7m(`AvatarConstants` 集中常量)
- **跑速**:2.2 m/s → 6 m/s(`max_speed` 600,UE CMC 对齐)
- **跳跃**:wire 端到端 ack.ground_z 锁定 launch z + apex 96cm 实测
- **scene_ops capsule** 米单位 latent bug 修了
- **prefab catalog**:v1 macro list → v2 micro mask(sphere/cylinder/stairs),
  服务端 BlueprintCatalog 跟客户端 prefab/definitions.ts 像素级对齐 + 持久化
  e2e smoke 验证
- **prefab 防覆盖**:prepare 阶段 occupancy reject,fence 未写入 → zero-cost
  cleanup,wire reason unwrap 成裸 atom,客户端 HUD flash 提示
- **prefab 线框预览**:沿 micro mask 描边,A1-1 切 hotbar 后自动正确,加
  regression test 立成契约
- **破坏技能**:CombatExecutor.resolve_cast 之后 PlayerCharacter 并行 dispatch
  voxel damage(actor / voxel 双轨),target_position → ChunkSnapshotStore →
  Storage.lookup_owner_at → ObjectRegistry.accumulate_damage,自动 fan-out 0x6C
  ObjectStateDelta(Phase 4-bis 链路)+ 客户端碎屑粒子

后段三个 hotfix:

1. **A2 hotfix**(`58a7a9e`):用户实测发现移动延迟严重 — 根因是 A2 commit
   `ef5d524` 改了 server `MovementProfile.default/0` 但**漏改 client
   `clients/web_client/src/domain/movement/profile.ts` `DEFAULT_MOVEMENT_PROFILE`**。
   Client predict 用旧 220 cm/s,server 真实 600 cm/s,每个 ack 触发 reconcile
   把 client 向前 snap ~38cm,体感 = 100ms 延迟。修法:client profile.ts
   整套跟 server 同步;profile.test.ts 断言更新(本来名字就是"matches the
   authoritative SceneServer movement defaults",讽刺地 A2 时漏跑这个测试)。
   **教训**:任何 movement profile 改动都必须同步 3 处:profile.ex /
   profile.rs / profile.ts。

2. **A1-1b**(`0e3434c`):用户实测发现"右键放 prefab 整服务器卡死,移动也
   被阻塞 1.5-2s"。根因不是网络/wire,是 Elixir 端 algorithmic O(N²)。
   旧路径每次 `Storage.put_micro_block` 调 `normalize!(storage)`(整 4096
   macro_headers list rebuild)+ List.replace_at(O(N)),sphere 280 slots 跑
   ~1.5s。期间 ws_connection / chunk_process GenServer 邮箱被锁,同玩家所有
   movement input ack 等 prefab 完成才发,体感"整服务器卡死"。修法:加
   `Storage.put_micro_blocks/4` 一次性接 N 个 (slot, layer_attrs),按 attribute
   signature 分组合并 → 1 次 normalize + 1 次 List.replace_at。算法 O(N²) →
   O(N + macro_count)。`ChunkProcess.build_intents_storage` 加
   `detect_micro_block_batch/1` fast-path 检测 single-macro micro batch 走
   batch API,否则 fallback 到旧逐 intent reduce 路径。**实测 1.5s → 46ms
   (33×)**,7 个新 unit test 验证 batch 跟 N×sequential 像素级等价。
   **不需要 Rust NIF**(这是 algorithmic fix 不是常数优化,Rust 也写不出
   O(1) normalize)。

3. **Watcher hotfix**(`cc3a31d`):用户重启 server 时 crash —
   `TransactionRecoveryWatcher.handle_transaction/3` 收到 plain map(不是
   `%BuildTransaction{}` struct)的 stale snapshot 时 FunctionClauseError,
   watcher init 失败 → WorldSup 起不来 → world_server.Application crash →
   整 umbrella shutdown。根因:Phase 3-bis-3 / Phase 4 给 BuildTransaction
   defstruct 加了 `intents_by_participant` / `scene_objects` 字段,旧 stale
   blob 反序列化字段不全 fallback 成 plain map,所有 struct-pattern clause
   miss。修法:加 `not is_struct(stale, BuildTransaction)` catchall clause,
   plain map 直接 `abort_decision` + emit `voxel_transaction_recovery_stale_*`
   observe event。Backlog:**BuildTransaction snapshot schema_version 化**
   是更彻底的修法。

backlog:
- ~~**A1-1b** Storage.put_micro_blocks/4 batch API(已完成 `0e3434c`)~~
- **测试隔离**:test_helper 加 setup TRUNCATE 几张 voxel 表(本会话多次踩到
  stale snapshot 让 transaction 走 replay-skip 路径让 e2e smoke 失败假象,
  得 fresh DB 才能 verify)
- **BuildTransaction snapshot schema_version 化**:防止下次再加字段时 stale
  blob 又 plain map(catchall hotfix 是 band-aid)
- **A3** 多客户端联调

A2 之前的所有 Phase 1a → 4-bis commits(完整列表见上一个会话的 handoff)。

## ⚠️ 跨会话恢复优先动作

下个会话开始,**先确认这三条**:

1. **用户能否成功重启 server**(watcher catchall hotfix `cc3a31d` 后通常能起;
   如果 crash,可能是更深层 stale shape — 已知 `cc3a31d` catchall 只匹配带
   `transaction_id` key 的 plain map,但仍有可能见到只带 `state + decision_version`
   两个 key 的 stale,触发 FunctionClauseError → world_server 起不来 → umbrella
   shutdown)。临时修法:`cmd /c mix run --no-start scripts/truncate_voxel_tables.exs`
   清表(scripts 目录已有,untracked)。根治候选:**TransactionCoordinator
   `validate_persisted_payload` 拒绝任何 inner transactions value 不是
   `%BuildTransaction{}` 的 stale payload,让 coordinator 启动空状态而不是
   把 plain-map stale 喂给 watcher**(handoff backlog,与 BuildTransaction
   schema_version 化是同一根因)。

2. **用户重启后能否流畅放 prefab + 摆放位置和线框预览像素级一致**:
   - 流畅性靠 A1-1b batch API(33×)
   - 精度靠 prefab micro-precision hotfix(`a7a5bc9` + `20f6a8a`)
   - 如果摆放位置和线框还有偏差:对比 client `world:prefab-boundary-snap-committed`
     event 里的 `anchorMicroCoord` vs server `voxel_chunk_transaction_committed`
     log 里 intent 起点(macro+slot 还原成 world micro 应该完全相等)

3. **~~多 chunk prefab 跨 region 警告~~**:**Phase A4 主体已闭环**(2026-05-10)。
   mid-macro 锚把 prefab 摆在 chunk 边界附近跨两 chunks 时,gate `build_prefab_plan`
   会按 `(region_id, lease_id)` 分组成 multi-participant,World coordinator
   begin_transaction 持 N 个 participant,executor 走 multi-participant prepare
   + commit 路径,任一 prepare 失败 fail-fast abort。Storage 在两 chunk 都被
   写,scene_objects 在 owner participant(字典序首 chunk 所在 region)的
   ObjectRegistry 注册。生产仍单 scene_node(所有 region 跑同一 BEAM),真
   分布式部署在 A4-bis-cluster 阶段。

如果以上都 OK,可以推进:
- **A4-bis-cluster**(真多 scene_node 部署,MVP 必需。**A4-bis-1 已完成本会话**:`BeaconServer.Client.register/lookup/await` 签名升级为 `term()`,所有 caller 无代码改动直接兼容;新增 5 个 term key 单测全绿。剩 A4-bis-2~6 + A4-bis-final,3.5-5 天)
- **A3** 多客户端联调
- **Phase 5** 属性目录 + 温湿度

## ⚠️ A4-bis 期间已知非 regression 失败

- `apps/gate_server/test/gate_server/ws_connection_voxel_cross_region_test.exs` 第二个 test 在 `__ex_unit_setup_0/1` 注册 region_b 时偶现 `:region_bounds_overlap`。根因:`MapLedger` fixture 用 `ensure_started!` 走全局 named singleton,跨 2 个 test 的 setup 重复注册同 bounds region(region_id 是 `System.unique_integer/1` 唯一,但 bounds_chunk_min/max 是同一对常量),`validate_region_bounds_available` reject。**与 BeaconServer.Client term key 升级无关**。修法候选:fixture `on_exit` 清理 MapLedger 注册,或每 test 用不同 bounds(连同 anchor 偏移)。A4-5 progress log 标的"3 fail → 3 fail"应该是当时 CI 漏拍此 fail。**留 A4-bis 期间 backlog**,本会话不动以免 scope creep。
