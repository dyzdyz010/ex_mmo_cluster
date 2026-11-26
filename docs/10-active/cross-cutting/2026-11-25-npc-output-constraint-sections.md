# NPC 心智输出的约束段：每种输出在提示词里写清合格的样子（2026-11-25）

分类：NPC 心智侧的决策稿（定范围、依据、约束段原文、测试矩阵与实施次序）。上位：三循环稿
[`2026-11-23-npc-three-loop-framework-decision.md`](2026-11-23-npc-three-loop-framework-decision.md)，起因见 U-31 稿
[`2026-11-24-npc-route-and-teleport-decision.md`](2026-11-24-npc-route-and-teleport-decision.md) §10 2026-11-25 末条（M-3c C1 不成立）。
状态：**用户定方向（2026-11-25）；约束段原文已写成（§4），新一版 harness 已实施并离线验证（§9，指纹 `464f047c848998fa`）；M-3d 已实跑（§9 末条）：约束段只部分改变行为，自写经验里写死挖 / 放格的判定 C4 不成立，原因已按环节定位，下一轮的做法待用户定。**
2026-11-25 补：下一轮已由 [M-3e 稿](2026-11-25-npc-m3e-timeliness-and-way-sources-decision.md) 定（用户全照建议）；本稿 §2 依据、§4 原文、§5 的唯一定义处与“接纳边界不变”被该稿取代，各处已加注（§9 末条）。

## 1. 起因与用户的决定

M-3c 正式系列（`.demo/observe/npc-three-loop-m3c-20261124/plan.md` §10）里，三次 pit 的出坑都没有经过路线槽：表思考把 `find_route`
给的挖格坐标写成字面值，抄进自写经验的 `do_in_order`。pit-2 的推理原文说明了原因：它以为路线要在写待办时就给出
（“but the route value must be given when used, not now… awkward”）。现有的工具说明只有一两句话：`write_experience` 说“**如果**
每次用时要不同的值，就声明成参数”，待办的方式只说“the values it needs are given when I come to do it”，没说由谁、从哪里给。
字面值写进经验后，它就得自己逐步核对，于是困住之后又在推理里逐格算几何。

**用户的决定**：
- 「关于把具体参数也放进经验，这个要靠提示词约束的，针对每一种输出都要有约束段」（2026-11-25，系列进行中）。
- 对统筹提案（每种输出一段约束；先只靠提示词、代码不加专门的拒绝规则；改了另开一轮小验证）的答复：「可以，按这个方案开始写约束段」（2026-11-25）。
  （2026-11-25 “先只靠提示词、代码不加专门的拒绝规则”已由 [M-3e 稿](2026-11-25-npc-m3e-timeliness-and-way-sources-decision.md) D-6 定：程序在接纳边界按经验参数来源契约校验，不合格整条拒绝。）

## 2. 外部依据（AGENTS 2.2.8；2026-11-25 取原文）

（2026-11-25 本节依据被用户口径取代：提示词只写输出什么、为了什么、举一个例子，不抠细节、不写防御性条款；M-3d 里约束段被逐字引用却引出误读，是取代的理由之一。
见 [M-3e 稿](2026-11-25-npc-m3e-timeliness-and-way-sources-decision.md) D-8 的依据。下文原文保留作记录。）

Anthropic 官方文档 *Define tools*（`platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools`）“Best practices for tool definitions”：

- “**Provide extremely detailed descriptions.** This is by far the most important factor in tool performance. Your descriptions should
  explain every detail about the tool, including: What the tool does / When it should be used (and when it shouldn’t) / What each parameter
  means and how it affects the tool’s behavior / Any important caveats or limitations …”
- “Aim for at least 3–4 sentences for each tool description, more if the tool is complex.”
- “for tools with complex inputs, nested objects, or format-sensitive parameters, you can use the `input_examples` field to provide
  schema-validated examples.”

**对应与取舍**：
- 上面四项正好对应约束段的四部分：它做什么、什么时候用得上、每个字段的含义、限制与注意事项。
- 本项目的心智模型是 DeepSeek（OpenAI 兼容接口，严格模式），没有 `input_examples` 字段。所以复杂输入（`write_experience`）的样例
  写进说明正文，指向现有的 G0 经验，不新造样例。
- “when it shouldn’t”在本项目里只写**机制上的后果与形式要求**（写进步骤的字面值以后照原样用），不写对选择的倾向。这样与 U-3 / U-10
  （不替它判断、不点名该做什么）不冲突；评价词清单（`candidates.EVALUATION_WORDS`）与被删措辞（`mind.REMOVED_WORDING`）照旧为 0。
- 约束段只放在工具说明（每种输出各一段）里，系统提示词 P-plain 不动（它的“不列举该做什么”是 M-1 起的冻结口径）。

## 3. 盘点：模型能产出的每一种输出（M-3c harness，2026-11-25 核对）

| 部件 | 输出 | 现有说明（大意） | 缺什么 |
|---|---|---|---|
| 表思考 | `write_experience` | 由基本动作组成的做法；“如果”每次要不同的值就声明参数；build 的锚点与朝向来自点位组（B-2） | 经验会被反复用、字面值照原样用；取决于位置 / 世界的值一律写成参数；执行时怎样列候选、谁来选 |
| 表思考 | `add_todo` | 记下打算做的事；`not_before` | 方式只写名字；实参在做的时候按当时的世界列出、选定；所以现在不必知道路线、地点 |
| 表思考 | `add_schedule_entry` | 加一条日程（时段、可带 parent） | 同上（方式与实参） |
| 表思考 | `close_todo` | 关一条：done 或 given_up；下面的步一并关 | done / given_up 各指什么；没有“改一条”，改就关了再加 |
| 表思考 | `write_journal` | 写几行日记 | 日记只是给自己看的文字，不会去做；要做的进日程 / 待办，做法进经验 |
| 表思考 | `retire_experience` | 丢掉一个不再信的做法 | 字段含义（based_on、reason） |
| 表思考 | `note_region` | 给一段列范围起名 | 记下后它就是“我知道的区域”，用带区域 / 路线 / 料源 / 点位参数的做法时从中列出（离自己最近的至多 8 个）；两个角的次序 |
| 表思考 | `say` | 对身边的人说一句 | 立刻说出去、记进经历；不改日程 |
| 里思考（入睡整合） | `write_understanding` | 整段替换“认识”，≤ 2000 字符 | 不在新文字里的就没了；此刻会变的值（位置、余额）每次从世界读，不靠这一区 |
| 里思考 | `write_experience`、`retire_experience` | 与表思考同一份 | 同表思考（同一份说明、同一接纳边界） |
| Jev | 每次问话里的选项之一 | 选项本身带说明（语义类型的 `name` / `explain`、“现在做不做”的选项文字） | **不加**：输出只能是列出的选项之一，选项文字就是它的约束；判定 5 已管它不含评价词 |

只读查询（`look`、`survey`、`find_places`、`find_route` 等）不写心智、不改世界，不是输出，不在本稿范围。

## 4. 约束段原文（英文，写进工具说明；中文是给人读的对照）

写法：每段接在该输出现有说明之后（现有说明逐字保留），只写机制与形式；共用的句子只定义一次（DRY），由各段引用。

（2026-11-25 本节原文被 [M-3e 稿附录 B](2026-11-25-npc-m3e-timeliness-and-way-sources-appendix.md) 取代：每种输出改为一段完整说明，整段替换“现有说明 + 约束段”两截；
删了什么、为什么见附录 B.16。下文是 M-3d 用的版本，留作记录。）

**共用句 `VALUES_CHOSEN_WHEN_USED`**（经验、待办、日程三段都用）：

```text
When a way is used, the values it needs are filled at that moment: for each parameter with a sem kind, values are listed from the world as it is then (routes: from where I am then, the same listing find_route gives) and one is chosen; a parameter with no listing comes back to me to fill.
```
（做法被用的那一刻才给实参：带语义类型的参数按当时的世界列出候选、选一个——路线从当时站的地方列，与 find_route 同一份；列不出的参数交回给我填。）

**write_experience**（接在现有说明与 B-2 那句之后）：

```text
A way is kept and used again: each time, it starts from where I am at that time, in the world as it is at that time, and every value written into its steps is used exactly as written. So a value that depends on where I am or on how the world is when the way is used (a point to walk to or stand at, a cell to dig or to place, a route, an area, a source of material, a place to build) is a parameter with its sem kind, written {"$param": name} in the steps; a number written into a step is for a value that stays the same wherever and whenever the way is used, such as a tool id, a material id or a design id. A value read now with look, survey, find_places or find_route describes the world now; written into a step, it is used as written later, after I and the world have changed. <VALUES_CHOSEN_WHEN_USED> For example, make_my_way has one parameter, route (sem kind route), and one step, {"do_listed": {"$param": "route"}}: when it is used, an area is chosen from the areas I know, then a route from where I am to that area.
```
（做法会被反复用，每次从当时的位置、当时的世界出发，步骤里写的值原样使用。所以取决于位置或世界的值——要走到或站的点、要挖或放的格、路线、区域、料源、建造地点——写成带语义类型的参数；写死的数字只用于在哪里、什么时候用都不变的值，如工具号、材料号、设计号。此刻用 look / survey / find_places / find_route 读到的值描述的是此刻的世界，写进步骤后会在以后原样使用。样例指向现有的 G0 `make_my_way`。）

**add_todo**（接在现有说明之后）：

```text
what is the thing I mean to do and why is what it is for, in my own words. how names a way I know or a basic action and carries no values. <VALUES_CHOSEN_WHEN_USED> So a todo whose way needs a route, a place or a source can be written now, before I know which one. With a parent, it is a step of that item.
```
（what / why 用自己的话；how 只写名字、不带值；实参到做的时候才列出、选定，所以现在不必知道是哪条路线、哪个地点。）

**add_schedule_entry**（接在现有说明之后）：

```text
day, from and to are when I mean to do it; what, why and how are as in a todo: how names a way I know or a basic action and carries no values. <VALUES_CHOSEN_WHEN_USED>
```

**close_todo**（接在现有说明之后）：

```text
outcome done means what it was for has happened; given_up means I am not going to do it. note says what happened, in a sentence. A closed item is not taken up again. An item cannot be changed in place: to change one, close it and add a new one.
```

**write_journal**（接在现有说明之后）：

```text
about is who or what it is about; text is a few lines in my own words. The journal is shown to me when I think; it does not make anything happen: things I mean to do are in my schedule and todos, and ways of doing things are in my ways.
```

**retire_experience**（接在现有说明之后）：

```text
name is the way's name and based_on the version it has now, as shown with it; reason says why, in a sentence. The way is no longer among my ways.
```

**note_region**（接在现有说明之后）：

```text
(x0, z0) and (x1, z1) are opposite corners, whole columns, both included, with x0 <= x1 and z0 <= z1. Once noted, it is one of the areas I know: when a way with an area, a source, a place to build or a route among its parameters is used, the areas listed to choose from are the areas I know, the nearest to me first, at most 8.
```

**say**（接在现有说明之后）：

```text
It is said aloud right away, while I am thinking, and what I said is added to what has happened. It does not change my schedule or todos.
```

**write_understanding**（接在现有说明之后）：

```text
What is not in the new text is gone from this section. The section is shown to me each time I think. Values that change from moment to moment (where I am, what I hold) are read from the world each time and shown under Right now.
```

## 5. 落点与所有权

- 唯一定义处：M-3d 新一版 harness 的 `formats.py`，一张表 `OUTPUT_CONSTRAINTS`（输出名 → 约束段）加共用句 `VALUES_CHOSEN_WHEN_USED`；
  `m3_mind_ops` / `m3_inner_ops` 把约束段接在现有说明后面。M-3c 的 harness 冻结不动（它的报告绑着指纹 `1e238a2472c3f61f`），
  新版本照 M-3c 的做法另起目录复制（`.demo/observe/npc-three-loop-m3d-<日期>/`）。
  （2026-11-25 M-3e 起唯一定义处改为 `formats.OUTPUT_TEXT`，输出名 → 一段完整说明，取代 `OUTPUT_CONSTRAINTS`、`VALUES_CHOSEN_WHEN_USED` 等的拼接，见 M-3e 稿 D-8。）
- 进产品时（通用心智稿 §7）这张表随心智原子的说明一起迁移，不另写一份。
- 代码侧的接纳边界不变（用户定：先只靠提示词）；B-2 / B-10 与 `do_listed` 的清单规则照旧。
  （2026-11-25 被 M-3e 稿 D-6 取代：M-3d 读数是提示词约束不住，用户定由程序校验格式；接纳边界按“经验参数来源契约”整条拒绝不合格的经验，
  B-2 / B-10 与 `do_listed` 查树的规则并入该契约。）

## 6. 测试矩阵（按 `../Voxim/Docs/Testing.md`）

**契约**：§3 表里每一种表思考 / 里思考的输出都有一段约束，接在现有说明之后；文字不含评价词与被删措辞；严格模式工具表照旧合法。
**不覆盖**：模型是否照着做——那是实跑的读数与判定（下面最后一行），离线测试证明不了。

| 层 | 证明什么 | 做法 |
|---|---|---|
| harness 离线 | `m3_mind_ops` 与 `m3_inner_ops` 的每个输出名在 `OUTPUT_CONSTRAINTS` 里，说明以“现有说明 + 约束段”结尾；表里没有多余的名字 | 新用例先红后绿（改前 KeyError / 断言失败） |
| harness 离线 | 约束段里评价词 0、`REMOVED_WORDING` 0 | 复用现有扫描（`run.py dry` 与判定 5 的同一口径） |
| harness 离线 | 严格模式自检、三种预设的 `dry` 未处理错误 0 | `run.py dry`；五个测试文件循环 10 次 |
| 隔离节点小验证（M-3d） | 约束段是否改变行为：自写经验里还有没有字面坐标的 `dig_cell` / `place`；pit 是否经路线槽或传送出坑；困住后的推理长度 | 场景沿用 M-3c（pit / walled，`trap.py`），判定在发问前写定于 M-3d plan；额度先报用户 |

## 7. 风险

1. **说明变长**：每次表思考请求多几百 token；工具表在缓存前缀里，命中价 0.006 美元 / 百万 token，花费影响很小，实跑时读一下。
2. **模型照样写字面值**：提示词约束不是硬性的；M-3d 读数会直接看到。是否再加代码边界，到时由用户定。（2026-11-25 已由 M-3e 稿 D-6 定：程序在接纳边界按契约校验。）
3. **约束段被读成倾向**：只写机制与形式、不写评价词；判定 5 的扫描照旧。
4. **与 P-plain 的关系**：系统提示词不动，约束只在工具说明里，M-1 以来“不列举该做什么”的口径不变。

## 8. 实施次序（每步先报用户）

1. 本稿：盘点、依据、约束段原文（本步，未改代码）。
2. 新一版 harness（复制 M-3c 目录）：`OUTPUT_CONSTRAINTS` 与离线测试，先红后绿；`dry`；循环 10 次；重算指纹。
3. 写 M-3d 计划与判定（发问前写定），报额度，用户定后在隔离节点实跑。
4. 结果回填三循环稿与 U-31 稿；通过后随 U-31 稿 §9 第 5 步按通用心智稿 §7 进产品。

## 9. 进度

- 2026-11-25：用户定方向（§1）。统筹盘点 M-3c harness 的全部输出（§3），取 Anthropic 官方文档原文（§2），写成约束段原文（§4）。
  核对过的机制事实：待办方式只写名字、实参在做的时候给（`formats.how_schema`）；带语义类型的参数由决策循环按当时的世界列候选、
  Jev 选，没有候选的开放槽交回表思考（`decide.py` 模块说明）；“我知道的区域”= 启动数据的区域、表思考记下的与执行时查过的三栏并集，
  列出离自己最近的至多 8 个（`semantic_types.json` region）；`note_region` 的接纳只查两个角的次序（`formats.py` M-3 工具表注释）；
  `say` 接纳后立刻经桥说出并记一条经历（`think.py` 模块说明）；`write_understanding` 整段替换、≤ 2000 字符。未改代码、未实跑。
- 2026-11-25：§8 第 2 步完成（用户「可以，开始第 1 步」，即本稿 §8 第 2 步）。新一版 harness 在 `.demo/observe/npc-three-loop-m3d-20261125/`
  （由 M-3c 复制；M-3c 的 harness 指纹仍是 `1e238a2472c3f61f`）。改动明细在该目录 `harness/README.md` 末节，要点：
  - `formats.py` 一张表 `OUTPUT_CONSTRAINTS` 与共用句 `VALUES_CHOSEN_WHEN_USED`，`m3_mind_ops` / `m3_inner_ops` 把约束段接在现有说明之后；
    文字与 §4 相同，只有两处由代码取值：样例取 G0 的 make_my_way 本身，“至多 8 个”取 `formats.LIST_CAP`
    （从 `candidates.py` 挪来、在这里定义一次）。账本换成 `runs/spend-ledger-m3d.json`。
  - **证据**（`python -m unittest`，Windows miniconda 3）：新类 `test_slot_think.OutputConstraintsTest` 3 条，实现前全红（`AttributeError`），
    改后绿；账本用例改预期后 8 个子用例红、改后绿；随本步改预期的旧用例 1 条（B-2 那句不再在说明末尾，改成“说明里有这句”）。
    原位变异 3 个都被抓到、文件逐字节恢复。test_m3 79 / test_slot_think 69 / test_decide 83 / test_run 52 / test_report 109 /
    test_report_m3c 13 全绿；六个文件循环 10 次 60 / 60。`run.py dry`：三种预设未处理错误 0、被删措辞 0、评价词 0、严格模式问题 0。
    表思考工具表摘要 `3c2c8cddd70bd3af` → `d44f6aec7ff3c1f5`（多约 3,400 字符），里思考 `2054afecd69fc856` → `429e3ea91999fe3c`。
    harness 指纹 `464f047c848998fa`（未冻结；M-3d 计划写定后冻结）。未实跑、未调模型。
- 2026-11-25：用户定 §8 第 3 步的做法：「可以，开新会话做第 2 步，额度沿用 15 美元」——M-3d 的计划与判定由新统筹会话写
  （接力说明 `.demo/observe/npc-three-loop-m3d-20261125/handoff-brief.md` 第七版），账本 `runs/spend-ledger-m3d.json` 整轮硬上限 15 美元，
  实跑仍等用户看过计划再定。
- 2026-11-25：§8 第 3 步完成（M-3d）。第八个统筹会话写判定器 `report_m3d.py`（C0–C3 调 M-3c 的判定原样，新加 C4：被接纳的自写经验里
  dig_cell / place 的 x / y / z 写成数字的个数）与反例（18 条、原位变异 11 个），驱动、离线结果；用户定「五项都照建议，冻结 harness 开小集成」
  （C4 阈值 0、move_to 只作读数、小集成 1 + 正式 5、额度 15 美元、成立后直接开正式）。实跑中用户另定测试口径：测各独立环节对不对，整体是否达到目的
  只当症状、出问题定位到环节（「可以，按环节写报告，下一轮再改计划」；跨会话记忆 `npc-test-per-link`），本轮判定不改、报告加按环节诊断
  （`scripts/diagnose_m3d.py`，反例 11 条、变异 7 个）。产物在 `.demo/observe/npc-three-loop-m3d-20261125/`（`plan.md` §10、`report/`、`report/per-link.md`）。
  - **结果**（2026-11-25T09:45–12:02Z，harness `464f047c848998fa`，账本 $2.468、现算 $1.592，本线 UDP 0、4266 未变）：C0、C2、C3 成立；
    **C1 不成立（3 / 5）**：pit-3 第一次经路线槽出坑（自写方式带 route 参数与点位组，10 步全 done），walled 两次传送，pit-1、pit-2 自写字面挖格；
    **C4 不成立**：被接纳 64 条里 20 条含字面格、共 156 个（同一规则复算 M-3c：32 / 54、303 个），用路线参数 1 条（M-3c 0）。
  - **按环节**：约束段在提示词里、模型逐字引用；M-3c 的误解 “route value must be given when used, not now” 0 次——那一处讲清楚了。
    断在“理解”：模型把坑壁、料堆、地块的格读成“在世界里位置不变”，归到“写死的数字只用于在哪里、什么时候用都不变的值”那一句
    （两句对固定地形上的格给出相反答案）；另有一次性计划只能写成经验、“one is chosen” 不知谁选怕选错、自己先前的字面经验当先例。
    记忆 → 推送心智 127 次会话 0 处不符；系统函数、模块（C3）、事实闭环都对。另一处断点不在约束段：游戏钟 24 倍，表思考按会话开头的“此刻”排日程，
    被接纳时时段已过的日程正式 35 / 203，不执行也不留事实（M-3c 起就有）。
  - **待用户定**：下一轮候选 6 项（`report/per-link.md` §6：约束段那两句的歧义、写明谁选与怎么列、一次性具体动作的写法、计时与过期事实、
    里思考推送心智只列能用的、要不要加接纳边界规则）；下一轮计划按环节重写（用户已定）。
- 2026-11-25：下一轮由 [M-3e 稿](2026-11-25-npc-m3e-timeliness-and-way-sources-decision.md) 定，上条候选 6 项都在该稿处理，用户全照建议。按其 §十 第 3 条回填本稿，只加注、原文保留：
  §2 依据被用户口径取代（D-8）；§4 原文被该稿附录 B 取代；§5 唯一定义处改为 `OUTPUT_TEXT`（D-8），“代码侧的接纳边界不变”被 D-6 取代（含 §1、§7 风险 2 同义处）。
