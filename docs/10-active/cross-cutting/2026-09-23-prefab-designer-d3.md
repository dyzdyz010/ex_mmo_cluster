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
（发布者与跨会话列表已由下节 D3-2 W-A 完成；名称为派生、不存储；D3-2 定案不暴露 `PrefabDesigner.check`、不做命名输入框。）

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

**W-A 已实现、已实跑；D3 整体未验收**（W-B 撤销／材料清单未做）。

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
#   Voxim: python Docs/Gameplay/smoke.py --mode prefab_editor ... --out <新目录> --row <空行>；镜像与切换 Voxim/Saved/Gameplay/prefab-list-20260923/{build_image.py,upgrade.py}
# 镜像与切换（只测试）：Voxim/Saved/Gameplay/prefab-editor-20260923/{build_image.py,upgrade.py,upgrade-resume.py}
```
