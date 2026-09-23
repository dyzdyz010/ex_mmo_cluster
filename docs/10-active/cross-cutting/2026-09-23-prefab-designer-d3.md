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
# 镜像与切换（只测试）：Voxim/Saved/Gameplay/prefab-editor-20260923/{build_image.py,upgrade.py,upgrade-resume.py}
```
