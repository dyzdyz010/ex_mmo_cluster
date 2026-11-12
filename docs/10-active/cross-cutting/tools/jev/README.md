# Jev（TypeSafe System One）评测 — 只测试

凭据在仓库根目录的 `.env`（见 `.env.example`）；没有 `.env` 的检出（git worktree）读进程环境里的同名变量。与 Jev 的交互一律用英文。

- `jev.py` 最小客户端；`probe.py` 连通性 / 延迟 / 计费口径 / state 上限；
- `build_cases.py` → `cases.json`：70 条冻结情境，期望值按文件头的规则手工标注（数值题的算式写在注释里）；
- `run.py [jev] [llm]` → `results-jev.json` / `results-llm.json` 与汇总。LLM 对照每条一次询问，花额度。

## 2026-09-21 结果（jev-1.13，从国内直连；LLM = gpt-5.6-terra，effort low）

| | Jev | LLM |
|---|---|---|
| 准确率（70 条：调度 24 / 叫醒规划 10 / 护栏 8 / 文档弱项 8 / 难题 20） | 70 / 70 | 70 / 70 |
| 延迟 p50 / 最大 | 0.78 s / 3.5 s | 2.67 s / 8.8 s |
| 每次输入 token | 786（含约 290 的固定开销） | 4870（代理注入约 4k） |
| 每千次决策 | 约 0.033 美元 | 按 token 计约为其 6 倍输入量、单价另高两个数量级 |

- 置信度 ≥ 0.6：98.6 % 自动通过、其中 0 错；≥ 0.85：85.7 % 自动通过、0 错。最低的是二维距离题（0.6）、单位换算题（0.62）。
- 中文对照（同 12 条）：12 / 12，置信度不低于英文。仍按约定只用英文——这 12 条不足以推翻“模型是英文的”。
- 计费：多个问题共用一份 state 只计一次（1 问 320 token，8 问 407 token）；延迟几乎不随问题数增加（0.82 → 0.92 s）。
- state 上限在 1 万到 4 万 token 之间（4 万词返回 400 `max_tokens_exceeded`）；20 次连续请求未遇 429 / 529。
- 文档说它不会计数、不会比数值；本集里“差 1 个单位的大数比较”“缺中间一格的 11 格计数”“220 行无关日志里找一行”都答对了。
  样本小，不把它当成可依赖的能力：能用代码算的仍由代码算，把结论写进 state。

## 2026-11-11 人格 / 状态 / 记忆能否移动 top1（`persona.py`，jev-latest，top1 即最终选择）

4 个情境（吃什么、多项工作先做哪项、散步去哪、战斗打法）各 6 个选项 × 7 个人格（含不写人格的对照）× 3 种当前状态 × 3 种记忆，
每格问 2 次，共 504 次请求全部应答；另跑 `mild`（把四个措辞最重的人格改成温和措辞）、`big5`（6 个人格改成下一节的标准写法，只有 traits 段）与 `card`（big5 再加 personal 自由文本段）各 504 次。
期望值运行前手工写在脚本里：中性情境下各人格可接受的选项（22 条），以及某个状态 / 记忆出现后选中某些选项的人数应增或应减（20 条）。
原始结果 `results-persona[-mild|-big5|-card].json`，`python persona.py report [mild|big5|card]` 离线重出全部表格。

| | 原措辞 | 温和措辞 | 标准卡（big5） | 两段式卡（card） |
|---|---|---|---|---|
| 中性情境人格选择符合手工标注（两次不一致时两次都在标注内才算） | 20 / 22 | 20 / 22 | 18 / 22 | 21 / 22 |
| 中性情境 6 个人格的不同选择数（四个情境） | 4 / 5 / 5 / 5 | 4 / 5 / 4 / 4 | 4 / 5 / 6 / 4 | 4 / 5 / 5 / 4 |
| 状态 / 记忆的方向性检查通过 | 16 / 20 | 18 / 20 | 15 / 20 | 15 / 20 |
| 状态与记忆怎么变都选同一项的（人格, 情境） | 8 / 24 | 4 / 24 | 4 / 24 | 9 / 24 |
| 两次询问 top1 相同的格 | 248 / 252 | 242 / 252 | 240 / 252 | 246 / 252 |
| 置信度中位数；≥ 0.85 的占比 | 0.66；29 % | 0.59；19 % | 0.58；24 % | 0.64；27 % |
| 延迟 p50 / p95 / 最大（3 个并发） | 0.59 / 0.81 / 2.10 s | 0.60 / 0.70 / 1.53 s | 0.58 / 0.72 / 1.31 s | 0.64 / 1.08 / 3.12 s |

- 人格、状态、记忆都以自然语言起作用，并且会合成：爱吃肉的猎人身无分文时改去钓鱼；好斗的人记得上次冒进被偷袭后改成拉开距离射箭；
  温和措辞下重伤且被二打一时 7 个人格全部撤退或呼救。
- 人格措辞越重，越压过状态与记忆：原措辞下“endlessly curious”的人手腕扭伤、通宵未睡仍去探洞，“hates being alone”的人 9 格全选同一项；
  改成温和措辞后固定不变的行由 8 降到 4。没有随措辞消失的：胆大 / 好奇的人在“两天前狼在那条路上袭击过人”的记忆下照去林中遗迹；
  “这人烧过我的房子”没有让更多人转为强攻。
- 置信度低不等于选择不稳：top1 翻转的格置信度都不超过 0.46，但每次都低于 0.5 而 top1 仍然一致的格有 71 / 252（温和 84 / 252）。
  偏好类问题不能沿用调度的 0.85 门槛，否则七到八成会被当成拿不准。
- 范围：单次情境选择。没有测同一角色连续多次选择是否重复、选项数超过 6 个、真实 NPC 观察与 Hindsight 召回文本、运行时接入。
  人格是一句话写成的，标注是单人手工标注。

## 2026-11-11 标准人格写法与强度阶梯（`big5.py`、`traits.py`）

写法取自 Serapio-García 等的人格塑造方法（arXiv 2307.00184 附录 K.1、表 13；Nature Machine Intelligence 2025）：
52 对低 / 高标记形容词，对应大五人格 5 个维度、IPIP-NEO 30 个子维度；每对 9 级，
`extremely / very / （不加）/ a bit 低词`、`neither 低词 nor 高词`、`a bit / （不加）/ very / extremely 高词`。
角色卡分两段：`traits` 是严格的标准框架，形式永不变化（键只能是 52 个高标记形容词，值是 1..9 的整数，由 `big5.render` 一处转成英文，没写的形容词不出现）；
`personal` 是自由英文文本，写偏好、承诺、目标、对重复的态度。`big5.describe(card, personal=True)` 拼成 `<who>. Personality: … Personal: …`。

强度阶梯：不写名字的村民，单个维度的全部形容词取同一级，5 个维度 × 9 级 × 4 个情境 × 2 种状态（中性、与之冲突的状态）× 2 次，
720 次请求全部应答，352 / 360 格两次一致。运行前手写了 14 条“该维度升高时应更常选中的选项”：
12 条没有逆序，其中 10 条两端确实不同。两条逆序都是整维度混了不同子维度造成的：外向性升到 7 级以上去探洞而不是帮人搬木头
（维度里有 adventurous and daring）；神经质 9 级在战斗里强攻（维度里有 angry、impulsive）。

- 中性状态下方向比级数管用：1–4 级几乎总是同一个选择，5 级（neither…nor）是另一个，从 6 级（a bit）起就翻到高分一侧。
  “a bit” 已经足以改变默认选择，所以不想让某个特质起作用就不要写它，不能写成 5 级。
- 级数在有冲突时起作用：外向性要到 8 级才会在手腕扭伤、通宵未睡时仍去帮人；宜人性 6–7 级在战斗里呼救、8–9 级才提出休战，
  重伤时只有 9 级才提；开放性只有 9 级才在夜雾里去林中遗迹。重伤被二打一时，任何维度任何级别都没有选强攻。
- 写卡用子维度（单对形容词），不用整维度：整维度同级会把不相干的倾向绑在一起。
- 标准写法不覆盖偏好、价值与目标：6 张卡里“爱吃肉”“讨厌人多”“想当第一”“说到做到”没有对应词，
  改写后 Lin 只有一半的次数先去修答应别人的篱笆。这些仍需要自由文本。
- `card`（traits + personal）与 `big5`（只有 traits）对比：手工标注符合 21 / 22（big5 18 / 22），Lin 在中性情境 work 里两次都选 finish_fence（big5 一次 finish_fence、一次 repair_roof）；但方向性检查仍是 15 / 20，固定不变的行由 4 增到 9 / 24（work 里 garrick、sella、ode、hask、brenna 全 9 格同选）。
- personal 文本没有改变的：walk 的 fog_night 与 wolves_attacked 方向检查仍 NOT MOVED，combat 的 burned_house toward press_attack 仍 NOT MOVED，work 的 exhausted_hurt away quarry_stone 仍 NOT MOVED。
- card 的重复一致 246 / 252，置信度中位数 0.64（big5 0.58），延迟 p95 1.08 s、最大 3.12 s（big5 0.72 / 1.31 s）。

## 2026-11-11 连续多天的选择会不会轮换（`routine.py`）

吃什么、散步去哪两个每天重复的情境，中性状态，9 个人格（不写人格、6 张标准卡、只写 very predictable / very spontaneous 各一）
× 3 种记忆写法 × 10 天 × 2 条链，链内把前一天的 top1 接进下一天的记忆（窗口 5 天）。1,080 次请求全部应答，`results-routine.json`。

| 记忆写法 | 平均选过几种 | 十天只选一种的链 | 平均最长连续天数 |
|---|---|---|---|
| none：不写历史 | 1.2 | 31 / 36 | 9.1 |
| log：只原样列出前几天做了什么 | 1.1 | 34 / 36 | 9.8 |
| tired：log + 连续满 3 天时代码加一句 “done the same thing N days in a row and I am getting tired of it” | 2.0 | 2 / 36 | 3.4 |

- 原样的历史不会带来轮换，反而把选择固定住：不写历史时在两三个选项间摆动的 Lin、Brenna，写了历史以后十天不变。
  只有 very spontaneous 的散步在历史下换过（一条链第 6 天起换了 5 种，另一条第 10 天才换）。
- 加上代码生成的那一句就够了，而且换去的是各自人格下的第二选择（Lin 面包 → 湖边烤鱼，Garrick 林中遗迹 → 山顶，
  Sella 集市 → 湖边）；懒人 Hask 吃饭仍然十天面包。多数角色只在两个选项间来回，very spontaneous 的一条链用到 5 种。
- tired 是看过 none / log 的结果以后加的，不是事先设计的对照；只测了“满 3 天加一句”这一种写法。
- 这一节量的是“会不会轮换”，问法不对：目标不是强制多样，而是选择对历史有可推论的响应。按响应看，
  历史让稳重的角色更固定本身就是响应；喜欢新鲜感一侧见下一节。

## 2026-11-11 对“连续 N 天做同一件事”的响应（`habit.py`）

同样两个情境，把 6 个选项逐个当作“连续做了 3 / 7 天的那一件”原样写进记忆（不加任何结论），5 个人格，每格 2 次，260 次请求全部应答，
`results-habit.json`。运行前写下的预期：喜欢新鲜感的人格 7 天后不再选那一项；very predictable 比它们更常再选。

| 人格写法 | 3 天后仍选那一项（12 格） | 7 天后 | 自己原本的首选被重复 7 天后，它的概率（吃 / 散步） |
|---|---|---|---|
| 不写人格 | 11 | 11 | 0.60 → 0.94；0.70 → 0.88 |
| 标准词 very predictable | 12 | 12 | 0.83 → 1.00；0.68 → 1.00 |
| 标准词 very spontaneous | 5 | 3 | 0.44 → 0.72；0.58 → 0.27 |
| 标准词 extremely curious, extremely spontaneous | 2 | 2 | 0.79 → 0.80；0.83 → 0.47 |
| 自由文本 “likes novelty and new experiences, and gets bored when things repeat” | 0 | 0 | 0.57 → 0.03；0.82 → 0.02 |

- 响应是有的，方向随人格而定：不写人格与 predictable 把重复读成习惯，连原本不会选的选项也跟着历史走；
  明说喜欢新鲜感的人格 12 格全部换掉，预期成立。
- 只用标准特质词时响应偏弱：两种写法各有 3 格、2 格 7 天后仍选那一项。curious + spontaneous 没换的两格正是它自己的首选
  （没人试过的蘑菇、没人去过的遗迹）——“好奇”把它拉向未知的东西，模型没有推出“去了七天就不新了”。
  对重复的态度属于偏好，标准词表里没有，要写在角色卡的自由文本段。
- 3 天与 7 天几乎没有差别：起作用的是“在重复”，不是重复了多久。
- 上一节 tired 那句代码生成的感受因此不是必需的：角色卡写明了对重复的态度，原样的历史就够；它是角色卡没写时的另一条路。

## 2026-11-12 “建设被破坏”的经历原文要点名建筑（`episode.py`）

薄片一 S1-B 的预演里，愤怒 + 近期经历的快照没有让 Garen 稳定回去修小屋（一次 `gather_stone` 0.02、一次 `build_hut` 0.06）。
推测是经历原文只有坐标与编号。对照：沿用那份快照（`npc_mind_test.exs` 的 `live_jev` 用例，fresh），state 逐字不变，
只换破坏经历这一句；7 种写法各问 4 次，并发 3，28 次请求全部应答，`results-episode.json`，`python episode.py report` 离线重出。
期望运行前写在脚本里：点名建筑的写法应 4 次都选 `build_hut`；A、C、D 只测量。句首的时刻与句尾的
`I feel angry toward this actor; my trust changed.` 各写法相同，下表略去。

| 写法 | 破坏经历 | 期望 | `build_hut` 次数 | 各次 top1（置信度） | `build_hut` 的概率 |
|---|---|---|---|---|---|
| A 现状 | `Actor 21 damaged construction I care about at (25, 518, 37), material 11, in world qinglan-test (transaction 4711).` | 只测量 | 3 / 4 | gather_stone 0.10、build_hut 0.22、0.25、0.09 | 0.30–0.50 |
| B_place 点名 + 地点 | `Brann (actor 21) damaged the small hut I built on the plot by the square.` | build_hut | 4 / 4 | build_hut 0.77、0.74、0.80、0.74 | 0.83–0.87 |
| B_name 点名（发布名） | `Actor 21 damaged the building "small hut" that I built.` | build_hut | 4 / 4 | build_hut 0.77、0.74、0.74、0.77 | 0.83–0.85 |
| B_name_actor 再带人名 | `Brann (actor 21) damaged the building "small hut" that I built.` | build_hut | 4 / 4 | build_hut 0.76、0.74、0.73、0.72 | 0.81–0.84 |
| B_activity 引活动名与判据 | `Actor 21 damaged what I built when I did "build_hut" (Build the small hut on the plot by the square; repair or rebuild it if it has been damaged.).` | build_hut | **2 / 4（落空）** | gather_stone 0.06、build_hut 0.13、gather_stone 0.07、build_hut 0.24 | 0.34–0.49 |
| C 去掉编号、不点名 | `Actor 21 damaged a building that I built.` | 只测量 | 0 / 4 | gather_stone 0.28、0.28、0.31、0.19 | 0.14–0.24 |
| D 点名、留着编号 | `Actor 21 damaged the building "small hut" that I built, at (25, 518, 37), material 11, in world qinglan-test (transaction 4711).` | 只测量 | 4 / 4 | build_hut 0.74、0.73、0.74、0.72 | 0.81–0.83 |

延迟 581–1973 ms（中位约 680 ms）。

- 推测成立，而且起作用的只是“点名建筑”：点名的四种写法 16 / 16、概率 0.81–0.87；编号留不留没有差别（D 对 B_name）；
  去掉编号但不点名反而一次都不选（C）。A 这一轮 3 / 4，但概率只有 0.30–0.50，与预演一样是在摇摆。
- 名字要是一个直接的名词短语。引活动名与判据的写法（B_activity）运行前期望会中，实际 2 / 4：模型没有把
  “做 build_hut 时建的东西”读成“那座小屋”。所以把事件对上活动经历这条路没有采用。
- 人写成 `Actor 21` 还是 `Brann (actor 21)` 没有可测的差别（快照的情绪栏已经写了 `Brann (actor 21)`）。
- 产品采用 D 的写法（`NpcServer.Life.State`）：名字取 World 里该 prefab 定义的发布名，其余原文不动。改后重跑预演
  `npc_mind_test.exs --only live_jev`：none → gather_stone 2 / 2（0.85、0.85），fresh → build_hut 2 / 2（0.77、0.77），
  recalled → build_hut 2 / 2（0.80、0.85）。原始输出 `.demo/observe/npc-slice1-20261112/s1b2/`。
- 范围：一张卡、一个情境、每格 4 次；名字与候选判据用的是同一个叫法（“small hut”）。没有测名字与判据叫法不一致、
  中文名字、多座同名建筑，也没有测 Hindsight 把这句抽成事实以后的召回文本。

## 调度问法的两条实测结论（`fanout.py`，`apps/gate_server/lib/gate_server/npc/jev.ex` 采用的就是结论）

- 一个五选一 `choice`，不拆成四个并行 `noul` + 代码优先级：state 没提到的事，`noul` 停在 0.3 上下（“没有玩家在说话”它没把握），
  35 条调度情境里只有 14 条能自动通过；五选一是 31 / 35，两者自动通过的部分都零错。
- 判据措辞要具体：`continue_building` / `replan` 写得含糊时，最平常的情况（刚放好一格、材料够、没人）置信度只有 0.6 上下；
  改成 “Nothing is wrong: …” / “The world contradicts the blueprint, or the same step failed repeatedly, …” 后是 0.95。
- 不另问“是否出乎计划”：着火也出乎计划，它会把十足把握的 `move_to_safety` 改成先问规划者。
- 同一请求两次的置信度会差 0.1 左右（0.65 / 0.77），阈值附近的情境会时过时不过——升级给规划者是安全的那一侧。
- 验收用例：`mix test test/gate_server/npc_jev_test.exs --include live_jev`，本模块原样问法过 35 条：33 条自动、零错。

## 2026-11-12 小屋被整座拆除后为什么一直守屋（`s1c_diag.py`，S1-D1 离线诊断）

S1-C 实跑：Garen 的小屋被另一角色整座拆除（一次 dismantle，World 一条 `:destroy` 事件），之后它一直选 `guard_hut`。
经历原文只写 `damaged the building "small hut"`，快照也不说小屋还在不在。来源 state 是实跑时 Selector 实际发给 Jev 的全文
（证据目录 `E = .demo/observe/npc-slice1-20261112/s1c`：C2 = `states/asked-20261112T121753Z.txt`，破坏后第一次发问；
C5 = `states/asked-20261112T122643Z.txt`，情绪衰减、记忆写入后）。变体只做行内替换 / 删行，全文在 `E/diag/<变体>.txt`，
逐行改动在 `E/diag/edits.txt`。请求体同 `NpcServer.Selector.body/2`（instructions 逐字、五个候选按 params 求值后的判据与次序）。
期望由统筹会话运行前写定，抄在脚本文档字符串里。“重建方向”= top1 ∈ {build_hut, gather_stone}；“成立”= 4 次里至少 3 次。
每个变体 4 次，并发 3；先跑 b_original / c_original 做复现检查（通过），再跑其余 9 个，共 44 次请求全部应答，延迟 575–2052 ms。
复跑：`python -B s1c_diag.py prepare`（只写 `E/diag/`）、`run [变体 ...]`（只问结果文件里还没有应答的变体）、`report`（离线）。

所用标准句（`{…}` 里是程序里已有的字段；破坏句前的时刻与句尾 `I feel angry toward this actor; my trust changed.` 不动）：

- 整座拆除 WHOLE：`Actor {actor} demolished the whole building "{building}" that I built, at ({x}, {y}, {z}), material {m}, in world {world} (transaction {seq}). The building "{building}" is gone; nothing of it is left.`
- 整座拆除备选 WHOLE_ALT：`Actor {actor} removed the entire building "{building}" that I built, at (…), material {m}, in world {world} (transaction {seq}); the building no longer exists.`
- 损坏一部分 PART：`Actor {actor} damaged part of the building "{building}" that I built, at (…), …; the building is still standing.`
- 处境事实句：`My building "{building}" at (25, 518, 37) is gone.` / `… is standing but damaged.`（插在 “Inventory:” 之前）

| 变体 | 来源 | 期望 | 结果 | 各次 top1（置信度） | 重建方向概率和 / guard_hut 概率 |
|---|---|---|---|---|---|
| b_original | C2 | 只测量 | — | guard_hut 0.74、0.66、0.66、0.69 | 0.14–0.18 / 0.73–0.79 |
| b_event | C2 | 重建方向 | 成立 4/4 | build_hut 0.14、gather_stone 0.14、gather_stone 0.11、build_hut 0.25 | 0.56–0.63 / 0.11–0.16 |
| b_event_alt | C2 | 重建方向 | 成立 4/4 | build_hut 0.16、0.18、0.19、0.25 | 0.61–0.67 / 0.09–0.10 |
| b_situation | C2 | 只测量 | — | gather_stone 0.14、0.24、0.25、0.16 | 0.58–0.65 / 0.17–0.21 |
| b_event_situation | C2 | 重建方向 | 成立 4/4 | gather_stone 0.18、build_hut 0.20、build_hut 0.16、gather_stone 0.22 | 0.60–0.69 / 0.11–0.15 |
| b_event_situation_alt | C2 | 重建方向 | 成立 4/4 | build_hut 0.24、gather_stone 0.20、gather_stone 0.20、build_hut 0.21 | 0.63–0.70 / 0.09–0.12 |
| b_partial | C2 | 只测量 | — | guard_hut 0.80、0.80、0.76、0.76 | 0.10–0.13 / 0.81–0.84 |
| c_original | C5 | guard_hut | 成立 4/4 | guard_hut 0.70、0.74、0.74、0.77 | — / 0.76–0.82 |
| c_no_inertia | C5 | top1 ≠ visit_plaza | **落空 2/4** | guard_hut 0.16、visit_plaza 0.16、visit_plaza 0.15、guard_hut 0.18 | visit_plaza 0.28–0.33、guard_hut 0.29–0.34、build_hut 0.28–0.29 |
| c_no_inertia_no_event | C5 | visit_plaza | 成立 4/4 | visit_plaza 0.44、0.42、0.46、0.50 | visit_plaza 0.54–0.60 |
| c_inertia_only | C5 | 只测量 | — | guard_hut 0.56、0.59、0.61、0.57 | guard_hut 0.65–0.69、visit_plaza 0.23–0.28 |

- (b)：说清“整座没了”——无论写在经历句还是处境事实句——guard_hut 从 0.73–0.79 掉到 0.09–0.21，top1 全部转到重建方向；
  但 build_hut 与 gather_stone 几乎五五开，top1 的置信度只有 0.11–0.25。备选措辞（removed the entire … no longer exists）
  build_hut 4/4、guard_hut 最低，略好于 WHOLE；只有 4 次，差别不大。“损坏一部分、建筑仍在”让守屋更稳（0.76–0.80），方向与语义一致。
- (c)：按规则，c_no_inertia 落空 → 记忆里的那件事不足以稳定改变选择。去掉惯性后它仍把 visit_plaza 从 0.54–0.60 压到 0.28–0.33，
  但 top1 在 guard_hut / visit_plaza / build_hut 三者间摇摆。只有惯性（c_inertia_only，删掉所有破坏与“要守”的记忆）就足以 4/4 守屋。
- 范围：一张卡、一个情境、每格 4 次；离线诊断，不是验收。没有测把“材料不够”写成事实句、Hindsight 把新句子抽成记忆后的召回文本。

## 2026-11-12 S1-D2 之后、S1-C2 实跑之前的预检（`s1c2_pilot.py`）

只问 Jev（HTTPS），不起服务端。state 取自 S1-C 的 C2 发问，只改两处使之等于 S1-D2 提交 `c0489bd7` 之后产品写出的文本：整座移除的标准经历句与处境里的 `is gone`。
8 个变体（base / no_event / no_gone / no_event_no_gone / no_anger / no_distrust / no_own_activity / all_removed）各 4 次，共 32 次；期望由统筹会话运行前写在脚本文档字符串里，
“重建方向”= top1 ∈ {build_hut, gather_stone}，4 次里至少 3 次算成立。
用法：`python -B s1c2_pilot.py prepare | run | report`（`report` 离线重出表格）。结果文件：`results-s1c2-pilot.json`。
结论：8 个变体全部符合运行前期望（两句事实任一句单独就够，两句都去掉则离开重建方向）。这是实跑前的预检，不是验收。

## 2026-11-12 S1-C2 实跑后的逐栏对照（`s1c2_counterfactual.py`）

只问 Jev，不起服务端。用 S1-C2 实跑存下的三份真实 state（B = 拆除后第一次选择，S = 陌生人在附近，V = 破坏者在附近），16 个变体各 4 次，共 64 次，全部应答。
期望与判定规则逐字抄自运行前定稿的 `s1c2/plan.md`，不许改；落空如实记落空。请求体与 `NpcServer.Selector.body/2` 一致，instructions 与候选表取自 `--template` 的 JSON。
用法：`python -B s1c2_counterfactual.py prepare | run | report`。结果文件：`results-s1c2-counterfactual.json`。
结论：(b) 通过——事件句与 `is gone` 任一句单独就够，两句都去掉回到 `visit_plaza`，愤怒、Distrusts、自己的活动记录去掉不变。(c) 不通过——S 与 V 原文都复现为 `guard_hut` 4/4，V 去掉 Distrusts 仍与 S 基线相同；
`nobody_nearby`（期望 `visit_plaza`，实际 `guard_hut` ×4）与 `memory_blank_no_distrust`（期望回到 S 基线，实际 3/4 `visit_plaza`）两项记录项落空。

## 2026-11-12 S1-C2 事后诊断（`s1c2_postdiag.py`）

探索性，不是验收。只问 Jev，24 次（6 个变体各 4 次），复用 `s1c2_counterfactual.py` 的分栏与删改办法（import，不改它）。问题：重建后的守屋来自记忆栏的哪一部分。
用法：`python -B s1c2_postdiag.py prepare --s S.txt --v V.txt --vandal-cid CID --vandal-name Corvin --template T.json`，之后 `run | report`。结果文件：`results-s1c2-postdiag.json`。
结论：运行前写定的 6 条期望，3 条成立（`S_recalled_removed`、`S_no_distrust`、`V_memory_blank` 都仍是 `guard_hut`），3 条落空
（`S_memory_blank`、`S_beliefs_blank`、`S_no_guard_memory` 期望 `visit_plaza`，实际都是 `guard_hut` ×4，0.67–0.90）。记忆栏与 Distrusts 任何一处单独去掉，守屋都不变；见统筹页“S1-C2 事后离线诊断”。
