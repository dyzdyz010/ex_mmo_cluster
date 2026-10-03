# Prefab Designer D3：玩家编辑空间（首个增量 D3-1）

分类：全局系统功能（客户端编辑空间、VXPD v3、0x71 发布、拼装仓库自制件、`BP_PrefabWorkbench` 资产）；
工作台在 `L_GameplayDemo` 的摆放、回放脚本与独立旧 Demo 部署为只测试。依据 [D1](2026-09-22-prefab-designer-d1.md)。
2026-09-23 用户选定形态：**独立编辑空间**（不是框选捕获），玩家与 NPC 共用同一发布与校验内核。

## 边界

- **草稿在客户端**：D1 的草稿本身就是一份纯定义，服务端不保留编辑进程；编辑逐格发生在客户端，只有发布跨越信任边界。
  `Voxim/Source/Voxim/Voxel/Prefab/VoxelPrefabDraft.{h,cpp}`：草稿盒为工作台局部宏格 `[24,40)×[8,24)×[24,40)`（16 m，与 `Prefab.limits` 一致），
  放在一个独立驻留 Tile 内，拾取复用 `RaycastVoxels`；空处射线落在盒底 y=8 的地面上起建。首版只编辑实体宏格。
- **编辑空间**：`P` 进入。视图切到关卡里的工作台 Actor（草稿 ISM、编辑相机、16 m 网格地面），隐藏世界呈现；角色原地不动
  （`AVoximM1Character::MovementRedirect` 把 WASD 交给编辑相机，跳跃忽略）；流送视点本就取服务端确认的角色位置，不随相机移动。
- **发布**：`Enter` 编码草稿（有宏格即写 VXPD v3，无宏格仍写 v1/v2，作者资产 id 不变）→ 上行 **0x71**（整份字节）→ Dispatch 经
  `Player.tool_context` → `World.publish_prefab`，格式、上限、引用、对齐、重叠全由服务端裁决；结果 `0x68`，拒绝原因以中文显示。
  发布不扣料、不产生体素事务。定义身份 = 字节 sha256，客户端自算。线格式见 `Voxim/Docs/R7/wire.md` 末节。
- **放置**：发布成功的定义进入本会话拼装仓库（作者资产之后的下标），`9` 选中；预览与放置复用既有 `0x7A`，含宏格定义的锚点按 8 对齐，
  预览同时检查宏格占用。放置仍走 World 付费裁决与宏格归属。
- **协议 17**：新增 0x71，Hello 16→17，双方精确匹配；0x71 在旧 TCP/WS 编解码的 0x82 冲突之外另取。

未做（D3-2 及以后）：自制件的服务端名称／发布者元数据与跨会话列表、按 id 下载定义（HTTP 内容寻址）、草稿 micro 格与子 prefab 引用、
检查面板（`PrefabDesigner.check`）、命名输入框（中文输入法）、撤销、旋转草稿、Qinglan 集成。
（发布者与跨会话列表已由下节 D3-2 W-A 完成，撤销与材料清单由 W-B 完成；草稿 micro 格、薄面／细线、整体旋转已由 D3-3 增量 1 完成，子 prefab 插入由增量 2 完成，
命名（协议 18）由增量 3 完成，见下文“D3-3 增量 3”节；不暴露 `PrefabDesigner.check`，理由同节。Qinglan 集成为后续增量。）

## D3-2 增量 W-A：共享的已发布列表（协议仍为 17）

分类：全局系统功能（发布记录持久化、`World.published_prefabs/1`、`Codec.encode_prefab_list/1`、`POST /ingame/voxel/prefabs`、
`POST /playtest/prefabs`、客户端列表解码与拉取）；smoke 与独立旧 Demo 部署为只测试。

- **持久化**：`World.publish_prefab` 在写 `prefabs/<hex>.vxpd`（已有则跳过）之后，若该 id 尚未列出，再原子写 `prefabs/<hex>.pub = <<序号::32, cid::64>>`；
  序号 = 已列出数 + 1，cid 取刷新后的 `tool_context`。先 .vxpd 后 .pub：两步之间崩溃只让定义暂不列出（仍可放置），重发即补记；
  重发保留首个发布者与序号。World 启动时 `Prefab.load_published/1` 按序号载入 `published`。**D3-2 之前的发布没有 .pub，不迁移、不列出**，直到再次发布。
- **HTTP**：`POST /ingame/voxel/prefabs`（与 regions 同样受 `dev_auto_login` 控制）与 `POST /playtest/prefabs`（邀请码，已加入 `PlaytestAccess` 允许列表），
  经 `WorldServer.Movement.route` 找到 World。请求体为空；应答小端 `count:u32, count × {publisher_cid:u64, len:u32, vxpd}`，发布序，只含运行时发布。
  线格式见 `Voxim/Docs/R7/wire.md` D3-2 段。定义只存字节与发布者；数量、包围盒、成本由客户端从字节和目录推导。
- **客户端**：地址 = `FPaths::GetPath(RegionServerUrl) / "prefabs"`，复用 `MakeHttpRegionTransport`（同一邀请码头）。每个新会话 epoch、自己的发布被接受后、
  每次按 `9` 各拉一次；只应用最新一次请求的应答（旧的较短列表不会让 `SelectedPrefab` 越界）。应答整体替换拼装仓库的自制部分；
  名称派生为“作品 N · 我”／“作品 N · 玩家 <cid>”（N = 服务端序号）；`9` 从最新发布起向旧轮换并回绕。发布接受后不再本地追加。

**W-A 已实现、已实跑；D3 整体未验收**（W-B 撤销／材料清单见下节）。

- 服务端：`apps/voxel_region` 新增 World 测试（A、B 由 cid1 发布、cid2 重发 A，冷重启后列表 `[{1,A},{1,B}]`；作者目录子件不列出；
  删掉 B 的 .pub 后重启不列出但仍可放置，cid2 重发补记为 `{2002,B}` 并跨重启保留），prefab 相关 6 个文件 59 passed；全量 356/357，
  唯一失败 `prefab_macro_world_test.exs:177` 为测试库迁移时连接池超时，单独重跑该文件 14 passed。`apps/mmo_contracts` 116 passed（冻结 `encode_prefab_list` 字节）。
  `apps/auth_server` 新增 `voxel_prefabs_controller_test.exs`（真实 World 启动载入 .pub/.vxpd，HTTP 返回冻结字节、`dev_auto_login` 关闭为 403、
  playtest 无邀请码 401／有邀请码 200）与 `playtest_access_test` 的 `/playtest/prefabs`，连同 regions 测试共 10 passed。
- 客户端：`Voxim.R7.Prefab.PublishedList` 解码同一冻结样本（发布者、离线 sha256 id、宏格），截断／多余字节／count 超出均拒绝；
  受影响范围 `Voxim.Prefab.Draft.+Voxim.R7.Prefab.+Voxim.R7.B4.+Voxim.R7.Hierarchy.+Voxim.Raycast.+Voxim.Foliage.` 38/38 通过。
- 实跑（独立旧 Demo，镜像 `voxim-gameplay:prefab-list-20260923`，正常 Linux Mix 构建，源码清单
  `Voxim/Saved/Gameplay/prefab-list-20260923/image/source-manifest.json`；切换前备份数据库与部署目录，切换前后余额、探测格、目录一致；
  回滚容器 `voxim-prefab-designer-test-before-prefab-list`）：`smoke.py --mode prefab_editor` 三阶段——A 进编辑空间放 3 格并发布
  （`33ffc16a…9cec`，与 D3-1 同形同 id：它此前无 .pub，本次被补记为序号 1、发布者 A）→ 同容器冷重启 → 新开 A、B：A 按 9 显示“作品 1 · 我”，
  B 按 9 两次都选中“作品 1 · 玩家 359443468289”，在 before.json 证明为空的 z=58 行放置，txn 634904 接受；服务端快照 (43,519,58)(44,519,58)(43,520,58)
  为木材、placed_by 为 B，B 木材 −6,291,456 单位、A 不变；判定器另经真实 HTTP 入口读到同一 id 与发布者。截图已实际检查（发布提示、A／B 的名称、放置后）。
  证据 `Voxim/Saved/Gameplay/prefab-list-20260923/smoke-01/`。回归：同镜像 `smoke.py --mode assembly` 通过（`regress-assembly/`）。

## D3-2 增量 W-B：撤销与材料清单（只改客户端，协议仍为 17）

分类：全局系统功能（`FVoxelPrefabDraft::Undo`、`PrefabMaterialBill`、`UVoxelInteractionComponent::PrefabBillText／UndoPrefabDraft`）；
Demo HUD 显示、smoke 与独立旧 Demo 部署为只测试。

- **撤销**：草稿每次 `Set` 记下该格原材料，`Undo` 逆序恢复一步且不再记录。编辑空间里 `Z`（既有 `SelectPrefabLeaf` 绑定）转为撤销，提示“[Z] 撤销”。
- **材料清单**：`PrefabMaterialBill(micro 占地, 宏格占地, UnitsPerMicro)` 与 `World.prefab_payment` 空地放置同口径——宏格 `512 × UnitsPerMicro`、
  micro 格 `UnitsPerMicro`，附件不计。编辑中取草稿格，世界里取所选拼装件的预览占地；在草稿编辑／撤销／进出编辑空间／预览重建／余额回执／断线时重算。
  每种材料一行“木材 需 3.000 m³ / 持有 61.367 m³”，不够时加“不足”，余额未确认为“待确认”；材料名复用目录 `DisplayName` 经 `DisplayLabels` 的同一函数 `MaterialName`。
  Demo HUD 把它接在“模式／反馈”面板的 Selection 文字后（`VoxelStatsHud.cpp`），未改 WBP，实跑截图未截断。

**W-B 已实现、已实跑；D3 整体未验收。**

- 客户端单元：`Voxim.Prefab.Draft.Undo`（放石、放木、删石三步，逐步撤回到空草稿，第四次返回 false）与 `Voxim.Prefab.Bill`
  （UnitsPerMicro 4096：木 2 宏格 + 3 micro = 4,206,592；石 1 宏格 = 2,097,152，手算），受影响范围同上共 40/40。
- 实跑（独立旧 Demo 升级为镜像 `voxim-gameplay:prefab-bill-20260923`，服务端 master `198c21fe`（含燃烧重调合并），源码清单
  `Voxim/Saved/Gameplay/prefab-bill-20260923/image/source-manifest.json`；切换前备份数据库与部署目录，回滚容器
  `voxim-prefab-designer-test-before-prefab-bill`；目录经既有 playkit.exs → `World.publish_parameters` 从 `e4dc89a4…` 升级为 `fbd4f301…`，
  `fuel_rebase_j≈1.9e-9`，余额与探测格不变）：`smoke.py --mode prefab_editor --row 63`——A 放 4 格后按 Z，草稿面 1→2→3→4→3 格，
  清单依次 4.000／3.000／3.000 m³（`D3 bill material=19 units=8388608／6291456`，持有 = before 快照的 A 木材 128,696,975 单位 = 61.367 m³）；
  发布同形 `33ffc16a…9cec` → 冷重启 → A、B 按 9 选中后世界清单各为“需 3.000 / 持有 61.367”“需 3.000 / 持有 61.000”，B 在 z=63 行放置 txn 637406，
  三格木材 placed_by B，B 木材 −6,291,456、A 不变。判定器按手算单位与 before 快照独立核对清单与 HUD 文字。截图已实际检查
  （4 格／撤销后 3 格的编辑空间与清单、发布提示、A／B 世界清单、放置后清单变为持有 58.000 且新目录的木材“导热率 150、燃烧热 12 MJ/m³”）。
  证据 `Voxim/Saved/Gameplay/prefab-bill-20260923/smoke-01/`；回归 `smoke.py --mode assembly`（世界里 `Z` 选叶级路径）通过（`regress-assembly/`）。

## D3-3 增量 1：小块、薄面／细线、整体旋转、完整清单、合并目录（只改客户端，协议仍为 17）

分类：全局系统功能（`FVoxelPrefabDraft`、`RotatePrefabDefinition`、`AimAttachment`、`PrefabMaterialBill`、交互组件的合并目录与草稿工具）；
Demo HUD 操作指南一行、smoke 与判定器为只测试。服务端未改：VXPD v3 本就承载 micro + 宏格 + 附件，发布与放置裁决不变。

- **草稿唯一真值**：草稿只保存一份 `FVoxelPrefabDefinition`（定义局部 = 工作台局部 − BoxMin），撤销 = 每步一份定义快照（上限约 115 KB／步，不设上限）；
  拾取用的驻留 Tile、渲染和清单用的占地每步由 `BuildPrefab{,Macro,Attachment}Footprint` 从定义重建（micro 进 Tile 的 refined 数据）。
- **编辑工具**：编辑空间里 `Q` 循环 整块／小块（1/8 m）／薄面／细线，与世界的附件模式互不影响（`CycleAttachmentMode` 在编辑中转给草稿）。
  小块放在命中 micro + 法线；整块只进空且不含小块的宏格；薄面／细线用与世界同一个纯函数 `AimAttachment`（从 `UpdateAttachmentTarget` 移入 `Voxel/`）：
  命中宏格面为 8×8 组、命中小块面为单槽，槽位重叠即拒绝，组 id 从现有最大值递增。左键删命中物：整块／小块工具删命中的格，薄面／细线工具删命中槽所在的组；
  删格后失去支撑的附件组随之移除（与世界同一支撑规则，否则发布会被 `:unsupported_attachment` 拒绝）。材料只接受挡移动的实体材料。
- **整体旋转**：编辑中 `R`（`RotatePrefab` 转来）= 整个草稿绕盒心 micro (64,64,64) 竖直四分之一转（朝向 1），可撤销。唯一旋转函数
  `RotatePrefabDefinition(定义, 朝向, 支点)` 复用放置的 `TransformCell`／`TransformPoint`／附件端点变换（附件变换抽成与服务端 `attachment_slot` 同式的一处）：
  在 A、朝向 0 放下结果 == 在 A + 支点 − R·支点、朝向 o 放下原定义。子件锚点／朝向同样变换（子件插入属下一增量）。
- **完整清单**：`PrefabMaterialBill(micro, 宏格, 附件槽, 附件规格)`：宏格 512 × UnitsPerMicro、micro UnitsPerMicro、每个附件槽 `SlotUnits`
  （面 = units × 面厚 × 8，棱 = units × 截面 × 64，与服务端 `damage.ex` face_units／edge_units 及 `World.prefab_payment` 逐槽扣料同式；
  无附件规格的旧目录每槽 1 单位，与 `Attachments.units/2` 的回退一致，这条规则也收进 `SlotUnits`，世界放置文字不再各写一遍）。
- **合并目录（修崩溃）**：交互组件维护一份目录 = 各作者资产的发布内容及依赖 + 服务端发布列表，世界选件与草稿都从它展开子件。此前自制件用空目录，
  引用子件的已发布定义在选中时 `FindChecked` 断言崩溃。
- **不做 `PrefabDesigner.check` 面板**（设计定案 (e)）：它要 NPC 房屋的入口／室内点；玩家侧有清单、中文拒绝原因与放置预览已够。

**D3-3 增量 1 已实现、已实跑；D3 整体未验收。**

- 客户端单元（全部手算期望）：`Voxim.Prefab.Draft.MicroAndAttachments`（命中 micro (258,71,258)+y → 局部 (66,8,66)；整块进含小块宏格被拒且草稿不变；
  小块叠小块、整块工具删小块；+x 面组 (72,0,64)、细线 (64,8,64)、重叠拒绝；删石连带无支撑的棱）、`Voxim.Prefab.Rotate`（2 宏格 + micro + 顶面组 + 子件的手算转后定义；
  转后朝向 0 与原定义朝向 1 平移 (128,0,0) 的三种占地逐项相等；四次回到原样）、`Voxim.Prefab.Draft.Undo`（五步快照逐字节撤回、Tile 重建）、
  `Voxim.Prefab.Bill`（木 4,206,592、石 2,097,152、铜面 64 槽 + 棱 8 槽 = 4,160；旧目录每槽 1 → 72）、`Voxim.Prefab.Palette.PublishedChild`
  （服务端列表父件引用列表内子件：改前 `Assertion failed: Pair != nullptr` 崩溃，日志留在 scratchpad `inc1/Automation_…_d3inc1_red_b0.log`；改后两种朝向手算宏格相等）。
  受影响范围 `Voxim.Prefab.+Voxim.R7.Prefab.+Voxim.R7.B4.+Voxim.R7.Hierarchy.+Voxim.Raycast.+Voxim.Foliage.+Voxim.R7.Properties.+Voxim.Gameplay.+Voxim.Demo.` 51/51。
- 实跑（独立旧 Demo `voxim-prefab-designer-test`，镜像不变 `prefab-bill-20260923`）：`smoke.py --mode prefab_editor --row 70` 三阶段——A 进编辑空间放木 2 格，
  `Q` 小块在第一格顶放 1/8 m 木块，`Q` 薄面、滚轮换铜在第二格顶铺铜面，`R` 整体旋转，`Q Q` 回整块放一格铜后 `Z` 撤销，`Enter` 发布 → 同容器冷重启 →
  A、B 各按 `9` 选中最新作品，B 在 z=70 行放置，txn 660214 接受。判定器逐项核对：草稿面 (格,附件槽) 依次 (0,0)(1,0)(2,0)(3,0)(3,64)(3,64)(4,64)(3,64)；
  旋转前后定义与手算一致；真实 HTTP 列表里的 VXPD 字节独立解码为宏格 (7,0,8)(7,0,9)、micro (61,8,66)、面组 轴 1 锚 (56,8,72) 边 8；B 的放置锚点 micro (288,4152,496)；
  服务端快照木宏格 (43,519,70)(43,519,71) placed_by B、(43,520,70) 槽 133 木 micro（owner 660214:0）、64 个铜面槽（轴 1，y=4160，x∈[344,352)，z∈[568,576)，同一 id）；
  B 木 −4,198,400、铜 −4,096（64 槽 × 64），A 不变；编辑中与 A／B 世界清单“木材 需 2.002 m³ / 铜 需 0.002 m³”及各自持有按 before 快照独立核对。
  证据 `Voxim/Saved/Gameplay/prefab-d3inc1-20260923/smoke-02/`（退出 0）。原始失败 `smoke-01/`：所有放置与服务端核对已对，只因 A 按 9 与 Status
  同帧执行、A 的世界清单缺行而判败（脚本给 Status 留 2 s 后复跑）；smoke-01 已发布同一字节（同 id、序号 2），smoke-02 为重发，保留首个发布者与序号。
  截图已实际检查（编辑空间两格＋铜面＋小块、旋转后、多放一格、撤销后、A／B 世界清单、B 预览与放置）。
- 回归：编辑器输入语义变了（编辑中 Q／R），`deploy.py --reset` 后重跑 `smoke.py --mode circuit_fire`：首次 `fire-d3inc1-01` 如下未判定，结论见增量 2 节（`fire-06` 通过）。
  设计段已实跑：草稿面 0→10→9（含左键删辅助块）与原 `DRAFT_SURFACES` 一致，发布 txn 接受，放置锚点 micro (464,3320,-4176) 与 fire-03 相同；
  随后观察期内本机内存不足，后台任务被系统终止，客户端已关闭，**判定器未运行，不计通过**；该部署世界已被部分消耗，下次实跑前须再 `--reset`。

## D3-3 增量 2：插入子件（只改客户端与 `BP_PrefabWorkbench` 资产，协议仍为 17）

分类：全局系统功能（`FVoxelPrefabDraft::InsertChild／ChildAnchor／ChildFits`、`BuildPrefabPlacement`／`PrefabPlacementAnchor`／`PrefabPlacementFits`、
交互组件的子件选择与虚影、`BP_PrefabWorkbench` 的 `ChildPreview` 组件）；Demo HUD 操作指南一行、smoke 与判定器为只测试。服务端未改：VXPD 本就承载子件引用，
发布时的引用存在、对齐、重叠、16 m 包围盒与放置时的先序展开都已由服务端裁决。

- **选择**：编辑空间里 `2–8`（经 `SelectPrefab`）选作者拼装件、`9`（经 `CycleCustomPrefab`，从最新发布起轮换）选合并目录里的已发布件；`1` 回到草稿工具，
  离开编辑空间即取消。选中子件时 `R` 在 24 个朝向间循环（与世界放置同一 `PrefabOrientation`），不选时仍是整体旋转草稿。
- **一处占地、一处锚点、一处判据**：`BuildPrefabPlacement(定义, 目录, 锚, 朝向)` 给出含全部子件的 micro／宏格／附件占地与体积包围盒；
  世界放置预览、草稿派生占地与子件插入都用它。锚点 `PrefabPlacementAnchor` 与重叠判据 `PrefabPlacementFits`（micro 驻留且空、宏格驻留且空且无小块、附件槽未占）
  从世界放置预览抽出，草稿用同一函数，外加“全部格在 16 m 盒内”。子件锚点一律取整宏格（不会触发 `:misaligned`）；空地面视为命中地面下方 micro、法线 +y。
  这是服务端规则的即时反馈，不替代发布裁决。
- **虚影**：`BP_PrefabWorkbench` 新增 ISM 组件 `ChildPreview`（`author_workbench.add_child_preview` 经 MCP 添加，网格与设置同世界放置预览），
  C++ 按组件名取用（`DraftSurface`／`ChildPreview`），材质在 `PrefabValidMaterial`／`PrefabBlockedMaterial` 间切换。
- **删除与撤销**：左键命中的格属于某个顶层子件（含其更深层）时删整个子件；插入、删除都是一步定义快照，`Z` 撤销。槽位从现有最大值递增（首个为 1）。
  材料清单用草稿派生占地，天然含子件的格与附件。

**D3-3 增量 2 已实现、已实跑（判定器复判通过）；D3 整体未验收。**

- 客户端单元：新增 `Voxim.Prefab.Draft.Children`（手算：朝向 1 的已发布件包围盒 [(-8,0,0),(0,9,16))、空地锚 (280,64,256)、节点树
  `C1 (88,0,64)@1  C2 (72,0,72)@0`、世界占地宏格／micro／64 面槽逐项、清单 石 2,097,152／木 4,202,496／铜 8,192、与作者件自身重叠拒绝、出 16 m 盒拒绝、
  宏格子件进含小块的宏格拒绝且草稿逐字节不变、左键删整个子件、撤销逐字节恢复）；既有草稿／旋转／清单／合并目录测试改用新接口。
  受影响范围同增量 1 共 52/52。
- 实跑（独立旧 Demo，镜像不变）：`smoke.py --mode prefab_editor --row 59`，证据 `Voxim/Saved/Gameplay/prefab-d3inc2-20260923/smoke-01/`。
  A 在增量 1 的步骤后按 `3` 插作者件“黏土隔热桥”（朝向 0，工作台锚 (256,64,264)），按 `9` 选中列表最新的增量 1 作品 `d7ecb621…`、`R` 转到朝向 1 插入（锚 (336,64,200)），
  发布 `07a8e570…`（166 格、128 面槽）→ 冷重启 → A、B 按 9 选中“作品 3”，B 放置 txn 664302。判定器逐项：草稿面 …(3,64)(163,64)(166,128)；
  真实 HTTP 列表里的字节独立解码出子件 `(1, ee567818…, (64,0,72), 0)`、`(2, d7ecb621…, (144,0,8), 1)`；服务端实例与 A、B 两端驻留实例同为先序
  `664302:0` 根、`:1` 黏土桥（父 :0、槽 1、锚 (352,4152,480)）、`:2` 已发布件（父 :0、槽 2、锚 (432,4152,416)、朝向 1）；宏格 (43,519,59)(43,519,60)(44,519,59)(45,519,59)
  placed_by B，162 个 micro 槽逐槽（黏土桥 160 + 两个小块）归属对应 occurrence，两组各 64 面槽；B 黏土 −131,072、木 −8,921,088、铜 −8,192（手算清单），A 不变。
  **原始判定失败保留**（`acceptance.json` 未生成，`smoke-01.out`）：附件观察盒从 x=336 起，含相邻格 (42,519,60) 早先的石棱，“放置前为空”前提不成立；
  盒收窄到本次两张铜面所在的 x∈[344,368) 后对同一证据复判全部通过（`acceptance-recheck.json`）。台面 x∈[43,45] 已无空的双行，未另跑一次。
  截图已实际检查（编辑空间里绿色虚影、插入两子件后的草稿与清单、B 预览与放置后、A 看到放置结果；HUD 指南新增一行未截断，另见 `hud-01/`）。
- 回归：增量 1 改了编辑器路径，`deploy.py --reset` 后重跑 `smoke.py --mode circuit_fire`：`fire-04` 失败于 harness 应答文件竞态
  （客户端每帧读旧的 `place.json.reply`，Windows 拒绝替换打开中的文件，PermissionError），客户端改为取走应答后删除；`fire-05` 失败于权威采样线程与 `@place` 应答同时
  以同名 `harness_<pid>` 起 Erlang 节点（“name … in use”），节点名加线程 id；两者都是只测试 harness 的并发缺陷，不是编辑器语义变化。`fire-06` 十五项全过、退出 0：
  三设备 119.565984 A、加热器 42,888.07 W、源 57,391.67 W，源耗电 57,391.7 W，合闸后 83.1 s HOST 起燃、186.2 s 云杉底起燃被烧掉，7.32 MJ 已供、5.18 MJ 随设备弃置，
  双端 1246 条燃烧确认一致（证据 `Voxim/Saved/Gameplay/emergent-loop-20260923/fire-06/`，截图已看）。

## D3-3 增量 3：命名（协议 18）

分类：全局系统功能（0x71 名称字段、`Prefab.check_name/1`、`.pub` 名称、列表名称字段、Hello18；客户端 `UVoxelPrefabNameDialog` 与资产 `WBP_PrefabNameDialog`、交互组件的 `PrefabNameDialogClass`／`NamePrefabDraft`／`PublishPrefabDraft(Name)`、列表名称解码与显示）；`L_GameplayDemo` 接线、回放命令 `@type`／`@slate`、smoke 与判定器、两个独立旧 Demo 部署为只测试。

- **0x71**：定义字节之后追加 `name_len:u16, name:UTF-8`（大端，同帧其余整数）。Hello17 帧（无名称字段）解码即拒绝。
- **信任边界**：`World.publish_prefab/4` 在刷新 `tool_context` 之后、编译之前调用 `Prefab.check_name/1`：非法 UTF-8、含 Unicode Cc 控制字符
  （U+0000–001F、U+007F–009F）或超过 48 字节 → `{:error, :invalid_name}`，经既有 `ResultFrame.error` 以 `0x68` rejected、reason `":invalid_name"` 下行，
  不编译、不写文件。空名合法（客户端显示“作品 N”）。拒绝原因中文标签由客户端 `author_chinese.py` 维护。
- **持久化**：`.pub = <<序号::32, cid::64, 名称::binary>>`（名称占文件剩余字节）；启动载入用同一匹配，Hello18 前写下的 12 字节记录即空名，不迁移。
  重发同一定义保留首个发布者、首次名称与序号；崩溃补记（有 .vxpd 无 .pub）时由补记者的名称写入。
- **列表**：每项 `publisher_cid:u64, name_len:u16, name, len:u32, vxpd`，全部小端。
- **NPC**：`PrefabDesigner.publish` 走 `World.publish_prefab/3`（名称默认空）。
- **不暴露 `PrefabDesigner.check`**：它需要 NPC 设计用的 `entry`／`inside` 脚点才能给出路线、净空等报告（`prefab_designer.ex` 顶部），
  玩家编辑空间没有这些输入；材料清单、中文拒绝原因和放置预览已覆盖玩家需要的反馈。决定不做玩家检查面板。

- **客户端**：Hello 18；0x71 以 `FBigWriter::Text` 追加名称；列表解码读 `name_len:u16` + UTF-8；拼装仓库名称 = 服务端名称（空名为“作品 N”）+ “ · 我”／“ · 玩家 <cid>”。
  编辑中 `Enter`（控制器键表 `author_controls.py` 改绑 `NamePrefabDraft`）创建关卡指定的 `WBP_PrefabNameDialog`（MONOLITH 面板 + 按钮 + 输入框，
  `author_name_dialog.py` 经 MCP 创作；按钮 `OnClicked → Submit` 在资产图里），切 UI-only 输入并把键盘焦点给输入框；输入框 `Enter` 或按钮提交即发布（空名合法），
  `Esc` 取消并切回 GameOnly。Esc 在对话框的 `NativeOnPreviewKeyDown` 截下：`SEditableTextBox` 外壳会自己吃掉 Esc 并把焦点移出内层文字框（见 naming-01）。
  客户端不校验名称，拒绝原因经 `DisplayLabels`（`invalid_name` = “名称无效（最多 48 字节，不含控制字符）”）显示。
- **回放（只测试）**：`@type <文字>` 逐字符走 `FSlateApplication::OnKeyChar`，`@slate <键>` 走 `OnKeyDown`／`OnKeyUp`（按焦点路由，与真实键盘同一 Slate 入口）；
  `@press` 仍直接进 PlayerController，到不了 UMG。它们不经过系统输入法组合。

**D3-3 增量 3 已实现、已实跑（命名双客户端 smoke 与 circuit_fire 回归通过）；系统中文输入法未验证；D3 整体未验收。**

- 服务端在 `prefab-naming` 分支完成后变基到 master（只有本记录冲突，两侧内容合并），快进 master 为 `b4d6e432` 后在主工作区重跑：

- `apps/mmo_contracts` 116 passed：0x71 冻结帧（名称“石屋”= `E7 9F B3 E5 B1 8B`，空名、Hello17 帧／截断／多余字节拒绝）与列表冻结字节（一项“石屋”、一项空名）；
  Hello 版本钉住改为 18（combustion／liquid／liquid_falls）。
- `apps/voxel_region` prefab* 6 个文件 60 passed：名称跨重启、重发保留首名、崩溃补记者名称、12 字节旧 .pub 载入为空名、`.pub` 冻结字节；
  非法 UTF-8（截断、过长编码 `C0 80`、`FF`）、LF、TAB、DEL、U+0085、49 字节拒绝且不入目录、不写文件，恰好 48 字节接受。
- `apps/gate_server` 新增 `voxim_prefab_publish_dispatch_test.exs`：冻结 0x71 帧经正式解码 + `Dispatch.handle` 进真实 World，
  含 LF 名称得到冻结的 `0x68 … ":invalid_name"` 字节、合法名称得到 `"ok"` 并列出；主工作区重跑 gate_server 除 `quic_connection_test`（Windows 不能运行）
  外全部测试文件 340 passed（10 excluded）。`apps/auth_server` HTTP 列表冻结字节（一新一旧 .pub）与邀请码 6 passed；`apps/scene_server` `prefab_designer_test` 11 passed。
  分支与工作区已删除。
- 客户端单元：`Voxim.R7.Prefab.PublishWire`（与服务端同一冻结帧：“石屋”与空名）、`Voxim.R7.Prefab.PublishedList`（冻结列表：名称“石屋”与空名；
  名称长度越界、协议 17 的同一列表拒绝）、`Voxim.M1.Codec.Boundary`（Hello18，Hello17 拒绝）；受影响范围
  `Voxim.Prefab.+Voxim.R7.Prefab.+Voxim.R7.B4.+Voxim.R7.Hierarchy.+Voxim.Raycast.+Voxim.Foliage.+Voxim.R7.Properties.+Voxim.Gameplay.+Voxim.Demo.+Voxim.M1.Codec.+Voxim.R7.B3.ReplayDeadline` 61/61。
- 镜像与切换（只测试）：服务端 master `b4d6e432` 正常 Linux Mix 构建为 `voxim-gameplay:prefab-naming-20260923`（`DEMO_BUILD_PROTOCOL=18`，源码清单
  `Voxim/Saved/Gameplay/prefab-naming-20260923/image/source-manifest.json`）。`upgrade.py designer|emergent` 先 pg_dump 数据库、复制部署目录，
  旧容器改名 `…-before-prefab-naming` 作回滚，`entry.exs` 协议守卫 17→18；`voxim-prefab-designer-test` 切换前后余额、探测格、目录一致，
  真实 HTTP 列表读回旧 12 字节 .pub 的三项为空名；`voxim-emergent-loop-20260923` 切换后 `deploy.py --reset`（断言协议 18）。
- 实跑 `smoke.py --mode prefab_naming`（证据 `Voxim/Saved/Gameplay/prefab-naming-20260923/naming-02/`，退出 0）：A 在编辑空间放木 3 格
  （局部宏格 (8,0,9)(8,0,8)(9,0,8)），经对话框键入 20 个汉字（60 字节）→ 服务端 `:invalid_name` 拒绝，反馈“发布被拒绝：名称无效（最多 48 字节，不含控制字符）”，
  列表不变；键入“石屋”后 Esc → 对话框关闭、未发送；键入“石屋”、Enter → 发布 `5a762488…e746`；经 Slate 按 P 回世界（证明键盘已交还游戏）→ 同容器冷重启 →
  A、B 按 9：A “石屋 · 我”、B “石屋 · 玩家 359443468289”（模式面板截图可见）；B 瞄 (48,518,67) 顶面放置，锚 micro (320,4152,472)（手算），txn 670602，
  (48,519,67)(49,519,67)(48,519,68) 木材 placed_by B，B 木 −6,291,456、A 不变；判定器经真实 HTTP 列表核对旧三项不变、新项发布者 A、名称“石屋”、字节解码为上述三格。
  截图已实际检查（长名输入、拒绝反馈、Esc 后、输入“石屋”、发布后、B 选中与放置后、A 选中）。
  **原始失败保留** `naming-01/`（`naming-01.out`）：①通用故障过滤把本场景预期的一次 `:invalid_name` 当故障（判定器改为只在 A 发布阶段容许该原因，时间线仍要求恰好一次）；
  ②真实缺陷：Esc 被输入框外壳吃掉、焦点移出内层文字框，之后 Enter 不再提交（以 `SlateDebugger` 探针 `probe-01` 定位，改为隧道阶段截 Esc 后 `probe-02` 通过）；
  ③夹具：第三格瞄点被第一格挡住，叠成与 D3-1 相同的形状（同 id 重发不改名），放置顺序改为由远及近；该次 B 按 9 选中增量 2 作品放在 (46..48,519,65..66)，保留在测试世界。
  当前判定器对 naming-01 复判仍失败（只发出一次 0x71），对 naming-02 复判通过。输入框默认浅底白字对比度不足、MONOLITH 按钮不报告高度，已在资产里改深底主文字色、外包 48 高 SizeBox。
- `smoke.py --mode prefab_editor` 与 emergent_loop／circuit_fire 的发布步骤改为 `Enter` + `@slate Enter`（空名）。prefab_editor 本次未重跑：它要求“列表最新一项 = 增量 1 形状”且台面
  x∈[43,45] 有空双行，当前世界两者都不成立（重跑需新部署）。回归：`deploy.py --reset` 后 `smoke.py --mode circuit_fire` → `fire-naming-01` 十五项全过、退出 0
  （119.565984 A、源耗电 57,391.7 W，合闸后 83.2 s HOST、186.6 s 云杉底起燃，7.32 MJ 已供、5.18 MJ 弃置，双端 1246 条燃烧确认一致；截图已看）。
- **未验证（需人工）**：系统中文输入法。回放的 `@type` 走 Slate 字符入口，不经 Windows TSF 组合，不能证明组合、选词与组合中 Enter 的行为。人工步骤：
  编辑器 Play `L_GameplayDemo`（连协议 18 的独立旧 Demo）或 `-game` 客户端 → `P` 进编辑空间放一格 → `Enter` 打开对话框 → 切到微软拼音 →
  输入 `shiwu`，候选框出现后按 `Enter`：应只把拼音上屏／结束组合、**不得**发布或关闭对话框；再用空格选“石屋”上屏，确认输入框显示“石屋”、无截断；
  组合中按 `Esc` 应只取消组合；最后无组合时按 `Enter` → 反馈“已发布”，`9` 选中显示“石屋 · 我”。若组合中 Enter 就发布了，需在提交处判断组合态（另开增量）。

## D3-3 增量 4：青岚集成（只本地，未部署）

分类：青岚接线、发布工具与本地版本为只分发；共享按键表 `Voxim/Docs/R7/tools/player_controls.py` 为全局系统功能；冒烟与回放命令 `@await_intents` 为只测试。服务端源码未改（master `c89a6f8d`）。

- **已实现**：青岚关卡摆放 `BP_PrefabWorkbench`、名称对话框、清单 HUD、编辑说明、`P／Enter／9`（与 Demo 同一份按键表）、中文 `invalid_name`、工具 19 进 `C` 循环；
  Asset Registry 依赖检查 1244 个包、唯一地图 L_Qinglan、0 个 Test-only（MONOLITH 面板／按钮改标全局）；打包 1092 个包，无 Test-only 资产或模块。
- **已实跑（本机）**：镜像 `voxim-qinglan-server:20260923-qinglan-prefab-editor`（协议 18）运行在青岚世界与数据库的副本上，目录经 `World.publish_parameters` 从 `e4dc89a4…` 升到 `4b2c6abe…`，
  seq 145→146，overlay／refined／micro／实例／余额逐项不变，副本无点燃行（`fuel_rebase_j = 0`）。`smoke.py --mode prefab_editor` 改为按定义 id 识别发布、按 before 快照选场地，
  设计器容器复跑通过（txn 674932），青岚副本 smoke-02 通过（txn 151；smoke-01 因回执晚到 7.5 s 而实例读数过早，保留失败）。打包客户端双端人工输入冒烟：采集、编辑、命名“木亭”发布、`9`、放置、另一端可见、`K` 点火两端一致。
- **未做**：公网部署、公网双端实跑、系统中文输入法组合。记录与部署步骤见 `Voxim/Docs/Playtest/release-20260923-qinglan-prefab-editor.md`。

## D3-4 增量 1：建模式编辑（只改客户端，协议仍为 18）

分类：全局系统功能（`FVoxelPrefabDraft` 的选择／平移／复制／删除／重做与盒外射线、`Voxel/Prefab/VoxelPrefabGizmo`、交互组件的编辑空间输入与相机、
工作台资产上的 `SelectionSurface`／`Gizmo` 组件、`PrefabEditor/` 下的控件与选中材质、`WBP_EditorMarquee`）；`L_GameplayDemo` 接线、回放命令
`@cursor`／`@cursor_px`、`Voxim/Docs/Gameplay/prefab_dcc.py` 冒烟与各场景脚本的编辑段迁移为只测试。服务端未改：发布、放置与裁决不变。

2026-10-02 用户要求：编辑空间改成 3ds Max 一类建模软件的操作方式——相机只用于观察，用鼠标指针和坐标轴控件变换，不再用越肩准星。
同日拍板：相机按“游戏友好式”（右键拖环绕、中键拖平移、滚轮缩放、Alt+中键也可环绕）；体素没有无级缩放，“缩放”工具改为推拉面（后续增量）；
旋转只绕竖直轴（与子件朝向、世界放置一致）。路线：①相机／指针拾取／选择／移动控件／删除复制／重做（本增量）→ ②拖拽创建盒／空心盒／线、逐层工作平面、刷材质
→ ③旋转控件、镜像、复制粘贴、子件变换 → ④载入已发布件继续编辑或另存、正交与预设视角。

- **输入**：`P` 进入时压入一个阻塞的输入组件（`BindEditorInput`），编辑中的键鼠全部由它处理，角色、控制器按键蓝图和世界交互都收不到；
  `P` 离开时弹出。指针常显、不锁进视口（`FInputModeGameAndUI`）。名称对话框关闭后回到这个输入方式。原来经世界按键表转进编辑的
  `AttackTarget`／`BuildTarget`／`CycleAttachmentMode`／`RotatePrefab`／`SelectPrefabLeaf` 分支与角色的 `MovementRedirect` 已删。
- **相机**：环绕状态（枢轴、偏航、俯仰、距离，工作台局部 canonical 米）每帧推出编辑相机；初始枢轴为盒心偏下 (32,12,32)、偏航 90°、俯仰 −35°、22 m。
  右键／Alt+中键拖环绕 0.3°/px，中键拖平移（枢轴随指针，每像素 = 距离 × 0.0015 m），滚轮每格距离 ×0.85（2–60 m），`F` 聚焦所选（无选择时整个草稿）。
  相机可在草稿 Tile 外：`FVoxelPrefabDraft::Pick` 先把射线推进到驻留范围（Tile 0 核心 [0,64)³，`IsResident` 按 `VoxelTileOf`）再求交。
- **两种工具**：选择（`W`，默认）——左键点选，Ctrl+左键加减选，拖出框为框选（元素中心投影在框内，不论遮挡），`Del`／退格删除，`Ctrl+A` 全选，`Esc` 取消；
  画笔（`B`）——左键放置当前块类（`Q` 循环整块／小块／薄面／细线，`Q` 也切到画笔），Shift+左键删除命中元素。`2–8`／`9` 选拼装件后左键插入子件，`R` 转子件朝向，`1`／`Esc` 退出插入。
  换料在编辑空间里是 `Tab`／`Shift+Tab`（滚轮是缩放）。撤销／重做 `Ctrl+Z`／`Ctrl+Y`（`Ctrl+Shift+Z` 同重做）；`R`（未选子件时）仍为整体旋转；`Enter` 命名发布。
- **选择元素**（`FVoxelDraftElement`，只认顶层）：整块（定义局部宏格）、小块（定义局部 micro）、附件组（Slot）、顶层子件（Slot）。点选优先级：子件 > 薄面组 > 细线组
  （命中点离棱 ≤ 1/16 m）> 小块 > 整块。
- **移动控件**：选中时出现在所选包围盒中心（只选附件时取附件中心平均），长度 = 相机距离 × 0.12。三条轴（canonical X 红、竖直 Y 绿、Z 蓝）与三个平面方块
  （两轴 [0.25, 0.45] 倍长度）；判定在屏幕空间：先平面方块（投影四边形内，投影面积 < 12² px 的近侧对方块不参与，否则会盖住旁边的轴），再轴（指针到投影线段 ≤ 10 px）。
  拖动＝指针射线与轴（或平面）的最近点位移，按步长取整：含整块或子件时 8 micro（1 m，宏格对齐），只有小块／附件时 1 micro；Shift 拖动为复制（新件取新 Slot，
  松手后选中复制出的元素）。位移变化时用 `CanMove` 预检，选中高亮整体平移并换成有效／阻挡材质；松手提交，不合法则不变并提示原因（出盒、格重叠、薄面／细线悬空）。
- **草稿规则**（`FVoxelPrefabDraft::Move`／`Delete`／`Redo`，与服务端发布裁决同口径的本地预检）：结果全部在 16 m 盒内、宏格与小块不重叠、小块不进整块、
  附件槽不重叠且全部有支撑；删除后失去支撑的附件组随之移除（与 `Remove` 同一规则）。新编辑清空重做栈。
- **资产**（`Voxim/Docs/Gameplay/author_workbench.py`）：工作台加 `SelectionSurface`（同 ChildPreview 的 ISM）与 `Gizmo` 场景组件（6 个箭杆／箭头用引擎圆柱／圆锥，3 个平面方块用引擎平面）；
  `M_EditorGizmo`（不受光、半透明、不做深度测试）及 `MI_GizmoAxis{X,Y,Z}`／`MI_GizmoPlane{X,Y,Z}`／`MI_GizmoHover`（`text.primary`）；
  `M_PrefabSelection`（UI 规范 `selection` 色、35 % 不透明、沿顶点法线外推 2 cm）；`WBP_EditorMarquee`（`selection` 色 12 % 底 + 1.5 px 描边）。
  交互组件新属性 `PrefabSelectionMaterial`／`GizmoHoverMaterial`／`MarqueeWidgetClass` 由关卡指定（`place()` 写入）；青岚接线留到下次分发集成。

**D3-4 增量 1 已实现、已实跑；D3 整体未验收。**

- 客户端单元（手算期望）：`Voxim.Prefab.Draft.SelectMoveCopy`（盒外射线距离 91、点选、步长 8、撞木／半米／出盒拒绝、上移 1 m、复制、撤销／重做、删除清空重做栈）、
  `Voxim.Prefab.Draft.SelectAttachmentsAndMicro`（点中面组非棱、面组单独上移悬空被拒、格与面组同移、小块步长 1、删格连带面组）、`Voxim.Prefab.Gizmo.Math`
  （射线—轴最近点 s = 3、平行无解、射线—平面、点到线段、凸四边形两种绕向、取整）。受影响范围 `Voxim.Prefab.+Voxim.R7.Prefab.+Voxim.R7.Hierarchy.+Voxim.Raycast.`
  31/31（首跑盒外射线按 [0,66) 裁剪、落在 ring 上不驻留而失败并崩在测试里的未检查取值，已改 [0,64) 与测试先判后取）。
- 实跑（r8acc Demo `voxim-r8acc`，镜像 `voxim-server:20261001-r8acc`，协议 35，空世界）：`python Docs/Gameplay/prefab_dcc.py --out Saved/Gameplay/prefab-dcc-20261002/run-01`。
  真实单客户端，键鼠走 `@press`，指针走 `@cursor`（Slate 平台移动入口；回读 `GetMousePosition` 与投影像素差 ≤ 0.5 px）。15 个状态块逐一与手写期望相同：
  画笔三格 (8..10,0,8) → 点选 (9,0,8) → Ctrl 加选 → 拖竖直轴上移 2 m 为 (9,2,8)(10,2,8) → Shift 拖 X 轴 3 m 复制出 (12,2,8)(13,2,8) 并选中 → Esc →
  框选 5 → 删除为空 → Ctrl+Z／Y／Z → 环绕 +150／−50 px、滚轮两格为偏航 135°、俯仰 −20°、距离 15.89 m → F 聚焦整稿 (35,9.5,32.5)、10.85 m →
  命名“DCC测试”发布，服务端真实 HTTP 列表含同名同 id。原始判定把环绕一项判败：判定器正则 `pivot=\S+` 匹配不了带空格的枢轴坐标（数值本身正确），
  修正后 `--recheck` 写 `acceptance-recheck.json` 全部通过，原始 `acceptance.json` 保留。截图已看（选中高亮、控件、复制、框选、聚焦、回到世界）。
  `run-02` 在发布前加了迁移脚本所用的操作：画笔 `Tab` 放一格（下一种材料，Demo 为冰 20）、`Shift+Tab` 再放一格（回到木材 19）、`Q` 小块落在地面格顶
  局部 (66,8,66)、`Q Q Q` 回整块、Shift+左键删 (9,2,8)、`3` 插入作者件“黏土隔热桥”、`1` 退出，19 个状态块与 27 项全部符合；首次判定在写结果时崩溃
  （判定器把元组作 JSON 键，未写出 acceptance.json），修正后 `--recheck` 通过。证据 `Voxim/Saved/Gameplay/prefab-dcc-20261002/run-0{1,2}/`。
- 场景脚本迁移（只测试）：`emergent_loop.Timeline` 加 `editor()`（P + B）、`brush(点, erase)`（指针 + 左键／Shift+左键）、`tab(n)`；`smelting_loop.Player`
  加 `edit_select(材料)`；`emergent_loop`／`circuit_fire`／`lamp_material`／`loose_pile`／`magic_range`／`body_revive`／`device_hud`／`smelting_loop`／`smoke.py`
  （`prefab_editor`、`prefab_naming`）的编辑段由“准星 + 右键 + 滚轮”改为上述辅助。这些场景本次未逐个复跑（它们的编辑段只是搭夹具），
  辅助本身在 `prefab_dcc` 里实跑。`showcase_bergen.py`（宣传视频，自己移动编辑相机）未迁移。
- 未做：上面路线的 ②–④；青岚关卡接线；演示 HUD 右侧操作指南里旧的编辑说明（左侧编辑反馈已是新说明）。

## D3-4 增量 2：拖拽建形、逐层工作平面、刷材质（只改客户端，协议仍为 18）

分类：全局系统功能（`FVoxelPrefabDraft::PlanFill／Fill／Paint／PlaneCell`、`DraftShapeCells`、工作平面拾取、交互组件的形状与刷料工具、
工作台资产上的 `WorkPlane` 组件与 `PrefabEditor/MI_WorkPlane`）；`prefab_dcc.py` 增量 2 段、`test_prefab_dcc.py` 判定器反例、
`deploy.py --stage prefab` 部署为只测试。服务端未改。

2026-10-03 开工前与用户确认的交互（四项都选推荐）：盒子两段式（3ds Max 式）；空心盒 = 封闭外壳；线在平面内任意方向、Shift 锁轴；
盒子／线的起点始终在工作平面上（不吸附已有表面）。

- **工具键**：`X` 实心盒、`H` 空心盒、`L` 线、`M` 刷材质（`W` 选择、`B` 画笔不变；`E` 留给 ③ 旋转）。形状只用整块或小块：
  形状工具里 `Q` 在两者之间切换，薄面／细线工具时按整块。
- **工作平面**：`PgUp`／`PgDn` 升降，整块一层 1 m（第 0–15 层），小块一层 1/8 m（第 0–127 层）；高度存为定义局部 micro，整块类工具取整到整米。
  抬离盒底时显示 16×16 m 半透明面（`WorkPlane`，选中高亮主材质的实例，telemetry 色 12 %）；状态栏显示“工作层 N m”。
  画笔与插入子件时，指针没命中格、或平面比命中的格更近，就落在平面上（格底贴平面）；平面在盒底时与以前只有地面完全相同。
  选择与刷料不拾取平面，平面挡不住它下面的格。
- **盒子**：左键在工作平面上按下、拖出底面、松开；之后指针射线到过底面远角 B 中心的竖直线的最近点定高度
  （向上时盒顶随指针，按层四舍五入；也可向下），单击生效，右键／`Esc` 取消。**空心盒**为壁厚一格的封闭外壳，只有一层高时为一圈。
  **线**：拖动、松手即生效，格子直线（主轴每步一格，副轴四舍五入、远离零取整）；按住 Shift 锁到离起点更远的水平轴。
  拖动中虚影用 `ChildPreview`（有效／阻挡材质），状态栏显示尺寸与新增格数。
- **形状规则**（`PlanFill`）：只填空格（整块跳过含小块的宏格，小块跳过整块里的 micro），整个形状算一步撤销；全部已占为“已全是方块”；
  任一角出 16 m 盒则拒绝（虚影画出整个形状并标阻挡）；填上后超出服务端 `Prefab.limits`（展开后宏格 512、micro 8192）则拒绝。
  形状格数先按公式算（实心 = 长×宽×高，空心 = 实心 − 内部，线 = 主轴长 + 1），已占的格本就计入现有总量，所以格数本身超限就一定超限，
  不必先枚举（小块盒最大 128³）。
- **刷材质**：左键单击或按住拖过，命中的整块／小块／附件组改成当前材料；材料相同不算一步；一次拖动并入同一步撤销（`Commit` 的 amend）。
  子件是引用，不能刷（提示“子件是引用，不能刷材质”）；不能放的材料（液体、花草等）同样不能刷。

**D3-4 增量 2 已实现、已实跑（单端）；D3 整体未验收。**

- 客户端单元（手算期望）：`Voxim.Prefab.Draft.ShapeCells`（实心 2×2×3 = 12 且两角顺序无关，空心 3³ = 26 无中心，一层空心 4×4 为 12 格一圈，
  两层空心 3×2×3 全满 18，线 (0,0,0)→(4,0,2) 与反向、直线、单格）、`Voxim.Prefab.Draft.FillAndWorkPlane`（跳过已占格、一步撤销／重做、
  全占为 Empty、出盒拒绝且虚影为整个形状、576 格超限、512 新格 + 3 已有超限、空心 10³ = 488 不超限、小块线跳过整块里的 micro、
  整块盒跳过含小块的宏格、128×1×65 小块超限、平面第 3 层放格、平面比下方格更近、盒底平面不挡格、1/8 m 平面放小块、平面上的子件锚点、
  平面格与从下方求交、平行无解）、`Voxim.Prefab.Draft.Paint`（一笔两格一步撤销、同料不算、面组、小块、子件拒绝、空处拒绝）。
  受影响范围 `Voxim.Prefab.+Voxim.R7.Prefab.+Voxim.R7.Hierarchy.+Voxim.Raycast.` selected=34 completed=34 failed=0（首跑即过）。
  判定器反例 `python -m unittest Docs/Gameplay/test_prefab_dcc.py` 4/4：合成的正确日志通过，刷料撤销只回一半、出盒盒被接受、空心盒被填满各自判败。
- 实跑：新部署 `deploy.py --stage prefab --create`（容器 `voxim-d3dcc`，镜像 `voxim-server:20261002-r8close` = master `99d1c5e5`，
  协议 35，目录 `b4d8bf35…`，空世界；旧 r8acc 镜像无材料 45，与当前客户端目录不符）。客户端从提交的独立 worktree `../Voxim-d3` 编译。
  `prefab_dcc` 在增量 1 的流程后加：PgUp×2 画笔落在第 2 层 (36,10,26)；`X` 第 1 层拖底面 (26,9,34)–(28,9,35)、指针升 2.2 m（两层）、单击 →
  12 格木材；`H` 地面 (31,8,35)–(34,8,38) 升 3.2 m → 4×3×4 外壳 44 格；`L` (24,8,37)→(28,8,39) 5 格、Shift 锁轴 (24..29,8,35)；
  `X` 拖到 x = 41 出盒 → `result=2`、草稿不变、提示“超出 16 m 编辑盒”；`M` 刷盒顶前排 (26..28,10,34) 一笔 → Ctrl+Z 三格一起恢复木材、Ctrl+Y 再刷上。
  28 个状态块与 12 项专项判定全部符合，发布后服务端 HTTP 列表含同名同 id。
  - run-01（a3edb72，刷料用 `Tab` 冰 20）通过，退出 0；但截图里刷上的冰几乎看不见：草稿预览只有一个不透明 ISM，透明材料（冰、玻璃）
    画得很淡——这是增量 1 起就有的预览限制（世界里透明材料走单独的透明通道），不影响定义与清单（清单显示冰 4 m³）。
  - run-02（ca48193，刷料改 `Shift+Tab` 金矿石 18；部署先 `--reset`）通过，退出 0；截图已看：工作层半透明面、两段式盒子的高度虚影、空心盒、
    两条线、出盒提示、盒顶前排三格的顶面与正面变为金矿石。证据 `Voxim/Saved/Gameplay/prefab-dcc-20261003/run-0{1,2}/`
    （截图在 `Voxim/Captures/Saved/Gameplay/prefab-dcc-20261003/run-0{1,2}/shots/`）。
- 未做：草稿预览的透明材料通道（冰／玻璃在编辑空间里画得很淡）；演示 HUD 右侧操作指南仍是旧编辑说明；③ 旋转控件、镜像、复制粘贴、子件变换；
  ④ 载入已发布件续编／另存、正交与预设视角；青岚接线；用户手动试用。

## D3-4 增量 3：旋转控件、镜像、炸开子件、复制粘贴（只改客户端，协议仍为 18）

分类：全局系统功能（`FVoxelPrefabDraft::Rotated／RotateSelection／Mirrored／MirrorSelection／Explode／Copy／Paste`、控件几何
`RingAngle／SnapQuarterTurns`、交互组件的旋转工具／剪贴板、工作台资产上的 `GizmoRing`／`GizmoRingHover` 与 `PrefabEditor/M_EditorGizmoRing`、
`MI_GizmoRing`、`MI_GizmoRingHover`）；`prefab_dcc.py` 增量 3 段与 `test_prefab_dcc.py` 的点击射线干跑为只测试。服务端未改。

2026-10-03 与用户确认（四项都选推荐）：`E` 圆环控件 + `R` 快捷；镜像含子件时拒绝并另加“炸开子件”；盖章式粘贴；镜像键 `Alt+X`／`Alt+Z`。
旋转只绕竖直轴（10-02 已定）。“子件变换”= 已插入的子件可被选中后旋转（锚点与朝向一起变）、移动、复制、粘贴、炸开。

- **旋转**：`E` 是旋转工具（点选、框选同 `W`），控件换成绕竖直轴的圆环（2 m 平面上的环形材质，半径 = 控件长度 × 0.9，不做深度测试）；
  拖动时指针射线与过控件原点的水平面求交，角度差按 90° 吸附，圈数变化时预检并把选中高亮换成转后的样子（有效／阻挡材质），松手生效。
  `R`／`Shift+R` 把所选顺／逆时针转 90°（从上看，朝向 1 = +X 转到 +Z）；没有选择时 `R` 仍整体旋转草稿，插入子件时仍转子件朝向。
  枢轴取离所选包围盒中心最近、且转完格仍对齐的竖直线：A = round((cx − cz)/S)·S、B = round((cx + cz)/S)·S、2p = (A + B, ·, B − A)
  （S = 1 m 若含整块或子件，否则 1/8 m），实现为“绕原点转 + 平移 p − R·p”，平移量必为 S 的倍数。一边奇一边偶的形状中心偏半格，
  连转四次不保证回原处。结果合法性与移动相同（盒内、不重叠、附件有支撑）。
- **镜像**：`Alt+X`／`Alt+Z` 以所选包围盒中线为镜面（按 S 取整）翻转：格 k → M − k − 1，面／棱两端点各自翻转后取最小角、轴不变。
  所选含子件时拒绝（“所选含子件，不能镜像（先按 [U] 炸开子件）”）：子件朝向只有 24 种真旋转，格式表示不了镜像。
- **炸开子件**：`U` 把所选子件展开一层：子件定义按它的朝向绕原点转、平移到它的锚点后并入根（附件与它自己的子件取新 Slot），
  占地不变；展开出的元素成为选择。
- **复制粘贴**：`Ctrl+C`／`Ctrl+X` 把所选（只有附件时拒绝）平移到原点存入剪贴板（本次会话内跨草稿保留）；`Ctrl+V` 进入盖章：
  虚影跟随指针（`ChildPreview`，锚点规则同插入子件：贴命中面外侧或工作平面上，含整块或子件时宏格对齐），左键放下可连续，
  `R`／`Shift+R` 转 90°，`Esc` 退出；每次放下的元素成为选择。
- **控件可见性**：每个手柄组件直接设目标可见性（不再由根组件向下传播后再隐藏圆环）。

**D3-4 增量 3 已实现、已实跑（单端）；D3 整体未验收。**

- 客户端单元（手算期望）：`Voxim.Prefab.Draft.RotateMirror`（撞格拒绝、枢轴 (76,68) 转一次、一步撤销、转 4 圈不算编辑、X 向镜像格与 −x 面组翻到 +x、
  小块 Z 向镜像互换材料、一排格转出盒被拒）、`Voxim.Prefab.Draft.Explode`（含嵌套子件的件朝向 1 炸开为确定的格／小块／面组／根子件、
  占地集合不变、选择 5 个、子件镜像被拒）、`Voxim.Prefab.Draft.CopyPaste`（只有附件拒绝、剪贴板在原点、贴空地、转向贴、叠放、出盒拒绝）、
  `Voxim.Prefab.Gizmo.Math` 加圆环角度与 90° 吸附。受影响范围 selected=37 completed=37 failed=0。首跑 1 项失败：测试用 float 常量 `HALF_PI`
  与 double π/2 比较超出默认容差，改用 `UE_DOUBLE_HALF_PI`（期望仍为 π/2，未放宽容差）。
  判定器反例与夹具干跑 `python -m unittest Docs/Gameplay/test_prefab_dcc.py` 7/7（新增：炸开后仍有子件、盖章锚点错误各自判败；增量 3 每一击的射线按当时的格集合干跑）。
- 实跑（`voxim-d3dcc`，每次先 `--reset`；客户端为独立 worktree 编译的已提交版本）：
  - run-03（a1e82c6）失败：①场景夹具——L 形第二击的地面点被增量 2 的悬空格 (36,10,26) 先挡住、第二次盖章的地面点在 (37,10,32) 之后；
    ②回放时序——第一批控件拖动中出现 3.34 s 的长帧，状态命令挤到松手之前，增量 1 的“Shift 复制”一块读到复制前的草稿。
  - run-04（0dc9e88，夹具已挪开）失败：L 形第三击被第一击刚放的格挡住（干跑只算了点击前的格）；长帧仍在（3.02 s、1.67 s），这次落在“上移 2 m”。
    run-01／02（增量 2 构建）没有超过 1 s 的帧，长帧是增量 3 引入的：`TickGizmo` 每帧先由根组件把圆环设为可见再隐藏，圆环的渲染状态每帧重建。
  - run-05（8fdb383：手柄逐个设可见性；L 由远到近下笔，干跑逐格累积）：没有超过 0.5 s 的帧；增量 3 全部 9 块与 `edits`（圆环 1、R 1、Shift+R 3、
    两次镜像、两次盖章锚点 (288,64,264)／(280,64,232)、炸开）、`child_pick`、`explode`（无子件、小块 161）全部符合；最后三块判败——判定器把炸开后的
    选择期望写成 0，实际保留 160 个展开元素被选中（设计如此，几何一致），修正期望后 `--recheck` 通过（77e5b16），原始 `acceptance.json` 保留。
  截图已看（圆环与悬停色、转后与镜像后的 L、两次盖章与粘贴虚影、炸开后的选中与常态绿环）。证据 `Voxim/Saved/Gameplay/prefab-dcc-20261003/run-0{3,4,5}/`，
  截图在 `Voxim/Captures/Saved/Gameplay/prefab-dcc-20261003/run-0{3,4,5}/shots/`。
- 未做：④ 载入已发布件续编／另存、正交与预设视角；草稿预览的透明材料通道；演示 HUD 右侧操作指南；青岚接线；用户手动试用；系统中文输入法。

## 状态

**D3-1 已实现、已实跑；D3 整体未验收。**

- 单元：`Voxim.R7.Prefab.MacroCellsV3`（服务端冻结 v3 字节逐字节相同、宏格占地两种朝向、宏格预览面积手算 384/388）、
  `Voxim.R7.Prefab.PublishWire`（与服务端解码测试同形的 0x71 帧）、`Voxim.Prefab.Draft.PickEditAndDefinition`（手算拾取／叠放／出盒／局部坐标），
  及受影响的 prefab／附件／层级／射线／植被测试共 37 项通过；Hello 版本测试同步为 17。
  服务端 `apps/mmo_contracts` 115 passed（含 0x71 解码与截断/多余字节拒绝、Hello16 拒绝），全伞编译通过。
- 实跑（独立旧 Demo，镜像 `voxim-gameplay:prefab-editor-20260923`，由当前工作区正常 Linux Mix 构建，源码清单见
  `Voxim/Saved/Gameplay/prefab-editor-20260923/image/source-manifest.json`；切换前后余额、探测格、目录一致）：
  `smoke.py --mode prefab_editor` 真实客户端进入编辑空间放 3 格（10 个面实例，构建 0.15 ms）→ 发布 17 ms 内接受，
  定义 `33ffc16ace9de3e81da3e21c03ebfb183e73a27a8fb44882d1caffd4b97e9cec` 写入世界目录 `prefabs/` → 回世界按 9 选中、瞄准台面放置，
  txn 626356 接受；服务端快照三格 (43,519,57)(44,519,57)(43,520,57) 为木材宏格、placed_by 为该角色，木材正好扣 3 宏格（6,291,456 单位）。
  截图已实际检查（编辑空间网格地面与草稿、放置后世界与选中高亮）。证据 `Voxim/Saved/Gameplay/prefab-editor-20260923/editor-04/`。
- 回归：同镜像上既有 `smoke.py --mode assembly`（双客户端逐笔复制、材料恢复）与 `floor_attack` 通过。

原始失败保留在同目录：`editor-01`（瞄准视线被台面方块挡住）、`editor-02/03`（工作台 Actor 实际落在原点，`add_to_scene_from_class` 未接受位置；
编辑相机组件需显式激活）。`editor-03` 中自制件列表为空时的右键按普通建造在 (40,519,57) 放了 1 m³ 木材（玩家正常操作，保留在测试世界）。
升级时 `isolated-server/entry.exs` 的协议守卫从 16 改为 17，首次启动失败记录在 `upgrade.py` 输出。

## 命令

```powershell
# Voxim
python Docs/R5/tools/run_tests.py filter=Voxim.Prefab.Draft.+Voxim.R7.Prefab.+Voxim.R7.B4.+Voxim.R7.Hierarchy.+Voxim.Raycast.+Voxim.Foliage.
python Docs/Gameplay/author_workbench.py; python Docs/Gameplay/author_controls.py; python Docs/Gameplay/author_chinese.py   # 编辑器开着 MCP 8000
python Docs/Gameplay/smoke.py --mode prefab_editor --server-dir Saved/Gameplay/prefab-designer-20260922/isolated-server --container voxim-prefab-designer-test --out <新目录>
# ex_mmo_cluster/apps/mmo_contracts
mix.bat test
# D3-2（RUSTUP_TOOLCHAIN=1.91.0，MMO_DB_PORT=5433）
#   apps/voxel_region: mix.bat test test/prefab_runtime_publish_test.exs ...；apps/auth_server: mix.bat test test/auth_server_web/controllers/voxel_prefabs_controller_test.exs test/auth_server_web/playtest_access_test.exs
#   Voxim: python Docs/Gameplay/smoke.py --mode prefab_editor ... --out <新目录> --row <空行>（D3-3 起占 row 与 row+1）；镜像与切换 Voxim/Saved/Gameplay/prefab-bill-20260923/{build_image.py,upgrade.py}（W-A 为 prefab-list-20260923）
# 镜像与切换（只测试）：Voxim/Saved/Gameplay/prefab-editor-20260923/{build_image.py,upgrade.py,upgrade-resume.py}
# D3-3 增量 3（协议 18）：python Docs/Gameplay/author_name_dialog.py（MCP 8000）；镜像 Voxim/Saved/Gameplay/prefab-naming-20260923/{build_image.py,upgrade.py designer|emergent,recheck.py}
#   python Docs/Gameplay/smoke.py --mode prefab_naming --server-dir Saved/Gameplay/prefab-designer-20260922/isolated-server --container voxim-prefab-designer-test --out <新目录>
# D3-4 增量 2（Voxim，Test-only）：python Docs/R8/r8acc-demo/deploy.py --stage prefab --create|--reset
#   python Docs/Gameplay/prefab_dcc.py --out Saved/Gameplay/prefab-dcc-20261003/<新目录> --server-dir Saved/Gameplay/prefab-dcc-20261003/server --container voxim-d3dcc
#   python -m unittest Docs/Gameplay/test_prefab_dcc.py；单元 python Docs/R5/tools/run_tests.py filter=Voxim.Prefab.+Voxim.R7.Prefab.+Voxim.R7.Hierarchy.+Voxim.Raycast.
```
