# VXPD v3 增量验收

分类：全局系统功能；以下夹具、脚本与独立 Demo 为 Test-only。2026-09-22。

已实现、已实跑、已按本增量范围验收：宏格与 micro 共用节点身份；发布对齐与占用校验；宏格普通地形事务、LOD、碰撞、数量及热状态；按单宏格损伤／拆卸；整树造价与退料；宏格归属、实例放置者和 placed_by 持久化。v1/v2 可读，旧日志缺少新元数据时不补造放置者，不迁移旧实例。

Hello 保持 16，线上消息／VXR4 格式不变，content_version 不变。macro_owners 差量及完整 prefab_instances 随现有 kind 3 ETF 元数据写日志，数据库重启与压实均实测。客户端从既有属性流取得宏格 owner，保持宏格粒度；父级轮廓组合窗口内实际宏格和 micro。实例元数据须等几何及完整属性窗口汇合后裁剪，不能只按 refined 槽位判断空壳。自制定义下载、VXPD v3 客户端解析与预览仍属 D3。

新增回归保留改前失败：v3 定义 7 项；World 初始 5 项；混合节点 micro 拆／攻击 2 项；相变 5 项；最后子节点替换导致祖先丢失；宏格拆卸漏退附件。期望包括每宏格 512 micro 单位、碰撞占用 512+512+1=1025、100−(30−2)×n 的单格 HP，以及相变的独立数量／焓／完整度计算。

全套另复现了原有缺陷：花草支撑预读未烘焙区域时崩溃，现按既有入口返回 missing_region，原有两条测试先失败后通过。三个历史协议测试显式对齐已采用的 Hello 16 并拒绝 15；没有改变产品协议。

## 执行结果

原始日志根目录：`Voxim/Saved/Gameplay/prefab-designer-20260922/`。本机命令使用 `mix.bat`；数据库 `MMO_DB_PORT=5433`。

- `apps/voxel_region`：`mix.bat test --no-start`，334 passed、4 excluded，`v3-voxel-all-green.log`。先前 332/334 的原始失败保留在 `v3-voxel-all.log`。
- `apps/mmo_contracts`：同命令，114 passed，`v3-contracts-green.log`。
- Gate 的 voxim_production_dispatch、voxim_auth_boundary、session_codec_owner、codec_dispatch、npc_body、npc_body_world 六文件：39 passed、7 excluded，`v3-gate-current.log`；未调用真实模型。
- Scene 的 voxim_instrumentation、voxim_collision_timeline 两文件：12 passed，`v3-scene-current.log`。IS/E1_FIXTURE 使用既有 S1/world-fixture，PROFILE 为 M0/fixtures/suite.json；E1 新世界 manifest 使用现有生成参数、不带历史 content_version。
- Linux 正常 Mix 构建的 quic_connection_test：45 passed，`v3-quic-green.log`。首次与独立 Demo 的 25443 端口冲突，失败保留 `v3-quic.log`；停止独立测试容器后测试，通过后恢复容器。
- 客户端正常构建及 12 项选定 Automation 通过，`macro-selection-green-results.md`；涵盖宏格损伤、归属窗口、metadata join、原 hierarchy 和 region afterimage。判定器 4 项反例测试通过。

额外广域尝试 `v3-player-boundaries.log` **不算全套通过**：跨 app 的 `--no-start` 运行导致缺夹具变量及 Scene 结束后测试库被删、Gate 继续使用旧连接。纠正为上述独立 VM 后当前玩家路径通过。广域 Scene 还发现旧 surface-element 监督树及旧生成器／profile 金样失败，本增量未改这些旧模块或接受新金样。

## 独立旧 Demo

容器 `voxim-prefab-designer-test`，目录 `Saved/Gameplay/prefab-designer-20260922/isolated-server`，独立数据库 `voxim_prefab_designer_20260922`，HTTP 25440／QUIC 25443。镜像 `voxim-gameplay:prefab-v3-20260922`；保留旧场景生成器作为夹具依赖，World 内容身份不变。原容器 `voxim-prefab-designer-test-before-v3`、切换前目录与数据库备份均保留。共享森林 Demo 与公网均未在本增量切换。

```powershell
python Docs/Gameplay/macro_smoke.py --server-dir Saved/Gameplay/prefab-designer-20260922/isolated-server --container voxim-prefab-designer-test --out <新目录>
python Docs/Gameplay/smoke.py --mode assembly --server-dir Saved/Gameplay/prefab-designer-20260922/isolated-server --container voxim-prefab-designer-test --out <新目录>
```

新场景 `v3-macro-assembly-final` 退出 0：有限作者样本经 World 正式作者入口一次安装，出生点和原样本避开；之后全用真实准星／按键。实例 419257，攻击／宏格 F／micro F 为 419367、419372、419382。两端逐笔同一身份、78 HP 和删除墓碑一致；退回石材 1m³、木材 160/512m³，B 余额不变，World 占用恢复、根实例退休。父轮廓实际从 672 缩到 160 个 micro 体积单位，截图已查看。整体 prefab_remove 由真实 World 用例覆盖，Gameplay 没有整栋删除按键，未以 F 冒充整栋删除。

旧场景 `v3-legacy-assembly` 退出 0：419162 放置、419174 替换、419183 拆卸，两端四条叶子状态一致，双方余额和18个采样格恢复。

首轮新场景判定器误要求只改 HP 的事务呈现网格；既有 IntentLedger 对无网格更新的完成状态为 not_visible。失败保留在 `v3-macro-assembly-run.log`，显式修正该条期望，双方 HP／退料／删除断言保留，最终新运行退出0。图像渲染、玩家编辑器、D1 发布与 D2 模型会话尚未实现；这里的渲染验收仅指放下后的既有宏格／micro 呈现与选择。
