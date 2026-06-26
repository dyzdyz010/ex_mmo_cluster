# Voxia UE 5.8 Client Roadmap

Date: 2026-06-25
Scope: `clients/Voxia`
Status: active implementation / UE-1 transport baseline

## Goal

Build Voxia as the Unreal Engine 5.8 client for `ex_mmo_cluster`, aligned with
the server-authoritative movement, voxel, prefab, object-state, and local field
runtime architecture already exercised by `clients/web_client`.

Voxia is not a replacement authority. It is a native presentation and input
client whose confirmed runtime state must come from server snapshots, deltas,
acks, and typed result messages.

## Current Decisions

1. Unreal MCP is the default editor automation surface for Voxia development.
2. Codex should be launched from the umbrella repository root; root MCP config
   mirrors the Voxia-local Unreal MCP endpoint.
3. Unreal MCP remains in tool-search mode. Agents must discover toolsets through
   `list_toolsets`, inspect with `describe_toolset`, and dispatch with
   `call_tool`.
4. C++ semantic MCP will use `clangd` + `mcp-cpp-server` once `clangd.exe` is
   installed. Until then, the config is documented but disabled.
5. Voxia implementation must be staged around observable slices, not viewport
   polish.

## Phases

### UE-0 MCP And Tooling Bootstrap

Deliverables:

- Root `.mcp.json` and `.codex/config.toml` discover `unreal-mcp` from the
  umbrella root.
- Voxia-local `AGENTS.md` documents UE/MCP workflow and authority constraints.
- `clients/Voxia/scripts/setup-clang-mcp.ps1` diagnoses clangd MCP prerequisites.
- UE generated directories are ignored by `clients/Voxia/.gitignore`.

Acceptance:

- `http://127.0.0.1:8000/mcp` responds to MCP `initialize`.
- `tools/list` returns the Unreal MCP tool-search meta-tools.
- Future agents can read `clients/Voxia/AGENTS.md` before editing Voxia.

### UE-1 Transport And Codec Baseline

Deliverables:

- Dev login bootstrap against `auth_server`.
- Gate TCP transport with `{packet, 4}` framing.
- Binary codec module with golden fixtures cross-checked against Elixir and
  `clients/web_client`.
- UE console commands and JSONL observe events for connection state, sent
  frames, received frames, decode errors, and auth/enter-scene state.

Acceptance:

- Headless/automation test can connect, authenticate, enter scene, and export a
  structured transport snapshot.
- Decode failures return explicit diagnostics and never masquerade as success.

### UE-2 Movement Runtime

Deliverables:

- Local input collection and prediction.
- Authoritative ack/snapshot reconciliation.
- Remote actor interpolation from AOI snapshots.
- Observe events for prediction frame, ack, reconcile delta, remote update, and
  disconnect reason.

Acceptance:

- Two-client smoke can show one Voxia client and one existing client observing
  movement through the server path.
- Movement remains server-authoritative; local state is marked predicted until
  confirmed.

### UE-3 Voxel Truth Consumer

Deliverables:

- Chunk subscribe.
- Chunk snapshot/delta application.
- Voxel edit intent submission and `VoxelIntentResult` handling.
- Confirmed runtime store separate from preview/pending edits.

Acceptance:

- UE console command can subscribe a chunk, dump confirmed cell state, submit an
  edit intent, and show the server result with explicit success/failure reason.
- No local edit path mutates confirmed truth without a server result.

### UE-4 Prefab, Object State, And Field Overlay

Deliverables:

- Prefab placement intent path matching server protocol.
- ObjectStateDelta consumption and object provenance visualization.
- FieldRegionSnapshot/field destroy handling and first overlay visualization.
- Field source/effect observe output.

Acceptance:

- Conductive path / field overlay scenario can be triggered from a real user
  input, automation test, and console command, with evidence written to
  `.demo/observe/`.

## Verification Matrix

- UE build: `Build.bat VoxiaEditor Win64 Development -Project=... -WaitMutex`
- UE automation: focused Automation tests for codec, transport, store reducers,
  movement reconcile, voxel snapshot/delta, and field overlay reducers.
- Server parity: relevant `mix test` files for protocol changes.
- Web parity: `clients/web_client` tests when protocol or voxel/field semantics
  are touched.
- Smoke: cross-client movement/voxel smoke once UE-2/UE-3 are available.

## Progress Log

- 2026-06-25: Created UE-0 tooling baseline. Confirmed Unreal MCP endpoint
  responds on `http://127.0.0.1:8000/mcp`; tool-search mode exposes
  `list_toolsets`, `describe_toolset`, and `call_tool`. Added root MCP config,
  Voxia local instructions, README, generated-directory ignore rules, and clangd
  MCP setup script.
- 2026-06-26: Started UE-1. Added `Source/Voxia/Net` with big-endian
  `{packet,4}` frame codec, dev `auto_login` HTTP bootstrap, gate TCP transport,
  downlink summary decode, JSONL observe output, Automation self-test, and UE
  console commands for auth/connect/enter-scene/heartbeat/time-sync/chat/one-shot
  movement input. UBT compiled the touched C++ files; final link was blocked by
  the running editor holding `Binaries/Win64/UnrealEditor-Voxia.dll`.
- 2026-06-26: Installed `mcp-cpp-server` via Cargo and prepared
  `.vscode/compile_commands.json` for clangd-compatible tools. LLVM/clangd
  installation via winget reached the installer but returned `0x800704c7`
  (`operation canceled`), so the `cpp-clangd` MCP remains documented but
  disabled until `clangd.exe` is available.
- 2026-06-26 (verify loop + codec parity): Established the headless build/test
  loop with the editor CLOSED — `Build.bat VoxiaEditor` compiles/links, and
  `UnrealEditor-Cmd <uproject> -ExecCmds="Automation RunTests Voxia; Quit"
  -unattended -nullrhi -ReportExportPath=Saved\AutomationReport` runs Automation
  tests headlessly (read `index.json`). **Editor-open vs editor-closed are
  mutually exclusive**: the MCP server runs inside the editor, so it's only
  reachable while the editor is open (which locks the editor DLL and blocks
  `Build.bat` linking). Workflow: write C++ → close editor → Build + Automation
  test; open editor → MCP for material/UMG/level/sky authoring.
- 2026-06-26 (MCP toolsets): enabled the editor MCP toolset plugins in
  `Voxia.uproject` — `EditorToolset` (ActorTools/SceneTools/MaterialInstanceTools/
  ObjectTools), `UMGToolSet`, `AutomationTestToolset`, `LiveCodingToolset`,
  `GameplayTagsToolset`, `SlateInspectorToolset`, plus `ToolsetRegistry`. Before
  this only `AgentSkillToolset` was exposed; now the editor (when open) exposes
  rich actor/material/UMG/automation control over `http://127.0.0.1:8000/mcp`
  tool-search (`list_toolsets`/`describe_toolset`/`call_tool`).
- 2026-06-26 (UE-1 codec parity advanced): audited `VoxiaProtocol` byte layouts
  against the authoritative server codec (`gate_server/codec.ex`) + bevy
  `protocol.rs` + the wire spec. Existing encodes (auth/enter-scene/movement/
  heartbeat/time-sync/chat) and the 0x80–0x8F summary-decode offsets were already
  byte-correct (built from the codec, not the stale doc — e.g. MovementAck = 104
  bytes with trailing `ground_z` f64, not the doc's 96). Added the missing C→S
  encoders: SkillCast 0x09 (44 B), FastLaneRequest 0x06, FastLaneAttach 0x07,
  ChunkSubscribe 0x60, ChunkUnsubscribe 0x61, VoxelEditIntent 0x70 (92 B, OCC
  sentinels). Extended decode: full motion (velocity/accel/mode) on PlayerMove
  0x83 + MovementAck 0x8B (+ correction_flags + ground_z), health on PlayerState
  0x8C; new typed decoders `DecodeChunkInvalidate` (0x69) and
  `DecodeVoxelIntentResult` (0x68 header). All covered by byte-exact + round-trip
  asserts in `Voxia.Protocol.FrameAndHandshake` — **build green, 1 test Success**.
  Remaining UE-1 codec: full ChunkSnapshot 0x62 section parsing, ChunkDelta 0x63
  ops, FieldRegionSnapshot 0x73 (LE-f32 value arrays) / 0x74, ObjectStateDelta
  0x6C, and the 0x68 authoritative-cell array + reason tail; then golden-fixture
  cross-checks vs `apps/scene_server/priv/fixtures/voxel/*.golden`.
- 2026-06-26 (Voxia 独立仓库 + 体素 truth wire 解码完成 + 对抗审计):
  `clients/Voxia` 设为独立 git 仓库(`git init`,与 umbrella 分离;umbrella .gitignore
  忽略它)。逐点 commit、每点 Build + Automation 测试:ChunkSnapshot 0x62(header +
  MacroHeaders/NormalBlocks + 鲁棒 TLV 段框架)、ChunkDelta 0x63(CellEmpty/Solid/
  Refined ops)、FieldRegionSnapshot 0x73(小端 f32 值数组 + 线序 temp→potential→
  current→ionization→light→light_color)+ FieldRegionDestroyed 0x74、
  ObjectStateDelta 0x6C。全部 round-trip 自检过。**对抗审计(11 agents 跨检 UE 字节
  布局 vs 权威服务端 codec.ex/scene_server voxel codec/field_codec.ex):0 个确认字节
  失配,逐组 all_correct=true** —— 证明 round-trip 之外的服务端 parity(对称偏移 bug
  也被排除)。UE-1 codec 主体完成;剩 RefinedCells/attribute 段深解、0x68 authoritative
  尾、golden fixture 为后续精修。
- 验证回路:编辑器关时 `Build.bat` + `UnrealEditor-Cmd ... Automation RunTests Voxia`
  全自动;MCP 在编辑器内(与 Build 互斥),材质/UMG/天空(Ultra Dynamic Sky 已装)走
  开编辑器 + MCP。
- 2026-06-26 (UE-3 体素 truth consumer 地基):新建 `Source/Voxia/Voxel/
  VoxiaVoxelStore`——server-authoritative confirmed chunk store:ApplySnapshot(整块
  替换)、ApplyDelta(**版本闸门**:仅 held==BaseChunkVersion 才应用,失配不动+返回
  re-subscribe 原因)、Invalidate、DumpChunk;Automation `Voxia.Voxel.Store` 覆盖
  快照/版本闸门/delta/invalidate。`VoxiaTransportSubsystem` 接入:Poll 收帧先按
  opcode 路由 ApplyInboundVoxel(0x62→store,0x63→版本闸门,0x69→Invalidate,
  0x68/0x6C/0x73/0x74→观测),非体素落控制面 summary。新增 BlueprintCallable +
  console:`Voxia.Voxel.Subscribe/Dump/Edit`(EncodeChunkSubscribe/EncodeVoxelEdit-
  Intent;store 只随服务端结果变,无本地绕过)。每点 Build 绿 + 2 个 Automation 测试过。
  **UE-3 验收(console 订阅/dump/编辑→服务端结果)结构上达成**;剩:把 store 渲成可见
  体素(需 PIE/材质)、RefinedCells 深解、连真服务端 live 烟测。
- 状态小结:UE-1 codec 主体完成(对抗审计 0 失配)、UE-3 truth store/wiring/console
  完成。下一阶段:体素网格渲染 + 材质、UE-2 移动运行时(纯 C++ 可测)、HUD(UMG)、
  Ultra Dynamic Sky 接入(需开编辑器走 MCP)。
- 2026-06-26 (UE-2 移动 + 可玩骨架 + 实机连真服务端):
  - `FVoxiaMovementRuntime` 预测/权威重对齐(PushInput 本地积分 + ack 丢帧+replay,
    LastCorrectionDistance),Automation `Voxia.Movement.Reconcile` 过;接入 transport
    live 路径(EnterScene Reset、SendMovementInput PushInput、MovementAck ApplyAck、
    PlayerEnter/Move/Leave 维护 RemoteActors)。
  - 可玩骨架:`AVoxiaPawn`(相机+输入,BeginPlay 驱动 bootstrap auto-login→connect→
    enter→subscribe,WASD→SendMovementInput,每帧贴服务端预测位置)、`AVoxiaWorldActor`
    (ISM cube 渲染 confirmed store,按 revision 重建)、`AVoxiaClientGameMode`;
    VoxiaCoords sim↔UE;输入轴 + GlobalDefaultGameMode 配置;周期心跳/time-sync 保活。
  - **实机 `-game` 连真服务端验证(`.demo/observe/voxia-transport.jsonl`):auto_login→
    connect→authenticated→enter_scene(spawn 750,750,185)→voxel_subscribe→
    voxel_snapshot_applied(4096 满块 macro,0 解码错误)→remote PlayerEnter/Move→
    movement 持续 + 心跳/time-sync 回复。** = 连接/进场/收体素 truth/收远端/发移动的
    **核心可玩闭环已通**。
  - **已知未解(下一步)**:初次 burst(~4s)后服务端对本连接转静默(连心跳回复都停),
    仅收到 1 个 chunk(玩家自身 chunk 0,0,0 未到,仅角 chunk -2,-2,-2)。最可能因:未接
    **UDP fast-lane**(服务端进场后把 AOI/移动 ack/体素 delta 路由到 fast-lane,bevy
    客户端会 FastLaneRequest→Attach;Voxia 仅 TCP)。下一步:实现 UDP fast-lane 握手 +
    路由,解锁持续世界流式 + 移动 ack 重对齐;之后材质/天空(UDS)/HUD/专用地图(需开
    编辑器走 MCP)。

- 2026-06-26 (UE-4 材质/天空/HUD + 服务端出生修复 = **客户端达「可玩」**):
  - **材质上色**：`VoxiaMaterialPalette.h` 逐字节镜像 bevy `material_color`(1-21 + 未知→
    magenta），`AVoxiaWorldActor` 每实例写 3×PerInstanceCustomData(RGB)；经编辑器内
    MCP MaterialTools 授权 `/Game/Voxia/Materials/M_VoxelInstanced`
    (`PerInstanceCustomData3Vector`→BaseColor)并保存。Automation `Voxia.Voxel.Palette` 过。
  - **天空/灯光 + HUD 走纯 C++**（MCP `load_level`/duplicate World Partition 图会崩编辑器，
    弃用）：`VoxiaClientGameMode::SetupEnvironment` 运行时剥离宿主图静态天空/灯光再 spawn
    `Ultra_Dynamic_Sky`；`VoxiaHUD:AHUD::DrawHUD` 画布画连接/位置/chunk/帧状态，零资产。
  - **服务端交叉修（解锁可玩）**：旧出生 `{750,750,185}` 假设 DevSeed 平台，但 noise
    WorldGen 地表在该列 z≈7900，玩家被埋实心石头→全黑。`player_character.ex`
    `maybe_lift_to_surface/1` 抬升到地表（主仓 commit 4ad697a）。
  - **实机 `-game` 验证**（截图为证）：EnterSceneResult z 由 185→**7985**（地表），画面由
    全黑→**Ultra Dynamic Sky 蓝天白云 + 上色体素地形 + HUD 的可玩视图**，125 chunk 流式，
    持续心跳。移动仅在输入变化时发（stop-spam 是早先静默/黑屏根因，非 UDP fast-lane）。
  - 本机服务端用 `scripts/dev-server-headless.ps1`（PHX_SERVER=true 绑 auth/visualize 端点 +
    EX_MMO_DEV_RELOAD=0 过 compile-env 校验）。
  - **待做（非阻塞可玩）**：相机俯角、RefinedCells 深解 + 0x68 尾 + golden fixture、UDP
    fast-lane、Lumen 超订（greedy meshing）、ObjectStateDelta/field 渲染、远端玩家可视化。

- 2026-06-26 (高性能体素 + 8km 可视 + 服务端权威地形直接同步):
  - 用户给视频字幕(`clients/Voxia/docs/reference/voxel-perf-video.{en,zh}.srt`)+ 指令
    `docs/2026-06-26-voxel-perf-optimization-directive.md`。
  - **贪婪网格化**替换 per-macro ISM(面剔除+合并同材质共面 quad,顶点色,
    UProceduralMeshComponent+M_VoxelVertexColor):满块 chunk 4096 实例→表面少量 quad;
    125 chunk→66 section/946 quad。Automation Voxia.Voxel.GreedyMesher。
  - **相机俯仰不设限**(AVoxiaCameraManager ±89.9 + 专用 controller)。
  - **8km 地形 = 服务端权威 heightmap 直接同步**(用户拍板:客户端不本地生成):新协议
    0x6A 请求/0x6B region(gate 调 WorldGen.heightmap_region,u8 高度扁平),pawn 进场
    请求 8km(1000×16m)、移动超 1/3 半径重心化重请求(32km 可横穿);
    FVoxiaHeightmapMesher 渲成连续共享顶点曲面(梯度法线)。实跑 8km 可见、FPS~53
    (瓶颈=Lumen+UDS,非几何;用户暂不动渲染)。
  - 服务端格点哈希 phash2→可移植 SquirrelNoise(支持过 golden 验证,后客户端不再本地
    生成→删休眠 FVoxiaWorldGen)。
  - golden-fixture 跨语言 parity(Voxia.Voxel.GoldenParity)、HUD FPS 读数。
  - 测试 6/6:Movement/Protocol/GreedyMesher/Palette/Store/GoldenParity。
  - **待做**:Lumen/UDS 画质-帧率取舍、距离雾、LOD 分级(近细远粗)、voxel 编辑交互
    (挖/建,需鼠标验证)、远端玩家可视化(需 2 客户端)、ObjectStateDelta/field 渲染。
