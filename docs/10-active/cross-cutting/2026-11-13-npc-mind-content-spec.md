# 给 Jev 的内容规范与召回方案（草案，待用户过目；2026-11-13，第六个统筹会话）

分类：设计草案，不是已采用的规范。依据：用户 2026-11-13 的方向（见 [统筹页](2026-11-11-npc-coordination.md)“用户 2026-11-13 的方向”、[总纲](2026-11-12-npc-architecture-overview.md)末尾）——
**不强行要求选项，靠内容让决策自然涌现；记忆系统承担 LLM 之外的大部分思考；给 Jev 的内容要详细；召回要像人一样把相关记忆都调起来；测试从驱动力测。**
Hindsight 的实际能力见 `.demo/observe/npc-slice1-20261112/s1g/hindsight-capabilities.md`（读自运行中的 0.10.3 服务的 openapi）。

## 1. 现状诊断（读 S1-C3 一份真实 state `asked-20261113T011353.298Z.txt` 所得）

| 问题 | 在 state 里的样子 |
|---|---|
| 没有“现在”，时间是 12 个精确 UTC 时刻 | `At 2026-11-13T01:08:09.911Z (UTC), I did "guard_hut" … Result: completed.` 连续 12 句，模型算不出过了多久 |
| 活动只记“做了”，不记“期间发生了什么” | 守屋 12 次，没有一句“期间没人来”；记忆里只有“守过”，推不出“守了也没事”，所以没有材料得出“新房安全了” |
| 记忆里是自己的行为流水账 | 召回 11 条，其中 7 条是 guard_hut / visit_plaza / build_hut 的重复完成句；真正有信息的（谁拆了我的屋）4 条，且 3 条互为改写 |
| 认识文档的人称与库的设定不一致 | bank mission 写“first-person journal”，认识正文却是“You come across as… Your hut…”；召回句是第一人称 |
| 记忆条目的噪声 | `\| When: Friday, November 13, 2026 \| Involving: assistant, …`：`assistant` 是抽取器自己，不是任何角色；时间只到“日” |
| 人只靠 cid 指代 | 记忆写 `Actor 920628760578`，处境栏写名字 + cid，靠两处对上；总纲 :117 要求“不带 id”，与现状矛盾 |
| 背包 90 行 | 其中 88 行 `0 units`，非零的是 `32768`、`3457024`（单位不是玩家能懂的量） |
| 身体只有一句 | `Life 100 of 100.`；蛋白质 / 体温 / 伤势没进快照 |
| 没有计划、没有约定、没有游戏时刻 | 总纲的“我打算做什么”一栏代码里不存在；游戏时刻服务端当时没有 owner（写于游戏钟之前；现已有 `MmoContracts.WorldTime`，提交 `7db73952`，快照还没读它） |

## 2. 栏的内容规范（每栏：写什么 / 多细 / owner；英文句式在实现时用离线测量定稿，下表只定语义）

| 栏 | 写什么 | 多细 | owner / 取值 | 与现状的差 |
|---|---|---|---|---|
| Character | 人格卡原文 | 不变 | 注册参数 | 无 |
| Now（新增，放在最前） | 现在的 UTC 时刻；距上一次睡 / 吃 / 与人交谈各多久（有真值才写） | 一行 | Life 的 `now_ms`；身体读数 | 新增。单独不解决守屋（S1-E 第 3 轮），但所有“多久以前”都靠它 |
| Feelings and relationships | 情绪（对谁、多强）+ 信任 + **关系史一句**：对每个有关系的人，“他做过什么、何时（多久前）” | 每人一句，来自 Life 的事件账，不来自 Hindsight | Life | Distrusts 之外加一句原因，如 `Distrusts Corvin (actor V): he removed my hut 12 minutes ago.` |
| What just happened | 未封存的经历。**连续同类活动合并成一句，写次数、起止“多久前”，并写期间观察到的事实** | 每个合并段一句 | Life（经历原文）+ 观察 | `I guarded the hut 12 times over the last 5 minutes; nobody came near.` 取代 12 句 |
| What I remember | ① 认识（四份，第一人称）② 召回 | ② 见 §4：每条带“多久以前”，去掉抽取器噪声，人名与 cid 同写 | Hindsight，经 Life | 召回条数上限按人 / 地点 / 约定分配，不再一个问句取 11 条 |
| Current situation | 位置；身体（用词不用数：饿 / 冷 / 伤，阈值一张表）；附近的人（名字、种类、cid、距离、**他们此刻在做什么**，有真值才写）；我的建筑在不在；**背包只列非零项** | 背包一行，材料名取不到时写“material N”，数量用玩家可读单位 | World / Scene / Body | 去掉 88 行零；`body_state` 进来 |
| Recent activities | 最近几项活动的结局，**同样合并连续重复**（`guard_hut ×12: completed`） | 一行 | 选择器历史 | 合并 |
| Plans and promises（新增，有内容才写） | 未了的约定、打算：来自 Hindsight 的 commitments 认识与经历，**不另造计划指令** | 每条一句，带对方与时间 | Hindsight | 新增栏；没有内容就不写这一栏 |

纪律（所有栏共用）：只写“是什么、多久以前、对谁”，不写“应该怎么做”；不出现候选名之外的指令性句子；数字由代码转成词与相对时间，模型不做算术；
记忆与认识仍标“可能过时，不是当前世界事实”；人名一律 `名字 (actor cid)` 同写（见 §3 的写入侧替换，使记忆原文与处境栏能对上）。

## 3. 写入侧（retain）规范——召回质量在这里决定

Hindsight retain 项支持 `context`、`tags`、`entities`、`metadata`、`timestamp`、`observation_scopes`、`strategy`（见能力清单），我们现在只用了 `document_id` / `content` / `timestamp`。

1. **事件原文里的人写成 `名字 (actor cid)`**，由 Life 在写入时替换（Life 知道名字来自观察 / 事件）。这样记忆与处境栏用同一个写法，不再靠情绪栏那一句 Distrusts 做桥，也不依赖抽取器怎么改写 cid。
2. **活动经历带期间事实**：自己做完一件事不再只写 `I did X. Result: …`，加 `During it: <名字> came within <N> m / nobody came near / I was hit`。真值取活动期间的观察（Runtime 每帧有 `observation.entities`，Life 在活动开始与结束各取一次、结束时对比即可，**不增加新的观察通道**）。
   这是“重建后一段时间不去广场”的材料来源：有了“守了 12 次、没人来”，记忆（observation 类事实 / 认识）才可能得出“新房安全了”；没有这句，就只有“守过”。
3. **tags**：每条带 `actor:<cid>`（涉及的每个人）、`place:<名>`（建筑 / 地点）、`kind:event|activity|conversation`。召回时用 `tags` + `any_strict` 做“按人 / 按地点”的精确调取，不依赖语义相似度碰运气。
4. **`entities`**：把 `名字` 与 `actor cid` 作为同一实体的两种写法提交（`entities: [{text:"Corvin"}, {text:"actor 920628760578"}]`），并用 `/aliases` 登记，避免同一个人被抽成两个实体。
5. **bank 配置**（`PATCH /config`）：`retain_mission` / `observations_mission` / `reflect_mission` 写明第一人称、保留人名与 cid、保留次数与“没有发生什么”、不要把自己（assistant）当作实体；认识文档的 `source_query` 写成“I”人称（现在 `What kind of builder am I…` 已是，但正文变 “You”，是生成指令里缺人称约束，用 mission 校正，离线先看正文）。
6. 封存阈值（3000 字才写）与 600 秒才刷新认识：活动合并后字数涨得更慢，会更晚进库。**未决**：是否按“重要事件即刻写入 + 活动按时间窗合并”；先在离线测量里看延迟对决策的影响，再定。

## 4. 召回方案（每次选择：多路并行召回 → 合并去重 → 排序 → 渲染）

现状：1 次召回，问句 = 附近的人 + 全部候选判据 + 一句泛问，结果原样进 state。

新方案（请求并发 ≤ 3，合计耗时纳入总纲“选择连同召回 2–4 秒”的预算；`budget: "mid"`，各路 `max_tokens` 单独限）：

| 路 | 问句 / 过滤 | 目的 |
|---|---|---|
| R1 人 | 对每个在附近的角色（上限 2 个，近者优先）：`What has happened between me and <名字> (actor cid)? Did they help, harm, or promise me anything?` + `tags: [actor:cid]`、`any_strict` | 把“他对我做过什么”调起来；按 tag 精确取，不靠相似度 |
| R2 地点与物 | 对我的建筑 / 当前所在地点：`What has happened at <建筑或地点> since …?` + `tags: [place:名]` | “重建后发生过什么 / 没发生什么”——安全感从这里来 |
| R3 未了与感受 | `What am I looking forward to, worried about, or have promised to do?` 不加过滤（类型含 observation，`prefer_observations: true`） | 约定、担心、打算 |

合并：按 `id` 去重；先按路的优先级、再按 `occurred_start` 旧在前排；总条数上限（暂定 12）。渲染：`- (<多久以前>) <正文去掉 " | When: … | Involving: …" 后缀>`；`types` 里 `observation`（已巩固的认识）单独标出，
`experience` / `world` 按时间排。认识（四份 mental model）仍整份给出，但改为第一人称（§3.5）。
**不用 reflect 进热路径**（它是带工具的多轮 LLM 回路，延迟不可控）；reflect 只考虑放在后台巩固。

## 5. 离线测量设计（驱动力，不要求选某项）

素材：S1-C3 的真实 state 与导出记忆（`s1c3/export/`）。每次只动一个驱动来源，记录各候选的概率移动，期望只写“方向与归因”，运行前写定：

1. **内容形态对照**（同一份事实，只换写法）：合并 vs 12 句流水；相对时间 vs 绝对 UTC；背包去零；召回带 / 不带噪声后缀。读数：top1 是否稳定、各候选概率移动方向。期望：写法本身不应改变选择方向（回归性检查），噪声去掉后同一变体的 4 次间离散不变大。
2. **驱动来源逐个加**（沿用 S1-E 第 3 轮的“只加一句、不删原文”，但加的是**事实**而不是答案）：
   - 期间事实：`During those 12 guards nobody came near.`（期望：`guard_hut` 概率下降、`visit_plaza` 上升，方向合理；不要求越过）
   - 身体 / 过了多久：`Last talked with someone 3 hours ago.`
   - 约定：一条对方与时间的约定（`Maren and I agreed to meet at the plaza this afternoon.`）——这条是**驱动**，不是答案；看概率移动是否随“约定时间已到 / 未到”而变。
   - 反向：期间事实写“someone came near twice, then left”，期望 `guard_hut` 概率上升。
3. **召回方案对照**（需起 Hindsight：把 S1-C3 导出的事实重新 retain 进新 bank，带 §3 的 tags / 人名写法）：旧单路召回 vs R1+R2+R3；读数 = 召回条目里与“破坏者”“重建后的平静”相关的条数、重复率、总延迟。
4. 不做：任何“必须选 X”的断言；不评价“守屋是否正确”。

## 6. 要用户定的

**用户答复（2026-11-13）：1、2、3 全部同意**（含改总纲 :117 的 cid 写法、新增“现在”与“计划与约定”两栏、封存阈值与认识刷新节奏本片可动）。
同时提出：借鉴“AI 小镇”把**反思**加进流程（整理与丰富记忆），并把计划做成**分层**（至少延伸到一周、最小到半小时）；研究结论见统筹页。下面三条是当时的提问原文。

1. 内容规范 §2、§3 的方向是否认可（尤其：**写入侧在活动结束时加“期间观察到的事实”**，与 **Life 写入时把人名写成 `名字 (actor cid)`**——这改了“给判断者读的文字不带 id”的总纲 :117，我的理由是目前靠 cid 才对得上人，且已有离线证据）。
2. “Plans and promises”新栏、“Now”新栏是否在本片做（它们是内容；约定的写入来源在薄片二的规划层，本片只做读侧和离线测量）。
3. 封存阈值与认识刷新节奏（§3.6）是否在本片动。

## 7. 代码事实与估算（改动落点，认可后才动）

- `Mind`：加 Now 栏、合并连续活动、背包去零、体况用词、关系史句（需 Life 的事件账一个只读投影）。
- `Life`：活动开始 / 结束时取观察，写 `During it:`；写入时人名替换；retain 项加 `tags` / `entities` / `context`。
- `Life.Hindsight`：`recall` 支持 `tags` / `types` / `prefer_observations`；`ensure` 里设 bank mission；多路并行召回在 Life 的慢 worker 里做，不阻塞 Body。
- `Selector`：召回改为 `Mind.recall_queries/2` 产出多路问句；历史合并。
- 不动：`Body`、`World`、`Brain.Social`、候选表。

## 8. 落地前的更正与决定（2026-11-13，第七个统筹会话；依据离线测量 S1-I / S1-J / S1-K / S1-L，明细在统筹页）

- **§3.2 期间事实的真值**：改为活动期间逐帧记每个人的最小距离（Life 本来每帧收到观察，不加新通道），不是“起止各取一次”——离线材料里“靠近又走了”恰好发生在中途。靠近半径 **6 米**。两项都是用户 2026-11-13 定的；半径没有外部依据，是原创取值，实跑后可调。
- **§3.3 `place:` 的来源**：Registry 的活动候选加可选地名字段（用户定），登记边界校验一次；事件的 `place:` 取建筑名。
- **§3.5 mission**：`retain_mission` / `observations_mission` 经 `PATCH /config` 写入（S1-L：第一人称比例 1.00 对缺省 0.11 / 0.14，认识里有了次数）。副作用：更多事实被抽成 `world` 类型，所以**召回不按 `types` 过滤**。
- **§4 合并规则更正**：原文“先按路的优先级、再按 `occurred_start` 旧在前；总条数上限 12”会截掉最近的事实（S1-J：M1 库“没人来”11 条 → 0 条）。改为**按路配额、路内新的优先**；三路都 `prefer_observations: true`；每路 `max_tokens` 700 / 700 / 600；每路配额先取 4（**没有离线依据，原创取值**，实跑后调）。
- **§2 暂不落地的栏内容**：连续活动合并成一句（S1-H：`guard_hut` 0.81 → 0.89，未单独评估）、关系史一句（S1-K：三个时长都把守屋抬高 0.04–0.09）、“多久没跟人相处”（S1-K：方向相反）。“Plans and promises”栏的写法成立（S1-K：到点的约定 `visit_plaza` 0.56，未到点 0.18），内容来源等规划层。
- **旧数据**：写入形状改变后清空重建本线的开发库与 Life 片段，不写兼容（用户定）。
- 存进 Hindsight 的经历正文保持离线测过的 `At <UTC> (UTC), …` 写法；条目另存 `at_ms`，Mind 用它渲染相对游戏时间，不解析正文。

