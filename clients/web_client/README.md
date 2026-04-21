# ex_mmo Voxel Web Client

一个浏览器端的体素世界原型客户端，与 `clients/bevy_client/` 并列，目的是：

1. **复刻** UE5 `test1` 项目的数据层与交互层（本地破坏 / 放置 / Prefab），让前端状态模型与 UE 端保持字节级一致
2. **提前验证**服务端 `voxel_server` 的订阅 / 编辑 / AOI / 冲突协议，不必等 UE net 层就绪
3. **压力联调**：向 `voxel_server` 压多客户端、多并发编辑，跑 `docs/2026-04-20-体素世界服务端规划.md` 第 12 节的验收指标

> 定位：服务端联调与协议验证工具。不做美术 / UI 投入，UE 端 net 层就绪后可退役或转为 e2e 回归客户端。

## 技术栈

| 模块 | 选型 | 理由 |
|------|------|------|
| 构建 | Vite 5 + TypeScript 5 | 热更新秒级，原生 ES module |
| 渲染 | three.js 0.170 | voxel 生态成熟，greedy mesher 参考实现多 |
| 网络 | WebSocket + DataView | 对齐服务端 `{packet, 4}` 长度前缀 + 小端二进制 |
| 语言 | TypeScript strict | 类型结构对齐 UE USTRUCT |

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
        │   ├── constants.ts        # VoxelConstants（与 UE 严格一致）
        │   ├── types.ts            # FChunkCoord / FMacroCoord / 枚举
        │   └── gridUtils.ts        # divideFloor / coord 换算
        ├── storage/
        │   ├── types.ts            # FNormalBlockData / FMacroCellHeader / FChunkStorageData
        │   └── chunkStorage.ts     # 运行时 Chunk 镜像 + 写入 API
        └── meshing/
            └── types.ts            # FChunkMesherInputSnapshot
```

## 与 UE test1 的映射约定

| UE 符号 | Web 符号 | 注意 |
|---------|----------|------|
| `VoxelConstants::MicroPerMacro` | `VoxelConstants.MicroPerMacro` | 固定 4，两端同步修改 |
| `FChunkCoord` | `FChunkCoord` 接口 | int32 语义，允许负象限 |
| `FNormalBlockData` | `FNormalBlockData` 接口 | 线格式 12 字节：u16+i32+u16+i16+i16 |
| `FMacroCellHeader` | `FMacroCellHeader` 接口 | 线格式 7 字节：u8+u16+u16+u16 |
| `EVoxelCellMode` | `EVoxelCellMode` enum | Empty=0 / SolidBlock=1 / Refined=2 |
| `EVoxelBlockStateFlags` | `EVoxelBlockStateFlags` enum | Burning/Frozen/Wet/… 位标志 |
| `EVoxelRotation` | `EVoxelRotation` enum | Rot0/90/180/270 |
| `FChunkStorageData` | `FChunkStorageData` + `ChunkStorage` class | 结构 + 写入 API 解耦 |
| `VoxelDirtyFlags` | `VoxelDirtyFlags` | Storage / Mesh / Collision |

所有字段顺序、枚举值必须与 UE `Public/Voxel/*` 头文件完全对齐。新增字段时先改 UE，再改此仓库。

## 实施路线（与 UE 阶段对齐）

| Web 阶段 | 对齐 UE 阶段 | 交付 |
|----------|------------|------|
| **W-A 类型与脚手架** ✅ | UE-A 类型基线 | `src/voxel/core`、`src/voxel/storage/types.ts`、`ChunkStorage` 写入 API、three.js 空场景 |
| **W-B Chunk Mesher** | UE-B Mesher 首版 | greedy mesh 算法；每 Chunk 一个 `BufferGeometry`；Mesh 脏区只重建差异 |
| **W-C 本地编辑** | UE-C1 数据流 | 鼠标拾取 → `trySetNormalBlock` / `clearCell`；高亮预览框；撤销/重做 |
| **W-D 网络接入** | UE 未覆盖（本客户端独有价值） | WebSocket 连 gate；`ChunkSubscribe/Delta/BlockBreak/Place`；`base_hash` 乐观编辑 + `EditAck` 回滚 |
| **W-E 视觉系统** | UE-C2 视觉系统 | `FVoxelBlockStateView` + overlay（燃烧 / 冻结 / 湿润）；基础材质注册表 |
| **W-F Prefab** | UE-E Prefab | `PrefabCreate/Place` 协议；运行时 instancing 缓存；共享 / 私有可见性 |
| **W-G 性能** | UE-F 性能 | Mesher 迁至 Web Worker；InstancedMesh / GPU instancing；订阅半径自适应 |

路线口径：

- W-A → W-D 以"**最快看到服务端交互**"为准，渲染优先用 per-face 简单三角面，不做 greedy
- W-D 上线后开始压测；若压测不过 `docs/2026-04-20-体素世界服务端规划.md` § 12 指标，优先修服务端，不在客户端堆优化
- 任何新字段：UE 端先落（`Voxel/*.h`）→ 本客户端类型跟进 → 服务端 codec 跟进。三端顺序不可颠倒

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

类型检查（CI / commit 前必跑）：

```bash
npm run typecheck
```

生产构建：

```bash
npm run build   # 同时跑 tsc --noEmit 和 vite build
npm run preview # 预览 dist
```

## W-A 冒烟验证

当前 `main.ts` 做两件事：

1. 初始化 `ChunkStorage.createEmpty({x:0,y:0,z:0})`，HUD 显示 `macroCount = 4096`
2. 渲染一个 MacroWorldSize 立方体 + GridHelper，验证 three.js 链路

看到以下即表示 W-A 通过：

- 背景 `#202833`，左上角 HUD 显示 `chunk 16^3 macros = 4096`
- 网格 + 蓝灰立方体可见
- 窗口缩放不变形

## 不在本仓库范围

- UE 客户端自身的渲染 / 物理 / 命中优化 — 由 `D:\UnrealEngine\test1` 仓库负责
- 服务端 `voxel_server` app 实现 — 见 `docs/2026-04-20-体素世界服务端规划.md`
- 美术资产 / UI 打磨 — 本客户端只做协议验证
- 游戏逻辑（战斗 / 经济 / 任务）— 不在本阶段

## 相关文档

- `docs/2026-04-20-体素世界服务端规划.md` — 服务端协议 / 数据 / 进程模型
- `docs/2026-04-10-线协议规范.md` — gate_server 二进制协议基线
- `D:\UnrealEngine\test1\DOC\UE5_方块世界_项目架构文档.md` — UE 端分层
- `D:\UnrealEngine\test1\DOC\UE5_方块世界_数据结构设计草案.md` — UE 端数据结构
- `D:\UnrealEngine\test1\DOC\UE5_方块世界_实施路线图.md` — UE 端阶段定义
