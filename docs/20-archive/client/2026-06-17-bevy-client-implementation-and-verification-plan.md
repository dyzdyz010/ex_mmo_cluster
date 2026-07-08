# Bevy 客户端实现 + 验证决策稿(2026-06-17)

**目标(用户拍板 /goal)**:客户端功能与服务端**完全对齐**,且**经多方验证渲染完全正确**;合理分层;
积极参考各平台/知识库的准确渲染做法;**遵循既有设计原则**(正交系统 / 属性派生 / 只经 truth 耦合 /
append-only / 形态分类法 / 表面元件 terrain-bypass)。

**命门约束**:用户**无法自行运行客户端看画面**,正确性只能靠**自动化测试 + 调试**确认。故本稿把
**验证/调试策略放在与功能实现同等核心的位置**——"看起来对"不算数,一切正确性必须落到**可自动断言**的
产物上。

> 产物来源:4 路并行 agent —— bevy_client 现状/分层、服务端↔客户端功能差距、准确体素渲染调研、
> 「无人眼时自动化测试/调试」调研(均带来源)。主线客户端 = bevy(web_client 为 oracle/spec)。

## 1. 现状(已核验)

- **分层干净(6 层)**:Network → Stdio → Input → Logic(authority) → Sync → Render(`app/schedule.rs`
  ClientSet)。wire 解码层无 Bevy 依赖(纯数据 + 显式 cursor),authority 纯逻辑(版本门控),离线世界独立。
- **解码层完整**:0x62 ChunkSnapshot(7 段)/0x63 ChunkDelta/0x69 Invalidate/0x6C ObjectStateDelta/
  0x71 CatalogPatch/0x73·0x74 FieldRegion 均已解码 + golden round-trip 测试(对 `apps/scene_server/priv/
  fixtures/voxel/*.golden`)。
- **渲染**:M2 greedy meshing + exposed-face(CPU 几何单测齐全:面剔除/水密/greedy vs exposed 面积一致);
  per-vertex color + 单 StandardMaterial;宏格→渲染 1:1(macro Y = up,无 swap,已修过"地面变墙")。
- **三大渲染缺口(P0)**:① 表面元件 0x08 **完全未解码/渲染**(web 有);② ObjectStateDelta/prefab
  **被 Ignored,无表现**(web 有 debris/part);③ FieldRegion **解码但无可视化**(web 有热烟/电弧)。
  次级:micro/refined 仅取首层近似(M2b 未做)、state_flags 语义未渲染、EnvironmentUpdated 0x72 未解码。
- **验证盲区**:**bevy_client 不在 CI**(最高杠杆缺口);无 headless 真实渲染/截图测试;mesh 断言仅长度级。
- **parity 陷阱(重要)**:bevy mesher 与 web mesher **每面角点顺序不同** → 跨语言 parity 必须比**顺序无关
  量**(面集 / 每材质面积 / AABB / 顶点集合排序后),不能比原始顶点缓冲。

## 2. 目标分层架构(沿用现有 6 层,细化 Render 子层 + 新形态接入点)

```
Network(transport/解码)            ── 纯数据,无 Bevy;新 section/op 在此扩 decoder + golden parity
  ↓ enqueue
Logic / Authority(世界状态真值)     ── 纯逻辑 VoxelAuthorityStore;新增 surface_elements / object 状态在此落 store
  ↓ dirty set
Render(分并行子层,各读 authority truth,互不耦合):
  ├ ChunkMesh   宏格 + 微格 → greedy mesh(+AO)            [体积形态]
  ├ SurfaceDecal 表面元件 → 贴面 quad/decal(零体积)        [表面形态,新]
  ├ ObjectView  object/prefab → 实体 + 状态(part 损毁)     [新]
  └ FieldView   FieldRegion → 热/电可视化(粒子/overlay)    [新]
Camera / Input / Presentation(相机、输入、平滑)
```

原则:**每个渲染子层独立读 authority 的 committed truth**(镜像服务端"只经 truth 耦合");客户端**不发明
真值**,只把服务端 truth 映射成可见。形态分类法对齐:体积(V)走 ChunkMesh、表面(S)走 SurfaceDecal、
自由(F,debris/object)走 ObjectView。

## 3. 验证与调试策略(命门 —— 分层,按 稳定性/价值/成本 排序)

> 核心:用户看不到画面 → **CPU 几何断言 + 跨语言 parity 是主力**,图像 golden 仅作补充。

### Layer 1 — CPU 几何断言(主力;无 GPU、确定、快)
把"将要绘制的几何"直接断言,替代人眼。在 `mesher.rs`/`chunk_render.rs` 现有长度断言上扩**逐值/不变量**:
- 已知体素输入 → 断言**顶点集合 / 法线 / 面集 / 三角数 / AABB / 每材质面数**(用**排序/集合比较**,抗 mesher 重构)。
- **不变量(property test,加 `proptest` dev-dep)**:任意 chunk —— 顶点在 chunk AABB 内;法线 ∈ 6 轴单位向量且单位长;`indices % 6 == 0`;index < 顶点数;各属性等长;无零面积三角。
- **面剔除/水密**:全实心 chunk 的面集 == 恰好 6 个外平面(每 quad 落在 coord==0 或 ==size);被实心包围的内部格零面。这是人眼会"一眼看出错"的剔除正确性证明。
- **每材质面积核算**:按 material_id 分组面积 == 期望暴露面 → 抓材质渗色/错色。
- **AABB 断言**:抓 voxel_size 缩放 / chunk 平移回归(几何悄悄移出屏幕)。

### Layer 2 — 跨语言 mesher parity(高价值;复用现有 golden 机制)
把 golden round-trip 从"wire 解码 parity"扩到"**mesher 产物 parity**":证 bevy mesher 与 web oracle 对同一
chunk 产出**同样的可见表面**。机制(避开角点顺序陷阱):
- web mesher 对同一批 `snapshot_*.golden` 跑出**顺序无关的 canonical summary** JSON(`{total_area, per_material_area, aabb, exposed_face_set_hash}`),存 `priv/fixtures/voxel/*.mesh.json`(与 wire golden 同目录,共享真值源,合本仓"golden=spec"政策)。
- bevy 集成测:解 wire golden → mesh → 算同样 summary → 断言等于 JSON golden。
- 在 `mesh_chunk`(exposed-face oracle)比面集 parity;`greedy_mesh_chunk` 与之比总面积一致(已有),greedy parity 传递成立。

### Layer 3 — headless 图像 golden(补充;最后做、保持薄、nightly)
真实渲染管线、无窗口、像素带容差比对。验 CPU 断言看不到的(光照/顶点色着色/绕序真正到 framebuffer)。
- Bevy 0.18 真实路径:`WindowPlugin{primary_window: None}` + `.disable::<WinitPlugin>()` + `ScheduleRunnerPlugin`;截图 `Screenshot` + `save_to_disk`,或 render-to-`Image`(`RenderTarget::Image`,**须 `RenderAssetUsages::default()`**,issue #18908)+ `gpu_readback::Readback`。
- **确定性**:固定相机/单方向光/`Msaa::Off`/`default_nearest`/禁时间动画/预跑数帧再截。
- 比对用 SSIM 容差(`image-compare`/`twenty_twenty`/`dssim`),**绝不逐像素精确**(软硬件 adapter 有差)。
- **CI 无 GPU**:Linux lavapipe(软件 Vulkan)/`WGPU_FORCE_FALLBACK_ADAPTER=1`;**单独/nightly job**,不阻塞每 PR(软渲染慢且脆)。

### Layer 5(横切)— 调试可观测性(完善调试能力)
- 扩 `ClientObserver`(已有 `va_status`/`va_chunk` 结构化日志):加 **`mesh dump`** stdio/CLI 命令,输出 Layer-1 canonical summary(每材质面积/AABB/面数/水密 bool)→ 失败留可 diff 工件;`--headless --script` 可断言之。
- **decode 结构 JSON dump**(可与 web 对 diff)。
- Bevy 诊断:`LogDiagnosticsPlugin`/`FrameTimeDiagnosticsPlugin`/`EntityCountDiagnosticsPlugin`(headless 日志确认"渲染插件确实 spawn 了 N 个 chunk 实体")。失败时上传 mesh dump / PNG(沿用 smoke 工件上传)。

### CI 集成(最高杠杆,立即做)
`.github/workflows/ci.yml` **加 bevy_client `cargo test` job**——现有最强资产(Layer-1 几何 + Layer-2 parity)
当前根本没在 PR 上跑。这是最便宜、最高影响的修复。

## 4. 渲染要点(据调研,Bevy 0.18.1)

- **greedy + AO**:0fps 公式 `side1&&side2?0:3-(s1+s2+corner)`;合并条件须加**四角 AO 相等**;按对角 AO 和决定三角划分方向(防各向异性);AO 烘焙进现有 per-vertex color(近零成本)。
- **Bevy 0.18 API**:`Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::default())` + `with_inserted_attribute`(POSITION/NORMAL/UV_0/COLOR)+ `with_inserted_indices`。**坑**:用 `RENDER_WORLD`-only → chunk 无法重建,必须 `default()`(issue #18864)。绕序须 CCW(Bevy `cull_mode=Back`),错则面消失。
- **off-thread meshing**:`AsyncComputeTaskPool` 双系统(派发 `Task<T>` 存 Component / 收割 `poll_once` 回主线程插 `Assets<Mesh>`)。MMO 流式世界硬需求。
- **表面元件渲染(关键)**:火炬/装置走**自管 quad**(沿面法线偏移 ε ~1e-3m + 必要时 `StandardMaterial.depth_bias`;0.14 曾忽略 depth_bias,0.18 须实测,退路高 RenderLayer 第二相机);锈/霜/焦痕走 **ForwardDecal**(软边自然、免手动 bias,但须相机 `DepthPrepass` + 关 MSAA)。**`hide_when_neighbor_occupied` 在 mesh 生成期剔除**(被挡则不产 quad,零运行时成本)。**表面元件绝不进 greedy mesher**(非体素面)。
- **透明**:不透明/透明**拆成两个 mesh**(Bevy 透明按实体 z 排序,非 per-triangle,混在一个 mesh 会穿插);优先 `AlphaMode::Mask`(ice/玻璃),water 才 `Blend`;同类透明相邻面互剔。
- **texture array**(换自定义 `Material` + `2d_array`,StandardMaterial 暂不支持 array,issue #20134):避免 atlas 渗色;当 per-vertex color 不够时再上。
- **微格交界 = 天生 T-junction 源**(大宏格面 vs 一排小微格面):交界处宏格面按微格分辨率细分或填裙边,别让宏/微格各自独立 mesh 不处理接缝。
- **LOD**:方块美术用距离降采样 + 裙边补缝(非 Transvoxel,那是平滑地形);最后做,仅当大世界证明是瓶颈。

## 5. 功能对齐里程碑(每个里程碑都由 §3 验证策略闸门)

- **C0 验证地基(先做)**:① Layer-1 几何断言扩充(顶点/法线/面集/水密/每材质面积/AABB 助手 + proptest 不变量);② `mesh dump` 调试命令;③ **bevy_client 纳入 CI**。**理由**:用户看不到画面,后续每个功能都要靠这套断言验,地基必须先稳。
- **C1 表面元件 0x08(P0)**:服务端先补 `snapshot_surface_elements.golden`(M4 遗留项)→ bevy wire decoder(section 0x08)+ authority store + SurfaceDecal 渲染(自管 quad / ForwardDecal,hide_when_neighbor_occupied 生成期剔除)。Layer-1/2 验证。接服务端 M1-M5(火炬/锈渍可见)。
- **C2 ObjectStateDelta/prefab(P0)**:authority 由 Ignored → 维护 per-object 版本 + part 状态;ObjectView 子层按 owner_object_id 分组渲染 + part 损毁/debris。对 `object_state_delta_*.golden`。
- **C3 FieldRegion 可视化(P1)**:FieldView 子层(温度热力/电势)——参考 web heatSmoke/lightning;数据已解码。
- **C4 微格 M2b(P1)**:refined 8³ 子网格 + 宏/微格交界裙边/细分(T-junction)。
- **C5 state_flags 语义 + EnvironmentUpdated 0x72(P1/P2)**:burning/rusting/powered 等状态位着色;0x72 decoder。
- **横切**:AO、off-thread meshing、透明拆 mesh —— 在相关里程碑顺带接(C1/C4)。

## 6. 设计原则遵循

- 客户端**镜像服务端 truth,不发明真值**;每渲染子层只读 authority committed truth(对齐"只经 truth 耦合")。
- 形态分类法对齐:体积/表面/自由 三基底各有渲染子层;表面元件 terrain-bypass(零 occupancy、被覆盖即隐)在客户端体现为"生成期剔除 + 独立 decal,不进体素 mesh"。
- 协议 append-only:新 section/op 只追加 decoder,旧 golden 不破(已验:0x08 可选段空 chunk 字节全等)。
- **逐 step commit + cargo test 绿 + 决策稿留痕 + 不 push**(沿用本仓纪律)。

## 7. 范围与 defer

- **IN**:C0-C5 + 横切渲染要点。bevy 主线;web 作 oracle 真值。
- **DEFER(显式)**:texture array(per-vertex color 够用前)、LOD/binary greedy(性能证明瓶颈前)、Layer-3 图像 golden 上每-PR CI(先 nightly)、ionization/current 场通道渲染、CatalogPatch 运行时 merge。
- **风险**:Bevy `depth_bias` 历史回归(0.18 须实测);软件渲染 golden 跨 adapter 漂移(故 SSIM 容差 + nightly);microgrid T-junction(交界细分必做)。
