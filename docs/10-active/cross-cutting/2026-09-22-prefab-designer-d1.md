# Prefab Designer D1：服务端工作台

分类：全局系统功能；测试脚本与样本为只测试。依据 [已批准设计 §7](2026-09-21-prefab-macro-cells-design.md)。

## 边界

草稿就是 decoded VXPD v3 定义。`VoxelRegion.Prefab.Draft.new/0` 新建，`edit/2` 原子执行有序操作：

- `fill / walls / clear`：macro 闭区间；`walls` 只生成四面竖墙，没有隐式地板或天花板。
- `micro`：指定 micro 坐标与材质；材质 0 删除该格。
- `prefab`：按 slot 增改目录引用，带内容 id、micro 锚点与 0–23 朝向；`remove_prefab` 删除该 slot。

盒操作算法在 `VoxelRegion.Blueprint`，原 `GateServer.Npc.Blueprint.cells/1` 委托它，荒野施工的 2000 格契约保留。
编辑可暂存空草稿或尚未通过结构检查的中间态；盒操作暂存最多 16³ 格，允许先填再挖。发布时以正式上限检查最终定义。
没有额外操作历史、世界副本或编辑进程。`Prefab.encode/1` 排序生成 v3 字节，sha256 即定义身份。

## 运行时发布

`World.publish_prefab(world, actor, bytes)` 经现有 `current_actor` 刷新会话；`Prefab.compile/2` 在展开前按每次引用累计限制，
重复引用不能绕过额度。成功后复用 v3 的对齐、空间重叠、附件支撑检查。上限唯一来源为 `Prefab.limits/0`：

- 512 宏格、8192 micro 格、64 展开节点、8 层（根为第 1 层）。
- 包围盒各轴 16 m；按体积端点计算半开包围盒，包含旋转后的子树。
- 8192 个展开附件槽位；face 的 size² 与 edge 的 size 分别计数。
- 编码上限 296999 B，由以上最大计数与格式固定段宽推导。

单根限制通过后才展开。不限制只测试的作者整目录入口。目录只读 API 为 `World.prefab_catalog/1`；每项包含原始定义、展开节点与摘要。
运行时发布原子写入世界目录的 `prefabs/<sha256>.vxpd`，成功才加入在线目录；重启时与部署作者目录合并加载。
发布不扣料、不产生体素事务；放置仍走已有 prefab 裁决和结算。未改变 Hello、客户端线格式、content_version 或旧实例。

## 检查

`SceneServer.PrefabDesigner` 组合草稿、正式 World 只读入口与 Scene 的 profile / 出生探测配置。
`SceneServer.PrefabDesigner.Check` 是纯检查：显式入口、目标脚点、室内范围及有限检查窗口；逐层切面和立面用文本显示。
门洞与楼梯按实际 micro 几何复用 `Movement.Path`，搜索额度耗尽与无路分开报告。旧 map 输入和调用参数保持兼容。

净高从脚点到第一层障碍计算；只有明确给出的室内范围才报告整屋屋顶覆盖。未提供 ground_y 时悬空检查为 unknown。
悬空只表示与显式地面没有实心面邻接连通，不冒充结构工程模拟。路径结果证明离散行走，不等同于连续碰撞实跑。
材料单位复用正式 Damage / Attachments 结算，工地检查读取实际占用、余额与 placed_by。出生点只作诊断，不新增世界放置权限。

## 联合上限实测

2026-09-22，Windows 本机 Mix、真实隔离 World，有限作者供给后走运行时发布与付费放置：
同一棵树同时达到 512 宏格、8192 micro、64 节点、8 层，三轴包围盒均 128 micro。

- 根定义 7241 B，全部 9 个内容定义合计 124389 B。
- 编译 6.246 ms，运行时发布 6.860 ms，放置 2904 ms。
- 压实检查点 55453 B，重启 514.252 ms。
- 付费放置后对应库存归零；压实与重启恢复 64 个实例和 128 个 refined 宏格。
- 同一样本检查 109.363 ms：窗口 144×152×144 micro、1920 室内列、16 步外围通路；屋顶覆盖为 0/1920，正确报告该容量样本没有屋顶。

这是一次同时达限样本的实际开销，不是吞吐保证。宏格仍走现有宏格 LOD 事务，不能因定义小就声称放置快。
测量入口为 `apps/voxel_region/test/prefab_runtime_publish_test.exs` 的 `:benchmark` 用例。
原始结果为 `../Voxim/Saved/Gameplay/prefab-designer-20260922/d1-combined-measurement-final.log`，检查脚本与日志为同目录 `d1-check-measure.{exs,log}`。

## 状态

**已实现、已实跑、D1 已验收。** D2 会话与 D3 玩家 UI 不计入 D1 完成声明。

- 草稿与最终运行时发布：13 passed / 1 benchmark excluded，`d1-voxel-final.log`；组合上限另单独实跑通过。
- 既有 Prefab 定义与真实宏格 World 回归 45 passed；原荒野 Blueprint 5 passed。
- Path 与 Check 30 passed；真实 World / Scene 对外入口 8 passed。缺失模块、附件冲突漏报、读取竞争及宏格错误码的原始失败均已保留。
- 动态作者目录已有相同 id 时，运行时发布仍必须真正写世界目录；独立回归证明原实现未落盘，修后重启不再依赖该动态作者目录。
- 独立旧 Demo 镜像 `voxim-gameplay:prefab-d1-20260922`，image id `sha256:9fd3403f11866c9ccb094cad3f9db95907c36fe511759c28fd18e92022d38c45`。
  使用同一次正常 Linux Mix 构建，保留旧 worldgen `.so` 与世界版本；切换前后出生点、建筑探测和余额一致。共享森林 Demo 未动。
- 真实 NPC `Player.tool_context` 发布草稿，`Body.prefab_place` 放置（txn 423356）、`Body.prefab_remove` 拆回（txn 423358）。
  宏格 placed_by 为该 NPC，micro 子节点实际 1 格；不补料，拆回后世界探测和库存恢复。
- 真实双客户端 `smoke.py --mode assembly` exit 0：txn 423493 / 423505 / 423515，每端逐笔完整匹配 4 个叶子状态，余额与垫台恢复。
  实际查看放置截图；D1 没有新增客户端 UI 或预览格式。

复现命令（各 app 独立 VM，数据库端口 5433）：

```powershell
# ex_mmo_cluster/apps/voxel_region
$env:MMO_DB_PORT='5433'
mix.bat test --no-start test/prefab_draft_test.exs test/prefab_runtime_publish_test.exs --exclude benchmark
mix.bat test --no-start test/prefab_runtime_publish_test.exs --only benchmark
# ex_mmo_cluster/apps/scene_server
mix.bat test --no-start test/scene_server/movement/path_test.exs test/scene_server/prefab_designer/check_test.exs test/scene_server/prefab_designer_test.exs
# Voxim
python Saved/Gameplay/prefab-designer-20260922/d1_demo.py
python Docs/Gameplay/smoke.py --mode assembly --server-dir Saved/Gameplay/prefab-designer-20260922/isolated-server --container voxim-prefab-designer-test --out Saved/Gameplay/prefab-designer-20260922/d1-assembly
```

所有运行日志、源文件哈希清单及原始失败位于上述本轮 evidence 目录；`d1-demo-*.json` 只读证据与 `d1-assembly/acceptance.json` 绑定实际角色、事务与世界余额。
