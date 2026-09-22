# Prefab Designer D2：设计会话验收记录

分类：全局系统功能；用例、模型请求记录和场景为 Test-only。状态：会话已实现并实跑，完整目标验收未完成；不能视为三项目标全部通过。

`Skills.Design` 在通用大脑之外的 worker 中保留一次会话的完整 Responses 历史，调用 D1 的 edit/view/check/publish；编辑后必须重新检查，结束返回发布定义和计量。build 仍走 Body.prefab_place。源码与独立 Demo 的证据目录为 `../Voxim/Saved/Gameplay/prefab-designer-20260922/`。

工地输入来自 World 的锚点两层、16×16 的 512 格有限快照，包含余额、seq 和材质事实；未采样的附件、上层和窗口外明确为未知，不猜地面。非均匀层以固定列的 `[x,z,material,placed_by]` 保留普通占用，refined 保留完整记录；只有已知窗口内未列的位置表示无归属的普通空气。初始输入明确草稿为空。完整 D1 检查结果留在技能结果中；模型用的悬空诊断只给数量、包围盒与标注过的少量样本，不重复整份 observed。

模型固定 gpt-5.6-terra / high。每个会话最多 12 轮、单次 max_output_tokens=4096；token 按返回 usage 的 input+output 累计，包含重复历史和缓存输入。超过累计预算的那次响应不执行工具。这是响应后的执行边界，不是请求发出前的费用硬封顶。

现有通用 Llm profile 加入以下技能配置即可调用；endpoint、scheduler、英文 activities、continue_activity 与持久化 memory 沿用 D4。`labels` 由调用方提供 `定义十六进制 id => 部件说明`，不在产品模块写死目录样本。

```elixir
skills: %{
  design: %{labels: labels, budget: %{rounds: 12, tokens: 120_000, max_output_tokens: 4096}},
  build: %{}
}
```

`design(goal, anchor_micro, orientation)` 返回已发布定义、完整检查及 metrics；`build(definition, anchor_micro, orientation)` 经 Body 正式放置。发布不扣材料，放置由 World 结算。既有原子动词和 remember/recall 继续可用。

## 实测

- 小屋 attempt1：5 请求、54,082 tokens（50,938 输入、3,144 输出），1 次检查未通过；第 4 轮已检查通过，第 5 轮 publish 因超过初始 48,000 预算未执行。失败日志 `d2-live-cottage-attempt1.log`。据每轮实际 7–13k token，把后续测试会话预算设为 120,000，检查条件不变。
- 小屋 attempt2：6 请求、62,552 tokens（59,455 输入、3,097 输出）、2 次检查未通过，1 passed / exit 0。定义 `de3d1089afbde0dbed382879957c3eb9a47733cfc677c5e1076ce27ec1691d33`；202 宏格、1,040 micro、4 节点、64×40×64 micro 包围盒。正式发布和付费放置后，逐格 World payload、三个目录组件、实际支撑与余额独立核对。模型将声明房间缩到不含楼梯的区域；这里只证明该区域和门口路线，不把它称为整屋每格净空。证据 `d2-live-cottage-1790016327088-389/verified.json`。
- 地板／天花板 attempt1：9 请求、145,219 tokens，超过 120,000，未发布。悬空诊断重复列出 202 宏格和 1,040 micro，单份工具输出约 16k tokens。用手算 9 格悬空屋顶红→绿回归修正模型投影；未删检查条件。
- 地板／天花板 attempt2：压缩后每份检查约 923 tokens；9 请求、123,496 tokens、5 次检查未通过，仍未发布。离线重放确认，所选起点中心或角色半径与楼梯／门柱相交；最后一次编辑还把门框移入室内，造成 8 列净空与屋顶检查失败。同一原始几何从真正屋外可通。
- 起终点诊断现复用 Path 的站立／下落规则，报告半径覆盖下的首个身体阻挡和支撑。冻结第 9 请求的单次 A/B 仅替换最近检查输出；B 用 18,451 tokens 恢复门框，消除了那 8 列阻挡，但起点仍无效，不算完整目标通过。原 A 提议的编辑会与楼梯重叠；两者均离线执行检查，未发布。
- 新增封闭盒反例：原检查允许把 entry 和 inside 都放在封闭盒内。现在 entry 必须在完整几何（含目录子件）的世界 XZ 包围盒外，发布条件增加对应一项。包围盒经 `Prefab.bounds/3` 复用既有变换；保留非零锚点与旋转的独立期望。相关 Design、Check、Facade、Path 共 50 passed / 1 live excluded。
- 地板／天花板 attempt3：新诊断下首次请求 60 秒 HTTP 超时，1 请求、0 完成轮次，usage 未知；没有执行工具。日志 `d2-live-floor-ceiling-attempt3.log`。
- 两层屋 attempt1：第 1 请求查看空草稿，7,336 tokens；第 2 请求 60 秒 HTTP 超时。2 请求、1 完成轮次、0 次检查，usage 不完整；没有编辑、发布或放置。日志 `d2-live-two-storey-attempt1.log`。两次超时均保留失败，未以延长正式时限或自动重试掩盖。
- 随后仅重放两层屋原第 2 请求一次：请求内容不变、同 `:httpc` 与 TLS 校验，Test-only 等待上限改为 180 秒，180.009 秒仍超时，无 HTTP 状态、response 或 usage，未执行工具。`d2-timeout-measurement-1790018155784/measurement.json`；测量脚本 exit 0 只表示记录完成。正式时限未改，停止继续付费重跑。无凭据 HEAD 另在 971 ms 得到 HTTP 404，证明地址可达，不能证明模型推理服务健康。

上述本机 live 用例直接调用正式 Skills→Design、真实 World/Scene 发布和放置；没有父脑 Jev 请求，因此不能拿其 0 次 Jev 代表 Demo 的通用大脑调度成本。独立 Demo 的自然场地与父脑 design→build 链、两层屋、通用目标和采集验收尚未完成。

## 9月22日继续实跑与预览修复

用户要求保留端点和模型配置。随后一次64输出token上限的连通性请求在2.450秒返回（4,397 tokens），不执行工具，不算目标验收；正式超时仍为60秒。

- 地板／天花板 attempt4：4请求、42,678 tokens（39,668输入、3,010输出）、0次检查失败，68.9秒，1 passed / exit 0。定义 `203423d60a42de07e420dba025ff205cfe88f7289c7d7c36885dbc1d1c2ba8e7`，122宏格、1,040 micro、4节点。真实World发布、放置、全部几何与余额通过；独立造价石料153,616,384、木料106,496,000单位。证据 `d2-live-floor_ceiling-1790031554246-4/verified.json`。
- 两层屋 attempt2：11请求、133,153 tokens（127,040输入、6,113输出），超过预算的第11轮未执行，0次检查。四次view只返回 `overlapping_definition`。离线仅应用第1/3/5/7/9轮编辑，确认第6/8/10轮冲突始终是根楼板与门框上部的宏格 `{3,3,1}`、`{4,3,1}`；移除楼梯和窗户并未消除冲突。证据 `d2-live-two_storey-1790031652331-6275/offline-geometry/`。

复用Prefab发布的同一几何展开与冲突判据，增加有界 `preview`：保持字节、引用、对齐和容量拒绝；几何重叠时返回草稿和冲突，正式compile/publish仍拒绝。view不再以发布成功为前提，返回冲突数量、包围盒、最多4个坐标样本及部件槽位。完整冲突留在Prefab API。初始输入的24个朝向基向量来自既有 `Prefab.point`。

新增 `slice(target,axis,at)` 读取草稿或目录定义的真实micro切面，每字符一格，保留门洞和楼梯形状；轴0/1/2分别固定X/Y/Z，立面Y从高向低。复用Prefab footprint，预览不能批准发布。手算三级楼梯、负坐标宏格与micro接缝作为期望。

改前失败日志 `d2-invalid-draft-view-red.log`、`d2-micro-slice-red.log`；改后Gate Design 12 passed、Scene Check 9 passed、Prefab preview/runtime publish/既有定义32 passed，各app正常 `mix.bat test --no-start`，World使用 `MMO_DB_PORT=5433`。`d2-preview-slice-green.log` 中跨app路径写错，实际只选中Gate的12项，不能计为Scene通过；Scene另以正确入口运行，日志 `d2-micro-slice-green.log`。

冻结两层屋原第7请求的单次A/B只替换最后view输出，提示词、工具和此前历史不变。B用14,911 tokens（13,777输入、1,134输出），仍以整片墙覆盖部件，导致10个macro/micro冲突，**没有修复**；0世界写入，不算目标通过。证据 `d2-preview-ab-1790038732902/verification-B.json`。完整新接口另行实跑，不拿此对照宣称模型已学会修复。

两层屋 attempt3使用完整新接口：先切面查看楼梯、门框，再编辑和查看，草稿可发布且无重叠；但两次检查仍有入口身体碰撞和楼梯区被声明为房间导致的净空/屋顶失败。9请求、136,917 tokens（127,180输入、9,737输出），199.7秒；第9响应预算拒绝，未执行、未发布或放置。证据 `d2-live-two_storey-1790038786392-11266/`，不视为目标通过。

预览增量以正式构建部署到独立Demo：`voxim-gameplay:prefab-d2-preview-20260922`，image `2957f86608f2b3f2bb359dd623a98a7c529f6e2d371fe679e4584a08e7228be8`。首次双客户端因原测试CA及服务端证书在2026-09-21 21:24 UTC过期而在TLS阶段失败（app298），未提交玩法意图。只对独立副本用现有 `Docs/M1/tools/certificates.ps1` 续发并重启，TLS验证保持开启。第二次 `smoke.py --mode assembly` 双方success、exit0；事务472371/472383/472392，每端4个完整叶子状态、材料恢复，已检查placed.png。证据 `d2-preview-assembly-renewed/acceptance.json`；原失败保留在 `d2-preview-assembly/`。

## 当前 Demo 的玩家回归

独立旧 Demo 镜像 `voxim-gameplay:prefab-d2-20260922`（image `7065c8deba922d4a34d2d6f2973e7303dede6046be3649f177824ef2d116579a`）由正式构建图生成；升级保留原 worldgen、世界版本、协议 16、余额及保护点。共享森林 Demo 未改。

`python Docs/Gameplay/smoke.py --mode assembly --server-dir Saved/Gameplay/prefab-designer-20260922/isolated-server --container voxim-prefab-designer-test --out Saved/Gameplay/prefab-designer-20260922/d2-assembly`：exit 0，双方 success；txn 431922 / 431934 / 431943，每端完整匹配 4 个叶子状态，材料恢复。已查看 `placed.png`。这只证明当前构建的玩家 assembly 链，不代表设计目标验收通过。

随后仅完善 Design 的模型输入：天然站点实测 site 从 41,100 降到 7,490 bytes，initial content 从 58,832 降到 25,281 bytes。手排混合自然格、付费宏格、refined 格和空气，512 格独立还原一致；空草稿字段改前 nil、改后零统计。最终 Design+Check 19 passed / 1 live excluded，Llm+Skills+Design 30 passed，均 exit 0，见 `d2-site-initial-final-green.log` 和 `d2-final-gate.log`。

当前独立 Demo 已更新为 `voxim-gameplay:prefab-d2-site-20260922`（image `e20254af6d080ebbc6a0738cbba7808470f229bf48db5a78ed820713681c4da1`），正常构建且源码清单一致，切换前后余额与保护点一致。在该实际镜像调用 Design、用记录请求的替身截住 HTTP，得到上述压缩结果并从 512 格全部还原原始观测；0 次实际模型请求、0 次世界写入，证据 `d2-natural-runtime-verified.json`。这证明部署的真实观测入口，不冒充模型会话通过；玩家 assembly 的实跑版本明确为前一段镜像，之后修改未涉及玩家路径。

## 继续验收的入口

数据库端口 5433；在 `ex_mmo_cluster/apps/gate_server` 运行：

```powershell
$env:MMO_DB_PORT='5433'
mix.bat test --no-start test/gate_server/npc_brain_llm_test.exs test/gate_server/npc_skills_test.exs test/gate_server/npc_skill_design_test.exs
# 模型端点恢复后，每次只选一个目标，保留完整输出；不要无诊断循环重跑。
$env:DESIGN_LIVE_CASE='floor_ceiling' # 或 two_storey / cottage
mix.bat test --no-start test/gate_server/npc_skill_design_live_test.exs --include live_llm
```

独立 Demo 的 Test-only `d2_demo.py`、`d2_demo_start.exs`、`d2_demo_verify.exs` 已准备并通过静态语法检查，尚未启动付费会话。安全天然场地 x90..97、z102..109、地表 Y508；NPC 新角色不复用旧施工者。固定一次供给，放置前按完整定义 bounds 限制在已核对的场地；通过标准是实际 Body 放置事务、World 全部宏格/细化格/归属、半径与高度覆盖的整条入口路径和独立材料守恒。场景限制只属于 Test-only，不加产品权限。

待完成：地板／天花板和两层屋、自然场地通用脑 design→build、三个无关单句目标，最后才做采集。第 6 步优先复用既有原子动词：水 material21、工具11/12（每笔524288单位）搬运独立夹具双坑；真实客户端 `@walk` 走停转弯，Scene 权威位置逐段验跟随；附件贴上/inspect/按身份拆回。不得重写当前 Demo 水池来制造前提。跟随时长 wait 不会被实体移动直接唤醒，这是现有行为，应实测而非先造 follow 框架。以上未运行，不计通过。
