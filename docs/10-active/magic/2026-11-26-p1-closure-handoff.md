# 魔法 v2 P1 收口：统筹会话交接（2026-11-26 17:20 PST）

> 用途：上一个统筹会话因为上下文过长而换新会话，本页给接手的统筹会话用。阶段事实以决策稿
> [`2026-11-26-p1-closure-slices4-8.md`](2026-11-26-p1-closure-slices4-8.md)（下称“决策稿”）§14 为准，本页只记交接时的现场与待办。
> 开工前先读工作树 `AGENTS.md`，测试规则以 `D:\hemifuture\Voxim\Docs\Testing.md` 为准。

## 1. 用户目标

用户要求：对接客户端，把魔法设计 v2 的改动统一，前后端一致，全部落地，达到能发版的程度。发版门槛是设计
（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` v2.11）§12.2 切片 1 的验收第 1–8 条，也就是本分支切片 8 的验收。
在 P1 闭环之后，服务端与 Voxim 同版本合入主分支（Hello 46）。**推送与发版必须先得到用户确认。**

## 2. 仓库与工作树

| 端 | 工作树 | 分支 | 交接时 HEAD | 说明 |
|---|---|---|---|---|
| 服务端 | `D:\hemifuture\ex_mmo_cluster-magic-v2-p1` | `magic-v2-p1` | `d3a95e89` | 已在 master `62d9a5a5` 之上；master 之后没有新提交 |
| 客户端 | `D:\hemifuture\Voxim-magic-v2` | `magic-v2-online` | `20414ae8` | 已变基到 Voxim main `f28b972f`；备份分支 `magic-v2-online-prerebase-3b9f9632` |
| 服务端 master | `D:\hemifuture\ex_mmo_cluster` | `master` | `62d9a5a5` | 本地领先 origin 约 83 个提交，未推送 |

- 客户端工作树里 `Plugins/VoximMovement/.../voxim_movement.h` 的换行改动是开工前就有的，**不要提交**。
- 不要碰 `D:\hemifuture\Voxim` 主工作树：那里有用户未提交的改动。
- **master 主工作树 `D:\hemifuture\ex_mmo_cluster` 里有别的会话留下的未提交改动**（约 04:26 最后修改）：灵炁场 `anima_field.ex`、
  `docs/10-active/magic/2026-11-26-anima-field-design.md`、`magic/{catalog,cost,program}.ex`、`world.ex`、`casting.ex` 等，
  另有用户的天气与时钟设计稿（未跟踪）。这些不属于本任务，不要动。但它们改的是魔法与 World 文件，
  魔法分支合入 master 时会冲突，合入前要先问用户这批改动归谁、怎么处理。
  （2026-11-26 用户答复：灵炁场归另外的会话，本任务不管。合入时若这批未提交改动挡住合并，停下来告诉用户，不动它们。）
- 已废弃的分支 `magic-v2-p1-throttle`（4b，已合入）、工作树 `D:\hemifuture\ex_mmo_cluster-magic-v2-throttle`，可在合入后清理。

## 3. 交接时仍在后台跑的子代理（由旧会话启动，结果不会通知新会话）

用 git 状态判断它们是否完成。若新会话开始后 30 分钟仍无新提交、文件也不再变化，就视为中断，按下面的说明另开代理接着做。

> 接手会话核对（2026-11-26 18:05）：两项都已完成并提交，均未推送。服务端 `c384c130`（记录见决策稿 §14 末条），
> 客户端 `ca1c5c7e`（`Voxim.Presentation.+Voxim.Magic.` 53/53）。

1. **服务端：结构邻居查找 O(N²) → 网格分桶**（服务端工作树，未提交：`world/structures.ex`、新 `test/magic_structure_neighbors_test.exs`）。
   要求结果与旧实现逐位相同（golden 字节不变）。只跑等价性测试、`magic_structure_world_test`、`magic_structure_wire_samples_test`
   和修复后的负载测试一轮（`--only load`），**不跑 voxel_region 全量**。完成后应在决策稿 §14 追加记录并提交。
2. **客户端：5 个缺失特效挂占位资产**（客户端工作树，未提交：`Docs/Magic/author_presentation.py`、`VoxelPresentationCatalogTests.cpp`）。
   涉及的键：`structure.end.{exhausted,collapsed,released,dispelled}`、`structure.overline`。用现有 Niagara 资产，四种终止要能互相区分，
   经作者脚本重新发布，作者脚本里标“占位，待美术替换”。只跑 `Voxim.Presentation.+Voxim.Magic.`。

## 4. 进度总览

- 已完成且两端闭合：切片 3（协议 Hello 46、IR v2）、4（结构运行时、热内核限流、结构记录 v2）、5/5b（飞行无射程终点、〈遇〉、命中伤害、
  法杖无质量光弹〈蓄〉1742 J）、6（驱散脉冲、前摇打断、取消结账；持物普攻免除移动打断）、7（准入 `World.MagicAdmission`、
  目录 `22c459f0…`，`flights_per_caster` 改为 3）。
- 客户端（`magic-v2-online`）：已覆盖全部上述内容。已修复正式关卡目录（`DA_MagicCatalogV5` 接入 10 个关卡，v1 资产已删）；
  “我的法术”迁移对话框；验收脚本改为 v2；验收清单 `Docs/Magic/Slice8-acceptance-checklist.md`。最近一次 Automation 173/173。
- 切片 8a 负载实测（已提交，三档 `--only load` 均为判定失败，没有改成通过）：热内核余量充足；**结构步进超预算**
  （主因是邻居 O(N²)，见 §3-1）；**持久化超出 16 KB/拍**，正确修法是 S1a A2 `stream_row`。S1a 尚未开始，
  统筹建议这一版先发，**尚待用户拍板**。

## 5. 待办（按顺序）

1. 收第 3 节两个子代理的结果并核对（看提交、测试日志）。
2. 把第 6 节的测试分级方案写进决策稿 §13，作为本分支剩余工作的测试规则。
3. 决策稿里约 25 条工程类“待设计确认”改写为“实现决策 + 理由”，去掉标记。分类见第 7 节。
   把已定的设计改动回写到 TheWorldBook 设计稿（另一个仓库，单独提交）。
4. 修测试隔离：scene_server `P0BodyLifecycleTest` 每次运行都复用同一批角色 id，会被测试库残留行打红（违反 Testing.md §3）；
   npc_server `NpcSpeakTest` 有计时偶发失败。
5. 切片 8b 双客户端实跑验收（Testing.md §2.3）：先拿世界副本干跑驱动，判定器先过含反例的单测，实跑按阶段门控、首个失败即停。
   每个短场景约 10 分钟内跑完，双端整场保持同一会话在线。实跑中请用户看手感项（第 7 节）、
   整串字形与碎裂效果、5 个占位特效，以及“按住普攻被受伤或驱散打断后继续连发”是否可接受。
   清单里有两条偏离设计：第 2 条改用热墙灼点、第 3 条改用取消到第 k 步；第 3 条先试把储能耗低来触发真正的中途失败。
   UDP 看护按全局 CLAUDE.md 的放宽规则：开始和结束各记一次端点数。
6. 合入准备：CI 的 `.github/actions/voxim-fixtures/action.yml` 固定的客户端提交号改为客户端发布提交；
   确认 master 上的 `npc_brain_llm_test` 修复（分支 `a15238ab`）随合入带过去；L3 合入门禁跑一次；
   处理第 2 节 master 工作树的灵炁场改动；生产 NPC 登记行若有 v1 `spells`，需要一次性迁移（N1/R4，合入前查）。
7. 合入与发版（推送、镜像、分发）——**每一步都先问用户**。

### 5.1 接手会话追加的待办与已定事项（2026-11-26）

- 已完成：§5 第 1–4 步（`c384c130`、`ca1c5c7e`、`bc1043a9`、`8f4c9011`、`094ce125`）；TheWorldBook v2.10–v2.12（`01fe762`、`b2f0904`、`705f225`）；
  性能例外已接纳并留档（`a3e4ada5`，`known_gaps.md`）。
- 发版前补上（用户已定），都改 `world/structures.ex`，必须串行：
  1. **#16 静止结构首次导热边置接触**：接触开始即唤醒（只针对带〈遇〉且未触发过的结构）、出生时就有的边也算、落地/命中与首次导热边两次都算。**已完成 `d3f68f10`。**
  2. **#7 板的轴向**：服务端 `half/1` 板改为 `{size1, size3, size2}`，与客户端 `HalfExtentsM` 和设计 §11.4.2 一致；局部系 P1 取世界轴。**已完成 `8b57e0ff`。**
  3. **#6 终止释放剂量**：改为下一热拍生效（全部终止释放进同一个待生效队列，随 `thermal` 持久化，下一热拍按拍首位置作用于 3 m 内全部运行中结构，连锁每拍一跳），投射物提交点的释放进同一队列；释放剂量也过 `Harm`，与驱散场一致。统筹定：收件人只限释放时已存在的结构、距离按生效拍拍首位置、#19 维持只改理由、冻结交付中的结构不受剂量。**已完成 `5ba972db`**（设计回写 TheWorldBook `3b1742c`）。
- `DataService.UidGenerator` 改标准雪花算法（用户定随这版发）：**已完成 `b81ff28f`**，决策稿 §14 有记录。
- dev 自动登录 cid 改字符串（两端，与正式票据 `ReadTicket` 同一约定；新 id 超过 2^53，不修会挡住 8b）：**已完成**，服务端 `dc41e8ef`、客户端 `c630c081`。`Voxim.M1.Transport.*` 要连真实 gate，只编译未跑，随 8b 实跑验证。
- 合入准备已查：`a15238ab` 已在分支历史里；CI `voxim-fixtures` 固定的客户端提交 `4a016fc1…` 须改成已推送的客户端发布提交（推送前问用户）；生产库 `npc_specs.params` 的 v1 `spells` 未查（生产操作，合入前问用户）。
- 下一步：第 5 步切片 8b。判定器反例单测 154 个已通过（客户端 `c630c081`）。
- 切片 8b 实跑进度（2026-11-26 晚，服务端第 1 次启动 `runs/live-01`，原始失败目录都保留在客户端 `Saved/Tests/magic8b-20261126/live/`）：
  - `magic_interrupt-01` 通过（A 碰巧在前台）；用户确认 #29 取消扣费保持。画面（字形、碎裂）截图未拍到，未验收。
  - `magic_dispel-01` 失败：驱动瞄点贴棱且旧镜头模型 → 客户端 `351ab0da` 修。`-02` 未开始：统筹停外层脚本时误杀驱动的 UDP 快照子进程（环境故障）。
    `-03` 失败：A 不在前台，按住 M 被客户端失焦取消（`VoxelInteractionComponent.cpp:80/399`，正确的产品行为）→ 客户端 `f720d2be`：A 置前一次 + 每次 M 后 `@await_cast` 快速失败。
    用户定：实跑期间不碰桌面，统筹实跑中不提问。
  - `magic_dispel-04` 失败：三盏灯建成、账目通过；但 ① 前摇中客户端每 50–66 ms 发同一 client_seq 的方向控制消息，尾部一条晚于结算 → `:already_released` 告警（`clean` 判失败）；
    ② 〈附〉脉冲在 M 松开那一帧目标与方向同时跳到相邻格，开始校验通过，出手时服务端按最新方向复核 → `:stale_target`。
    **查清（2026-11-27）**：② 是产品缺陷。松开 M 时相机从越肩缓回常态只平移不转向，屏幕中心射线横移约一个肩部偏移，
    准星在鼠标不动时跳到相邻格；前摇方向更新取“眼睛→当前准星格”跟着漂，服务端出手复核命中相邻格。不带目标的投掷同样被带偏。
    ① 是网络时序的正常结果：出手由服务端定，最后一条方向更新必然可能晚到，施放本身成功、扣费正确，只是客户端把回执当成告警。
    **修法（用户定：切换视角时准星始终瞄同一个点，平移与转向是同一个过渡变换）**，客户端 `5fcd4b79`（过渡中控制旋转随相机同步
    转动，准星落点不动；无命中时不转）、`45c284ac`（晚到方向更新的 `:already_released` 按 Log 记）；相关过滤器 81/81，两个新回归
    改前按预期失败。跟进 `8d7e0bb2`：战斗辅助瞄准的前摇方向（`RotateStartingAim`）扣掉过渡补偿的转动，只跟随玩家转动
    （82/82，新回归改前失败）。残余：`CameraRay` 读相机管理器上一帧的视图、累计值是本帧的，过渡进行中的帧多扣一步，
    本测试几何下最大约 0.37°，过渡结束归零；接受，不再处理。三处都未实跑。
    实跑时请用户看：近处（约 2 m）的墙前进出越肩，过渡要转约 17°，手感是否可接受。服务端不改。
  - 录屏：两窗口并排 1920×800 区域，脚本见统筹 scratchpad `run_mode.sh`（ffmpeg 须 `-nostdin`，按本次进程号停止）。
    脚本录屏上限 25 min；presets 充能约 25 min，须在客户端启动前另起一段录屏（`magic_presets-01.rec2.mkv`）。
- 切片 8b 第二轮实跑（2026-11-27 05:06–06:22，服务端 `runs/live-02`、`live-03`，release `d4d678f6`；UDP 开始 84、结束 84）：
  - `magic_dispel-05` **通过 8/8**：剂量与手算一致，正中熄灭、1.52 m 变暗存活、账目闭合；无 `stale_target`，晚到方向更新回执 1 次按 Log 记。
  - `magic_overline-01`：环境故障。`native_lifecycle.py` 读写 drvfs 部署目录得一次 `[Errno 61] ENODATA` 即停服（1151 s）。
    已改为 drvfs 的 OSError 只跳过本拍、连续 30 拍才判失败（原文件备份 `native_lifecycle.py.orig-20261127`），live-03 全程 0 次。
  - `magic_overline-02`：准备阶段失败，热面 900 s 后只有 304.2 K。只读调查结论：Test-only 驱动按孤立格绝热算能量，
    实际热格与 4 个石邻格导热、2 面散热，耗尽时峰值约 460 K；判据又要求“耗尽且在 480–520 K”，耗尽后只降不升。产品无缺陷；
    W4-7 能过是停机时直接写 500 K。建议修法：驱动分段保温（每 5 s 补 50 kW×5 s 有限热源、逐段记账、灼点首拍后停），
    热格避开出生点 (67,418,-518) 正下方；偏离清单“一次安装并记账”，**待用户拍板**（2026-11-27 已问，用户要求解释）。
  - `magic_presets-01` 6/8：七个预设建成、扣费、双端生命周期与前摇一致，上行 47 条全是 IR v2。失败两项：
    `server_agrees`：服务端 `voxel_structure_end` 把接触终止写成 `live=2 type=released` → 服务端 `49d0d349` 修
    （`type` 与 `live` 出自同一终止事件，另修热拍静止〈遇〉同类路径；`magic_structure_world_test` 36/36、`magic_staff_bolt_test` 11/11），
    release 已换为 `49d0d349`（旧 `rel.d4d678f6`），`version.json` 已更新；
    `ledger`：判定器取不出负指数 → 客户端 `56f8e25d`（166 个判定器单测通过），离线复判 `recheck-20261127-ledger.json` 中 `ledger` 通过、
    结构账精确闭合。`server_agrees` 须在 `49d0d349` 服务端上重跑 presets 判定，原失败保留。
  - 用户认可分段保温（2026-11-27）。客户端 `671fcbc2`：`HotSurface` 闭环（每 5 s 读温，上一段放完且 T < 500 K 补 50 kW×5 s，
    进 [490, 510] K 开客户端，会话结束／结构出现／超时即停并等最后一段放完），热格排除出生点 3×3，新增 `hot` 试跑入口，判定器 186 个单测通过。
  - 加热试跑 `hot-trial-01`（服务端 `runs/live-04`，release `49d0d349`，不开客户端）：热格 (67,419,-520)，177 s 进窗，
    保温 600 s 内 490.7–504.2 K，87 段、读数错误 0、收尾已放完。有段的 0.5 s 提交比相邻提交恰多 25 000 J（= 50 kW）。
    `supplied_j` 总增量 934.9 MJ 不等于段和 21.75 MJ：presets-01 的充能热源（`heat.json`，3.6 GJ、1.2 MW、`HEAT_S` 3000 s）
    跨停服重启仍在放热，08:04:06.9 才放完；它的实际速率 1 197 616 W 而非 1.2 MW，整账因此差约 6 MJ，未能精确闭合，逐拍归因为 21.66 MJ（−0.4%）。
    注意：presets 之后紧接 overline 时，presets 的充能源仍会运行约 5 min；本次试跑就是在充能源运行下做的，保温不受影响。
  - 已知：`magic_structure_world_test` 的 `hand_cast/5` 用 `drain/0` 取结果有竞争（§11.3 #6 两条曾偶发失败，未修）；
    `structures.ex` 与该测试在 HEAD 时就不符合 `mix format`，L3 门禁的格式检查会报。
- 残余（#16）：休眠的〈遇〉结构只按休眠判定的粗候选唤醒，细分构件贴上时不唤醒；人物碰到休眠结构约 1 个身体报告间隔加一拍后才触发。

## 6. 测试分级方案（用户要求：严格按 AGENTS §3-14 与 Testing.md，不要动不动就跑全量）

已写入决策稿 §13.1（唯一正文，含逐层文件清单与“简报范围是硬性要求”）。

## 7. 待确认项的分类（用户已同意：工程细节由统筹自己定）

- 统筹自定、写成实现决策：决策稿汇总的第 1–7、10–12、14、16–18、21、22、27–33 条（温度取格、邻居泄漏、限流边界、
  触发名额顺序、越界终止、预计飞行时长 T、负载两档等）。
- 用户已定、只差回写设计：〈取〉从取得的能量付费；`flights_per_caster` = 3。
- 手感类，已按推荐实现，在实跑时请用户看：〈附〉形成距离（8）、命中细节（13、15）、取消扣费（19）、受伤打断定义（20）、
  拥挤时拒绝策略（23、24、26）。

## 8. 环境（WSL 测试）

- 服务端测试只在 WSL 里跑。工作区 `/home/dyz/magic-v2-20261126`（`env.sh`、`sync.sh` 把服务端工作树 rsync 过去，`src/Voxim` 链接到客户端魔法工作树）。
  工具链在 `~/toolchains/hex/usr/local/lib`（OTP 29 / Elixir 1.20.5），asdf 里的版本不对。
- 入口：Git Bash 里执行 `MSYS_NO_PATHCONV=1 wsl.exe bash /home/dyz/magic-v2-20261126/mt.sh <app> [参数/文件…]`，
  只打印 `Result:` 与失败，完整日志在 `~/magic-v2-20261126/logs/`。临时命令先写成脚本文件再 `wsl.exe bash <文件>`：`wsl.exe bash -c` 会被二次展开。
- 测试库：docker 容器 `magic-v2-pg-20261126`（127.0.0.1:55501），本任务所建，验收结束后可删。
  WSL 里 `/home/dyz/voxim-toolchains/...` 和 devsrv 的 beam 进程属于别的会话，不要动。
- 客户端构建：`RUSTUP_TOOLCHAIN=1.98.0 powershell -ExecutionPolicy Bypass -File Docs/M0/tools/build.ps1`；
  Automation：`python Docs/R5/tools/run_tests.py "filter=..."`。
