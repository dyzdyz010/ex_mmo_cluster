# ex_mmo Voxel Web Client

一个浏览器端客户端验证面，与 `clients/bevy_client/` 并列。当前阶段的主目标不是 voxel 联机，而是：

1. **验证 movement sync**：浏览器直接接 `auth_server -> gate_server` 的 browser bridge，确认 prediction / ack / reconcile / remote snapshot 没问题
2. **保留离线 voxel 世界**：把体素世界作为本地承载层和调试面，不参与当前阶段的服务端同步
3. **保留后续扩展位**：等 movement 路径稳定后，再接 `SceneServer.Voxel.*` 服务端权威体素链路

> 定位：优先服务于 movement 联调与回归验证的浏览器客户端。当前不把 voxel online 作为交付目标。

## 当前状态修正

当前仓库里的 `web_client` 已不再只是 W-A 占位：

1. 已有多 Chunk 浏览器内置演示世界，使用真正的 `ChunkStorage -> chunk mesher -> BufferGeometry` 路径。
2. voxel 当前明确保持 **offline-local**：中心准星命中面选中、本地左键破坏 / 右键放置（`F/G` 仍可用），底部 hotbar dock 可点击并支持滚轮切换材质 / builtin prefab，但不走服务端同步。
3. 已有浏览器版可观测调试面：
   - HUD 持续显示关键状态
   - `window.__voxelCli.run("<command>")` 作为 CLI 命令入口
   - `window.__voxelObserve.recent()` / `snapshot()` 读取结构化日志
4. 已有真实 browser movement bridge：
   - `POST /ingame/auto_login`
   - `GET /ingame/ws`
   - `AuthServerWeb.GameWebSocket -> GateServer.WsConnection`
5. 已有 `simulated-local` 同步 demo：
   - fixed-tick 本地预测
   - 权威 ack 对账
   - 本地渲染平滑
   - 不再生成装饰性远端 actor；远端玩家插值只由真实 AOI / snapshot 输入驱动

仍未完成：

1. 当前真实 browser bridge 覆盖的是 auth / enter-scene / movement，这正是当前阶段的主验证目标。
2. voxel 现在故意保持离线，本阶段不接 `SceneServer.Voxel.*` 的 `ChunkSubscribe / ChunkSnapshot / ChunkDelta / EditAck`。
3. Prefab 已有浏览器本地 Definition/Instance 首版：内置 `builtin_sphere`、
   `builtin_cylinder`、`builtin_stairs` 使用 refined micro occupancy；`prefab_capture`
   生成玩家模板定义，`prefab_place` 生成量化旋转实例并写入 Chunk truth。
   Prefab definition 保留 `partDefinitions / microPartIds`，实例化后拍扁为带
   part tag 的 refined micro 数据，供后续魔法和局部破坏按部件语义结算。
   选中 prefab 时，准星命中已有体素表面会显示低成本 micro-wire boundary snap
   preview；右键 / `F` 会优先按整数 world micro anchor 做 socket-free 边界贴合，并用
   真实 rasterize 后的 micro occupancy 作为线框预览。socket 只保留为可选语义兼容层。
4. 微格治理已有浏览器端首版：refined cell 当前按 `8x8x8` micro payload 量化；
   mesher 会剔除相邻 micro 的内部面；CLI 只读取 `micro_cell` 用于检查 prefab/refined 内部数据，
   不把 micro 暴露成可放置的玩家方块。Prefab snap commit 使用事务式 overlap check
   和 refined union：不同 micro slot 可共存，任意 occupied slot 重叠则整次放置拒绝。

## 技术栈

| 模块 | 选型                  | 理由                                           |
| ---- | --------------------- | ---------------------------------------------- |
| 构建 | Vite 8 + TypeScript 5 | 热更新秒级，原生 ES module                     |
| 渲染 | three.js 0.184        | WebGPU 优先，WebGL 可回退，voxel 生态成熟      |
| 网络 | WebSocket + DataView  | 对齐服务端 `{packet, 4}` 长度前缀 + big-endian 二进制 |
| 语言 | TypeScript strict     | 类型结构对齐 UE USTRUCT                        |

浏览器目标：Chromium 最新两个版本（调试用，不做兼容下探）。

## 目录结构

```
clients/web_client/
├── index.html
├── package.json
├── tsconfig.json
├── vite.config.ts
└── src/
    ├── main.ts                     # 入口：wires scene + net + input
    ├── render/
    │   └── scene.ts                # three.js 场景 / 摄像机 / 灯光
    ├── net/
    │   └── opcodes.ts              # VoxelOpcode 0x60..0x69
    └── voxel/
        ├── core/
        │   ├── constants.ts        # VoxelConstants（浏览器本地 refined/prefab 量化参数）
        │   ├── types.ts            # FChunkCoord / FMacroCoord / 枚举
        │   └── gridUtils.ts        # divideFloor / coord 换算
        ├── microgrid/
        │   └── governance.ts       # Micro occupancy 治理与 SolidBlock refine 转换
        ├── storage/
        │   ├── types.ts            # FNormalBlockData / FMacroCellHeader / FChunkStorageData
        │   └── chunkStorage.ts     # 运行时 Chunk 镜像 + 写入 API
        └── meshing/
            └── types.ts            # FChunkMesherInputSnapshot
```

## 与 UE test1 的映射约定

| UE 符号                         | Web 符号                                   | 注意                                                      |
| ------------------------------- | ------------------------------------------ | --------------------------------------------------------- |
| `VoxelConstants::MicroPerMacro` | `VoxelConstants.MicroPerMacro`             | 浏览器本地为 8；server v1 canonical 也为 8；UE `test1` 的 4 只作为历史参考 |
| `FChunkCoord`                   | `FChunkCoord` 接口                         | int32 语义，允许负象限                                    |
| `FNormalBlockData`              | `FNormalBlockData` 接口                    | 当前本地接口沿用 12 字节基础字段；server v1 wire 追加 attribute/tag refs 后固定 20 字节 |
| `FMacroCellHeader`              | `FMacroCellHeader` 接口                    | 线格式 7 字节：u8+u16+u16+u16                             |
| `EVoxelCellMode`                | `EVoxelCellMode` enum                      | Empty=0 / SolidBlock=1 / Refined=2                        |
| `EVoxelBlockStateFlags`         | `EVoxelBlockStateFlags` enum               | Burning/Frozen/Wet/… 位标志                               |
| `EVoxelRotation`                | `EVoxelRotation` enum                      | Rot0/90/180/270                                           |
| `FChunkStorageData`             | `FChunkStorageData` + `ChunkStorage` class | 结构 + 写入 API 解耦                                      |
| `VoxelDirtyFlags`               | `VoxelDirtyFlags`                          | Storage / Mesh / Collision                                |

UE `Public/Voxel/*` 是空间模型和真相层参考，不再作为本仓库服务端 wire contract 的唯一来源。
服务端权威协议以 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` 为准；
新增跨端字段时先更新 canonical doc + golden fixture，再同步 UE / web / Bevy / Elixir codec。

## 实施路线（与 UE 阶段对齐）

| Web 阶段                | 对齐 UE 阶段                  | 交付                                                                                                 |
| ----------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------- |
| **W-A 类型与脚手架** ✅ | UE-A 类型基线                 | `src/voxel/core`、`src/voxel/storage/types.ts`、`ChunkStorage` 写入 API、three.js 空场景             |
| **W-B Chunk Mesher** 🚧 | UE-B Mesher 首版              | 当前已完成 exposed-face chunk mesher + `BufferGeometry` 重建；greedy/worker 化后续再补               |
| **W-C 本地编辑** 🚧     | UE-C1 数据流                  | 当前已完成准星选中 + `trySetNormalBlock` / `clearCell` + 高亮预览；撤销/重做后续再补                 |
| **W-D 网络接入** ⏳     | UE 未覆盖（本客户端独有价值） | 当前只验 movement browser bridge；voxel 保持 offline-local，不接服务端                               |
| **W-E 视觉系统** 🚧     | UE-C2 视觉系统                | 当前已完成 `MaterialId + StateFlags -> display color` 首版解析；完整 registry / overlay 资产后续再补 |
| **W-F Prefab**          | UE-E Prefab                   | `PrefabCreate/Place` 协议；运行时 instancing 缓存；共享 / 私有可见性                                 |
| **W-G 性能**            | UE-F 性能                     | Mesher 迁至 Web Worker；InstancedMesh / GPU instancing；订阅半径自适应                               |

路线口径：

- W-A → W-D 以"**最快看到服务端交互**"为准，渲染优先用 per-face 简单三角面，不做 greedy
- W-D 上线后开始压测；若压测不过 canonical server-authoritative voxel 指标，优先修服务端，不在客户端堆优化
- 任何跨端 wire 新字段：canonical doc + golden fixture 先落 → Elixir / TypeScript codec 跟进 → UE / Bevy 适配跟进。

## 运行

首次安装：

```bash
cd clients/web_client
npm install
```

开发（热更新）：

```bash
npm run dev
# 打开 http://127.0.0.1:5173
```

默认情况下，浏览器客户端会采用：

- `voxel_sync=offline-local`
- `renderer=webgpu`，优先尝试 `WebGPURenderer` / WebGPU backend，不可用时回退 WebGL
- movement 优先尝试真实 **server-backed movement transport**

- `POST /ingame/auto_login`
- `GET /ingame/ws`

如果真实 backend 在 ready 前不可用，例如：

- `auth_server` 没启动
- `DEV_AUTO_LOGIN` 没开
- 页面跑在没有 `/ingame` 代理的静态预览地址上
- WebSocket bridge / enter-scene 失败

运行时会自动回退到 `simulated-local`，并在 HUD、`transport` CLI 快照以及 `voxel_observe` 日志里写出回退原因。  
注意这个回退只影响 **movement transport**，不会改变 `voxel_sync=offline-local`。

如果你只想跑纯本地 movement demo，可显式覆盖：

```bash
VITE_MOVEMENT_TRANSPORT=simulated npm run dev
```

如果需要强制渲染后端，可用 query 参数或环境变量：

```bash
npm run dev
# http://127.0.0.1:5173 默认就是 WebGPU 优先
# http://127.0.0.1:5173/?renderer=webgpu
# http://127.0.0.1:5173/?renderer=webgl

VITE_RENDER_BACKEND=webgl npm run dev
```

如果需要指向非默认地址：

```bash
VITE_AUTH_BASE_URL=http://127.0.0.1:4000 \
VITE_GAME_WS_URL=ws://127.0.0.1:4000/ingame/ws \
npm run dev
```

类型检查（CI / commit 前必跑）：

```bash
npm run typecheck
```

生产构建：

```bash
npm run build   # 同时跑 tsc --noEmit 和 vite build
npm run preview # 预览 dist
```

注意：

- `npm run dev` 默认通过 `vite.config.ts` 把 `/ingame` 代理到 `http://127.0.0.1:4000`。
- `npm run preview` 只提供静态 `dist/`，不会自动提供 `/ingame/auto_login` 或 `/ingame/ws`。
- 因此 preview 场景下，如果没有把 dist 挂到真实 `auth_server` 前面，运行时会自动回退到 `simulated-local`。

## W-A 冒烟验证

当前默认运行时会做四件事：

1. 生成一个多 Chunk 的浏览器内置离线世界
2. 用真正的 chunk mesher 生成 `BufferGeometry`
3. 默认优先启动真实 server-backed movement；若真实 backend 在 ready 前失败，则自动回退到本地 movement sync demo（本地预测 + ack 对账）
4. 安装 HUD + CLI + observe 调试面

看到以下即表示 W-A 通过：

- HUD 持续刷新 chunk / player / reconcile / edit 统计
- HUD / `snapshot` / `transport` 明确显示 `voxel_sync=offline-local`
- 世界中可见多个真正的 voxel chunk，而不是单个占位立方体
- `window.__voxelCli.run("snapshot")` 能返回结构化快照
- 左键 / 右键或 `F` / `G` 可以对准星命中面执行破坏 / 邻接放置；选中 prefab 时右键 / `F` 放置 prefab
- 底部 hotbar dock 可见且可点击；滚轮可切换 hotbar，`1..7` 可直接选材质或 builtin prefab
- `WASD` 能驱动 avatar；默认应看到真实 transport ready，或看到自动回退后的 `simulated-local` 状态与 fallback reason
- 本地 fallback 初始出生点会从内置地形表面求角色中心高度，不再使用空中硬编码高度

## 调试 / CLI

浏览器端同样遵守“CLI 可观测接口 + 结构化日志优先”的仓库约定。

### 浏览器 CLI

在 DevTools Console 里执行：

```js
window.__voxelCli?.run("help");
window.__voxelCli?.run("snapshot");
window.__voxelCli?.run("renderer");
window.__voxelCli?.run("chunks 8");
window.__voxelCli?.run("cell 0 1 0");
window.__voxelCli?.run("micro_cell 0 1 0 1 2 3");
window.__voxelCli?.run("select_material wood");
window.__voxelCli?.run("place 0 5 0 2");
window.__voxelCli?.run("break 0 5 0");
window.__voxelCli?.run("hotbar");
window.__voxelCli?.run("hotbar_select 5");
window.__voxelCli?.run("prefabs");
window.__voxelCli?.run("prefab_boundary builtin_sphere");
window.__voxelCli?.run("prefab_capture test 0 0 0 2 2 2");
window.__voxelCli?.run("prefab_place test 8 5 8 rot90");
window.__voxelCli?.run("prefab_place builtin_sphere 12 5 8");
window.__voxelCli?.run("prefab_place builtin_cylinder 14 5 8");
window.__voxelCli?.run("prefab_place builtin_stairs 16 5 8 rot90");
window.__voxelCli?.run("prefab_snap_preview builtin_sphere 12 5 8 1 0 0");
window.__voxelCli?.run("prefab_place_snap builtin_sphere 12 5 8 1 0 0");
window.__voxelCli?.run("select_prefab builtin_sphere");
const exported = window.__voxelCli?.run("world_export").data.json;
window.__voxelCli?.run(`world_import ${exported}`);
window.__voxelCli?.run("world_save default");
window.__voxelCli?.run("world_load default");
window.__voxelCli?.run("transport");
window.__voxelCli?.run("player");
window.__voxelCli?.run("players");
window.__voxelCli?.run("reconcile_stats");
window.__voxelCli?.run("edit_stats");
window.__voxelCli?.run("frame_trace_start 300");
window.__voxelCli?.run("frame_trace");
window.__voxelCli?.run("frame_trace_clear");
```

### Observe 日志

运行时会输出 `voxel_observe ...` 结构化日志到浏览器 console，并在 `window` 暴露最近事件：

```js
window.__voxelObserve?.recent(20);
window.__voxelObserve?.snapshot();
```

调试原则：

1. 先看 `snapshot / chunks / cell / reconcile_stats / edit_stats`
2. 再看 `renderer / transport` 与 `voxel_observe` 日志确认渲染后端、连接、输入、权威 ack、重建与错误路径
3. 对 prefab snap，优先看 `prefab_boundary / prefab_snap_preview / prefab_place_snap`
   返回的 `anchorMicroCoord / affectedMacroCount / incomingOccupiedSlots / overlapSlots`
   / `contactSlots`，以及 observe 事件
   `prefab_boundary_snap_previewed / prefab_boundary_snap_committed / prefab_boundary_snap_rejected`
4. 最后才看画面本身

当前建议先看两条正交状态：

1. `voxel_sync=offline-local`：当前固定成立，表示体素世界只在浏览器本地运行
2. `movement_transport=...`：当前真正需要验收的网络面

movement transport 再拆成三类判断：

1. `mode=server-ws` 且 `ready=true`：真实 backend 已接通
2. `mode=simulated-local` 且 `fallbackReason` 非空：真实 backend 失败，但本地 demo 已接管
3. `mode=server-ws` 且 `ready=false`：仍处于 bootstrap 中，继续看 `voxel_observe` 最近事件

## 控制

- 镜头：第三人称跟随镜头；左键按住拖拽可旋转视角；`Ctrl+滚轮` 缩放
- `W/A/S/D`：驱动本地玩家 avatar，**方向相对当前摄像机朝向**；server-ws 与 simulated-local 共用同一套 movement 输入面
- `Space`：跳跃；HUD / CLI trace 会记录 `jump_pressed`、`movement_flags`、`player_mode` 和 Y 轴变化，渲染层会把 airborne offset 加到地表显示高度上
- 左键 / `G`：破坏准星命中面的当前方块
- 右键 / `F`：在准星命中面放置当前 hotbar 项；如果当前 hotbar 是 prefab，则优先执行
  socket-free micro boundary snap，失败时再回退到宏格邻接放置
- 底部 dock：点击槽位直接选中当前 hotbar 项；滚轮：切换 hotbar；`1/2/3/4` 选择 `Dirt / Stone / Wood / Ice`，`5/6/7` 选择 `builtin_sphere / builtin_cylinder / builtin_stairs`

## Smoke / 验收脚本

推荐使用新的受监督 runner：

```bash
node scripts/run_ws_dual_smoke_supervised.js
```

该 runner 会使用完整 `MIX_ENV=dev` 运行时，自动执行 data_service 数据库
create/migrate，并预置 `ws_smoke_a` / `ws_smoke_b` 两个 smoke 账号，避免
依赖手动准备的临时数据。运行产物写入 `.demo/observe/`，其中
`ws-dual-smoke-summary.json` 会记录登录、enter-scene、发送输入帧、ack、
AOI priority、remote tick 增长和 remote jump 抬升断言。

兼容 PowerShell 入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_ws_dual_smoke.ps1
```

说明：

- 旧 PowerShell 入口现在只做转发，不再自己管理 boot/timeout/cleanup
- 新 runner 会自动挑空闲端口、等待服务 ready、运行 probe，并在结束后清理进程树

## 不在本仓库范围

- UE 客户端自身的渲染 / 物理 / 命中优化 — 由 `D:\UnrealEngine\test1` 仓库负责
- web client 内不实现服务端权威 voxel；服务端侧应按 `SceneServer.Voxel.*` 设计推进，见 `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md`
- 美术资产 / UI 打磨 — 本客户端只做协议验证
- 游戏逻辑（战斗 / 经济 / 任务）— 不在本阶段

## 相关文档

- `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` — 当前 canonical 服务端权威 voxel 数据结构 / 协议 / scene authority 设计
- `docs/2026-04-29-voxel-server-authority-convergence-research.md` — 当前代码现状下把
  voxel 从 offline-local 收拢为服务端权威的研究结论和分阶段切入点
- `docs/2026-04-20-体素世界服务端规划.md` — 历史规划，已被 2026-04-29 canonical 设计取代
- `docs/2026-04-28-web-client-movement-render-prefab-fixes.md` — movement 丝滑化、prefab 预览优化、simulated-local 假远端 actor 移除、地形出生点修复的后续接手笔记
- `docs/2026-04-24-web-client-prefab-microgrid-jump-implementation.md` — 浏览器端 prefab / microgrid / jump display 当前实现记录
- `docs/2026-04-24-web-client-prefab-microgrid-snapping-design.md` — prefab micro boundary snapping + micro occupancy union 设计
- `docs/2026-04-10-线协议规范.md` — gate_server 二进制协议基线
- `D:\UnrealEngine\test1\DOC\UE5_方块世界_项目架构文档.md` — UE 端分层
- `D:\UnrealEngine\test1\DOC\UE5_方块世界_数据结构设计草案.md` — UE 端数据结构
- `D:\UnrealEngine\test1\DOC\UE5_方块世界_实施路线图.md` — UE 端阶段定义
