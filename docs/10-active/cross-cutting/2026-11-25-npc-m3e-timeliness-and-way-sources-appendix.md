# 附录：经验参数来源契约逐格表、各段提示词原文与文本模板（M-3e，2026-11-25）

分类：正文 [`2026-11-25-npc-m3e-timeliness-and-way-sources-decision.md`](2026-11-25-npc-m3e-timeliness-and-way-sources-decision.md) 的附录，只放篇幅大的表与原文；
决策、理由、测试与实施次序都在正文。代码锚点指 M-3d 冻结版 harness（离线试验台，指纹 `464f047c848998fa`，目录 `.demo/observe/npc-three-loop-m3d-20261125/harness/`）。
出处：两份起草稿 `.demo/observe/npc-three-loop-m3d-20261125/next-round/draft-mind-prompts.md`（§1、§2、§3）与 `draft-plan-exec.md`（§1.3、§2、§4、§5），合成时按正文 §3.0 的统一命名改过。
状态：**未实施**。英文是写进 harness 给模型读的原文，中文是给人读的对照。

---

## A. 经验参数来源契约（正文 D-6）

### A.1 写法

**字面** = 任何合原子 schema 的字面值；**null** = 只许字面 `null`；**—** = 不许字面值；`T.r` = 带语义类型 T、角色 r 的 `$param`（经验参数引用）；
**结果** = 允许的 `$result` 来源（前面某一步用 `as` 起名后找到的东西）；**成组** = 同一步里同标签的参数必须来自同一个 sem 组（多角色类型的同一（类型, 组名））。
清单取自 `formats.ATOMS`（`npc-route-u31-20261124/atoms.json` 里八组、去掉 speak 与 find_route，共 24 个原子、70 个参数）与 3 个树节点位置；起草时离线核对过，没有漏的、没有多的。

### A.2 逐格表

| 原子 | 参数 | 字面 | `$param`（类型.角色） | 结果 | 成组 | 说明 |
|---|---|---|---|---|---|---|
| move_to | x, y, z | — | — | — | | 单格。**整条原子不能作经验的直接步骤**，只经 do_listed 的路线出现 |
| stop | （无参数） | | | | | |
| teleport_to_spawn | （无参数） | | | | | |
| probe_toward | direction | 字面 | — | — | | 相对自己的方向，与站在哪无关（方法常量） |
| probe_toward | tool_id | 字面 | tool.tool_id | — | | |
| use_tool | target | — | — | probe_toward 的 `["target"]` | | 原子说明：“Copy target unchanged … never make one up” |
| use_tool | tool_id | 字面 | tool.tool_id | — | | |
| dismantle | target | — | — | probe_toward 的 `["target"]` | | probe_toward 说明：“pass data.target unchanged to use_tool / dismantle” |
| dismantle | tool_id | 字面 | tool.tool_id | — | | |
| place | x, y, z | — | — | — | | 单格，**整条原子不能作直接步骤**（同 move_to） |
| place | tool_id；material | 字面 | tool.tool_id；材料三种¹ | — | | 因上一行，实际用不到 |
| scoop | target | — | — | — | | probe_toward 的 target 粒度是 0–3、scoop 只收 0，类型不符；inspect 没有结果契约 → **整条不能** |
| scoop | tool_id | 字面 | tool.tool_id | — | | |
| pour | x, y, z | — | — | — | | 单格 → **整条不能** |
| pour | tool_id；material | 字面 | tool.tool_id；材料三种¹ | — | | |
| craft | material | 字面 | 材料三种¹ | — | | |
| eat | material | 字面 | 材料三种¹ | — | | G0 forage_and_eat 用料源组的 material，所以含 source.material |
| attach | x, y, z | — | — | — | | 单格（micro）→ **整条不能** |
| attach | size, kind, axis | 字面 | — | — | | |
| attach | tool_id；material | 字面 | tool.tool_id；材料三种¹ | — | | |
| detach | target | — | — | — | | probe_toward 的 target 粒度不符（detach 只收 3）→ **整条不能** |
| detach | tool_id | 字面 | tool.tool_id | — | | |
| prefab | op | 字面 | — | — | | |
| prefab | x, y, z, instance | — | — | — | | op = place 的锚点无来源（同原 B-10）；remove / replace 的 instance 是世界里某个建筑的句柄，与人物句柄同理不收字面 → **整条不能**（正文 §一 已定 ⑤） |
| prefab | definition | 字面 | prefab.definition | — | | |
| prefab | orientation | null | — | — | | |
| look | x0, y0, z0, x1, y1, z1 | — | region_cells.同名角色 | — | 范围 | 六个来自同一组 |
| survey | x0, z0, x1, z1 | — | region_columns.同名角色 | — | 范围 | 四个来自同一组 |
| inspect | （无参数） | | | | | |
| query_balances | （无参数） | | | | | |
| read_catalog | what | 字面 | — | — | | |
| read_catalog | definition | 字面（含 null） | prefab.definition | — | | 设计号是方法常量 |
| say | text | 字面 | open.text | — | | `open` 只在这一格合法 |
| say | target_id | null | person.entity_id | — | | 人物句柄不收字面 |
| say | conversation_id | null | — | — | | 会话句柄，没有语义类型 |
| build | definition | 字面 | prefab.definition | — | | |
| build | anchor_micro, orientation | — | site.anchor_micro / site.orientation | — | 点位 | 原 B-2 |
| dig_cell | x, y, z | — | — | — | | 单格 → **整条不能**（只经 do_listed） |
| dig_cell | tool_id | 字面 | tool.tool_id | — | | |
| gather | box, material | — | source.box / source.material | — | 料源 | 料盒与它的材料是一个候选值 |
| gather | units | 字面 | quantity.units | — | | |
| gather | tool_id | 字面 | tool.tool_id | — | | |
| travel | x, z | null | place.x / place.z，或 site.stand_x / site.stand_z | — | 去处 | “去某处”这一轮用“区域名 + 路线”，地点类不加区域名 |
| travel | entity_id, entity_epoch | null | person.entity_id / person.entity_epoch | — | 去找谁 | |
| *树节点* repeat.times | | 字面 | count.n | — | | |
| *树节点* wait_seconds | | 字面 | duration.seconds | — | | |
| *树节点* do_listed | | — | route.calls | — | | 原有规则（M-3c） |

¹ 材料三种：recipe_product.material、held_material.material、source.material。

“整条不能”的 8 个原子（move_to、place、dig_cell、pour、attach、scoop、detach、prefab）不另列表：由“它有某个参数既不收字面、也不收参数、也不收结果”推出（只定义一次）。

### A.3 附加规则（与逐格表同一节）

- **空间类型**（`place`、`region_cells`、`region_columns`、`source`、`site`、`person`、`route`）的参数：不许 `one_of`；`minimum` / `maximum` 只能不写，
  或与使用处原子 schema 的界限相同（G0 `restock_and_build` 的 `orientation` 声明 0–23，就是 build 原子自己的界限；起草时试过“一律不许界限”会误拒 G0 两条）。
- `sem` 为 null 的参数在任何要求 `$param` 类型的格子上都不合格（null 等于开放类型，只有 `say.text` 收 `open`）。所以 `open` 槽不能声明空间类参数。
- 走整棵树，含 `try_in_order` 各支与 `repeat` 体（`formats.atom_nodes` 的遍历）。
- **一次性指令不受本契约管**：它是具体的一次调用，不是经验，不进经验区（正文 D-5）。

### A.4 存放形状（`semantic_types.json` 新一节 `arg_sources`，唯一定义处）

```json
"arg_sources": {
  "about": "原子参数在经验里允许的来源（M-3e 决策稿附录 A）。value: any / null / none；param: [类型, 角色] 表；result: [原子, 路径] 表；together: 同一步里同标签的参数来自同一个 sem 组。",
  "spatial_types": ["place", "region_cells", "region_columns", "source", "site", "person", "route"],
  "region_types": ["route", "source", "site"],
  "atoms": {
    "travel": {
      "x": {"value": "null", "param": [["place", "x"], ["site", "stand_x"]], "together": "where"},
      "z": {"value": "null", "param": [["place", "z"], ["site", "stand_z"]], "together": "where"},
      "entity_id": {"value": "null", "param": [["person", "entity_id"]], "together": "who"},
      "entity_epoch": {"value": "null", "param": [["person", "entity_epoch"]], "together": "who"}
    },
    "use_tool": {
      "target": {"value": "none", "result": [["probe_toward", ["target"]]]},
      "tool_id": {"value": "any", "param": [["tool", "tool_id"]]}
    },
    "dig_cell": {"x": {"value": "none"}, "y": {"value": "none"}, "z": {"value": "none"},
                 "tool_id": {"value": "any", "param": [["tool", "tool_id"]]}}
  },
  "nodes": {
    "repeat.times": {"value": "any", "param": [["count", "n"]]},
    "wait_seconds": {"value": "any", "param": [["duration", "seconds"]]},
    "do_listed": {"value": "none", "param": [["route", "calls"]]}
  }
}
```

（只示三个原子；实施时按 A.2 写全。读者：接纳边界 `accept.py`（唯一裁决者）、离线测试、诊断脚本；以后若从契约派生 strict schema，也从这一节出。）

### A.5 拒绝原因模板与规则码

规则码只在 `accept.RULES` 定义一次（正文 §3.0）；原因是英文事实句，回到同一会话；一次至多 8 条。

| 规则码 | 原因模板 |
|---|---|
| `literal_not_allowed` | `{path}: {atom} {arg} is written as a value; in a way, {atom} {arg} can be {allowed}.` |
| `atom_not_in_ways` | `{path}: {atom} is not a step of a way: nothing in a way can give its {args}. It can be a call in a one-time command{route}.`；`{route}` 只对路线里会出现的原子（取路线列举的定义）写 `, or come in a route given to do_listed` |
| `param_sem_not_allowed` | `{path}: {atom} {arg} is the parameter {p!r} ({sem 描述，或 "with no sem type"}); in a way, {atom} {arg} can be {allowed}.` |
| `result_pair_not_allowed` | `{path}: {atom} {arg} is what {name!r} ({atom2}) found at {path2}; in a way, {atom} {arg} can be {allowed}.` |
| `not_one_group` | `{path}: {atom} {a} and {b} are parameters of two different sem groups; they come from one sem group of type {t}.` |
| `one_of_on_spatial` / `bounds_on_spatial` | `params[{i}] ({p}): a parameter of sem type {t} has no one_of, and no minimum or maximum other than those of {atom} {arg}.` |
| `region_on_wrong_type` | `params[{i}] ({p}): region is given only for sem type route, source or site.` |
| `region_differs_in_group` | `{group}: names two regions, {a!r} and {b!r}.` |
| `region_unknown` | `params[{i}] ({p}): there is no region named {n!r} among the regions I know by name ({names}).` |
| `reserved_name` | `name: one_time_command is the name used for one-time commands.` |

`{allowed}` 由表现拼：`a value`、`null`、`a parameter of sem type place (role x) or site (role stand_x)`、`what a probe_toward step found at ["target"]`，几项用 `or` 连。
其余规则码（计划一侧、区域名、评价）的原因见 C.5。

### A.6 离线试算（起草时，只读；草稿契约表对日志里的调用参数原文）

- G0（启动经验库）16 条全过。
- M-3d 正式系列被接纳的 64 条自写经验里 **55 条会被整条拒绝**；其中 35 条不含字面挖 / 放格（M-3d 的判定 C4 只数挖 / 放格，没数到这些：写死的 `travel` 51 处、`gather.box` 30 处、`look` / `survey` 范围 15 处）。
- pit-3 唯一走通路线槽的 `climb_quarry_and_build_hut` 也会因写死料盒被拒。

---

## B. 提示词原文（正文 D-1、D-4、D-5、D-8、D-9）

口径（用户定）：只写输出什么、为了什么、举一个例子；不抠细节、不写防御性条款、不用评价词；格式靠程序校验。
每种输出一段完整说明，唯一定义处 `formats.OUTPUT_TEXT`（输出名 → 说明），取代 M-3d 的 `OUTPUT_CONSTRAINTS`、`with_constraint`、`VALUES_CHOSEN_WHEN_USED`、`BUILD_SITE_TEXT` 的拼接。
`<AFTER_TEXT>`、`<REPLY_GAME_TIME>` 是下面 B.0 的两句共用句，各定义一次，代码里拼接。

### B.0 共用句

```text
AFTER_TEXT = after is the id of an item to do first, or null: this one is not started until that one's last run has completed or I have closed it as done.
REPLY_GAME_TIME = The reply gives the game time when it was taken in.
```
after 写先要做的那一条的 id，或 null：那一条最近一次执行完成、或被我以 done 关掉之前，这一条不开始。／回执写明接纳时的游戏钟。

接在三种计划条目（日程、待办、一次性指令）的说明里；其余输出的回执也带游戏钟（同一出口），说明里不写。

### B.1 write_experience（表思考）

```text
Write a way of doing something that I can use again. Where to go, which route to take (cells to dig or place come in a route), which region or pile, and where to build are parameters with their sem type: each time the way is used, the world lists what is there then and I pick one. To always use one region I know, write its name as the parameter's region. Ids of tools, materials and designs, amounts, counts and times can be written as values. A step named with "as" lets a later step use what it found, written {"$result": name, "path": ["target"]} (a probe_toward target, for use_tool or dismantle). Example: make_my_way has one parameter, route (sem type route, region null), and one step, {"do_listed": {"$param": "route"}}; with region "my plot" it always takes a route to my plot.
```
写一条以后还能再用的做法。去哪、走哪条路线（要挖或放的格在路线里）、哪个区域或料堆、在哪建，都写成带语义类型的参数：每次用的时候，世界列出那时有的，我挑一个。
想固定用我知道的某个区域，就把它的名字写在参数的 region 上。工具、材料、设计的编号，数量、次数、时长可以直接写值。用 "as" 给一步起名，后面的步骤
可以用它找到的东西（probe_toward 找到的 target，给 use_tool 或 dismantle）。例：make_my_way 有一个参数 route（语义类型 route，region 为 null）
和一步 do_listed；region 写 "my plot" 时，它总是走一条去我的地块的路线。

（例子取 G0 的 make_my_way 本身。合成时把起草稿的 “which cells to dig or place … are parameters” 改成 “cells to dig or place come in a route”：
契约里 dig_cell / place 的 x / y / z 不收任何参数，原句会让模型声明格参数、再被拒。）

### B.2 add_todo

```text
Note something I mean to do, so that I take it up when I can: what and why in my own words, and how, the name of a way I know or a basic action. The values the way needs are picked when I come to do it. <AFTER_TEXT> <REPLY_GAME_TIME> Example: {"what": "Get out of the pit", "why": "I cannot reach my plot from down here", "how": {"way": "make_my_way"}, "not_before": null, "parent": null, "after": null}
```
记下一件打算做的事，好在能做的时候去做：what、why 用自己的话，how 写我知道的一种做法或一个基本动作的名字。做法要的值，到做的时候再挑。<after 句> <回执句> 例：（见上）。

### B.3 add_schedule_entry

```text
Add one entry to my schedule: something I mean to do from one time to another, today or tomorrow, so that I do it then. how is as in a todo. <AFTER_TEXT> <REPLY_GAME_TIME> Example: {"day": "today", "from": "12:00", "to": "12:30", "what": "Eat lunch", "why": "I get hungry by noon", "how": {"way": "eat_servings"}, "parent": null, "after": null}
```
往日程里加一条：今天或明天从几点到几点打算做的事，到时去做。how 同待办。<after 句> <回执句> 例：（见上；`eat_servings` 是 G0 的一条）。

### B.4 add_command（一次性指令，表思考才有）

```text
Add a one-time command: basic-action calls with their values, done in order when it comes up in my plans and stopping at the first that fails; it is run once and is not kept as a way. It is for doing something once as things are now, such as the calls of a route find_route listed. <AFTER_TEXT> <REPLY_GAME_TIME> Example: {"what": "Climb out of the pit", "why": "to get to the stone", "calls": [<CALLS>], "after": null}
```
加一条一次性指令：一串带具体值的基本动作调用，在计划里轮到时按序做，哪一步失败就停；只做一次，不留作做法。用来照此刻的样子做一次的事，
比如照 find_route 列出的路线做。<after 句> <回执句> 例：（见上）。

`<CALLS>` 取一次真实 find_route 回答里第一条路线的前两步（不手写）。现有候选：M-3d pit-3 表思考会话 outer2 第 2 轮的回答（日志 seq 164）：
`{"atom": "move_to", "args": {"x": 29.5, "y": 506, "z": 47.5}}, {"atom": "dig_cell", "args": {"tool_id": 1, "x": 28, "y": 507, "z": 47}}`。
这两步就是坑场景自己的出坑路线（M-3d 五次的 find_route 回答起点都在坑里），正文 §一 已定 ⑪：不用它，改在实跑准备里于出生点附近只读查一次 find_route，取前两步。
（2026-11-25 用户补定：例子的 `what` / `why`（原文 “Climb out of the pit” / “to get to the stone”）随 ⑪ 一起换，按出生点附近那条路线实际去向写，理由同 ⑪——例子不与被测场景重合；实跑准备时与两步一并定，整个例子报用户看过再冻结指纹。）

### B.5 close_todo

```text
Close an entry of my schedule, a todo, a one-time command, or a step of one, so that it is not taken up again: done when what it was for has happened, given_up when I am not going to do it; note says what happened. To change an item, close it and add a new one. Example: {"todo": "t3", "outcome": "done", "note": "I am out of the pit."}
```
关掉日程、待办、一次性指令或其中一步，它就不会再被拿起：done = 它要达到的已经达到，given_up = 不打算做了；note 写发生了什么。要改一条，就关掉再加一条新的。例：（见上）。

（合成时补了 “a one-time command”：一次性指令也只由表思考关。）

### B.6 write_journal

```text
Write a few lines in my journal about someone or something, for me to read when I think later. Example: {"about": "Mira", "text": "She showed me where the limestone is. I want to thank her."}
```
在日记里写几行，关于某人或某事，供以后想事时读。例：（见上）。

### B.7 retire_experience（表、里思考同一段）

```text
Drop one of my ways when I no longer want to use it: name, based_on (its version as shown with it) and the reason. A plan item naming it is not run after this, and I am told. Example: {"name": "quarry_hut_stone", "based_on": 2, "reason": "The pile it digs from is used up."}
```
不想再用某种做法时把它丢掉：名字、based_on（显示的版本号）和理由。之后写着它的计划条目不会执行，我会得知。例：（见上）。

### B.8 note_region

```text
Note a region under a name not used for another region, by two opposite corners, so that my ways can name it and things in it can be listed. Example: {"name": "the plaza", "x0": 40, "z0": 12, "x1": 52, "z1": 20}
```
用一个没给别的区域用过的名字和两个对角记下一块区域，好让我的做法能用名字指它、能在里面列出东西。例：（见上）。

### B.9 say

```text
Say one line aloud right now, to someone near me (target_id, their actor id) or to whoever is near (null); conversation_id is the conversation I answer in, or null. Example: {"text": "Good morning, Mira!", "target_id": 1203, "conversation_id": null}
```
此刻说一句话，对身边某人（target_id 是对方的 actor id）或对附近的人（null）；conversation_id 是我在回应的那段对话，或 null。例：（见上）。

### B.10 字段级说明的改动（schema 里的 `description`；其余字段说明不动）

| 字段 | 原文 |
|---|---|
| 经验参数 `sem.region`（新，必填可空） | `For a parameter of sem type route, source or site: the name of a region I know, so the way always uses that region; null to pick a region each time. The same for every parameter of one group.` |
| 三种计划条目的 `after`（新，必填可空） | `The id of an item to do first, e.g. t3; or null.` |
| `ITEM_ID`（close_todo 的 todo、parent） | `Its id, e.g. s2, t1, g3 or c4.`（原文 `e.g. s2, t1 or g3.`） |
| add_command 的 `calls` | `The basic-action calls, in order, each with its atom and args.`；每项 schema 用 `formats.atom_step_branches(in_tree=False, params=False)` 生成（原子名枚举 + 该原子的参数 schema，不许 `$param` / `$result` / `as`） |
| evaluate_experience 的 `confidence` | `A whole number from 1 to 10.` |

### B.11 Jev 在计划队头的新选项

键 `stop_and_think`，文字：

```text
Not now: stop and think over my plans first.
```
现在不做：先停下来把计划想一想。（排在现有选项之后；问法与现有选项的键、文字、次序都不变。）

### B.12 表思考查询时调了世界动作的提示（`think.HINT`，只改一句）

```text
To do it, put it in my schedule, a todo or a one-time command.
```
（原文 `To do it, put it in my schedule or a todo with this action as its way.`；只陈述有哪几种写法。表思考的系统提示词 `think.SYSTEM` 不改。）

### B.13 里思考的系统提示词（新，`inner.INNER_SYSTEM`）

```text
You are the inner mind of the person described below, who lives in a voxel world, going over things at a quiet moment.

The message after this one holds who you are, what you have come to understand, the ways of doing things you wrote with how each has gone, and what has happened since you last went over things.

Look back over what has happened and write down what you make of your ways: how far you trust a way, from 1 to 10, and why; drop a way you no longer want; and rewrite what you have come to understand. When you plan later, you see these beside your ways. If nothing has changed what you make of them, use no tool and say so in one sentence.

- Times of day are HH:MM on the 24-hour clock.
```
你是下面这个人内心的一部分，在安静的时候回顾。下一条消息里是你是谁、你的认识、你写下的做法及各自用得怎样、上次回顾以来发生了什么。
回顾发生的事，写下你对这些做法的看法：信得过几分（1 到 10）与理由；丢掉不想再要的；改写你的认识。以后做计划时，你会在做法旁边看到这些。
如果没有什么改变你的看法，就不调用工具，用一句话说明。

（“只能做这几件事”不写：M-3d 里思考调没有的工具，根因是推送心智列了它用不了的东西，由里思考视图去掉，见 C.4。）

### B.14 evaluate_experience（新，里思考才有）

schema：`{name: string, version: integer, confidence: integer 1–10, reason: string}`，全部必填。

```text
Write how far I trust one of my ways, from what has happened when I used it, so that I see it beside the way when I plan: name and version as shown with the way, confidence a whole number from 1 (not at all) to 10 (fully), and the reason. Example: {"name": "climb_out_of_pit", "version": 2, "confidence": 3, "reason": "It failed twice today, blocked at the second dig; it may not be right and needs trying again."}
```
根据用这种做法时发生的事，写下我对它信得过几分，好在做计划时在它旁边看到：名字与版本照显示的写，置信度 1（完全不信）到 10（完全信）的整数，再写理由。
例子里的理由取用户第二轮的原意（“失败过……可能不准确，需要后续实践验证”）。

### B.15 write_understanding（里思考）

```text
Rewrite what I have come to understand, as one text of at most 2000 characters that replaces this section, so that I read it each time I think. Example: {"text": "I live on a small plot beside a stone pile and a limestone pile. Mira lives to the east and trades greens."}
```
改写认识：整段替换、至多 2000 字符，供每次思考时读。例：（见上）。

### B.16 与约束段稿（`2026-11-25-npc-output-constraint-sections.md` §4）现行原文的对照：删了什么、为什么

| 输出 | 删去的原文 | 为什么 |
|---|---|---|
| write_experience | `a number written into a step is for a value that stays the same wherever and whenever the way is used, such as a tool id, a material id or a design id` | 与前一句对“固定地形上的格”给出相反答案（M-3d per-link §3 ①）；模型把坑壁、料堆、地块的格读成“位置不变”的值。新稿按种类列：位置类写参数，编号 / 数量 / 次数 / 时长可写值 |
| write_experience | `A way is kept and used again: …every value written into its steps is used exactly as written.` 与 `A value read now with look, survey, find_places or find_route describes the world now; …` | 解释与防御性条款；改由契约在接纳边界拒绝、原因交回 |
| write_experience 等三段共用 | `VALUES_CHOSEN_WHEN_USED` 全句（`… and one is chosen; a parameter with no listing comes back to me to fill.`） | “one is chosen” 没说谁选（per-link §3 ③：“Ambiguous who chooses. Might pick nearest wrongly.”），改成 “I pick one”；“列不出的交回给我填”是细节，契约下空间参数也不会成开放槽 |
| write_experience | 样例后半 `when it is used, an area is chosen from the areas I know, then a route …` | 改成同一例子加 region 的写法 |
| write_experience | `BUILD_SITE_TEXT`（build 的锚点与朝向是同一点位组的参数、prefab 不能放设计） | 细节；由契约“成组”与 prefab 整条不能在接纳边界查 |
| write_experience | M-2c 现有说明 `Using the name of a way I already know replaces it. If the way needs values …` | 并进新段；`based_on` 的含义在字段说明里 |
| add_todo / add_schedule_entry | `So a todo whose way needs a route, a place or a source can be written now, before I know which one.` 与共用长句 | 推论与细节，保留“做的时候再挑”一句 |
| close_todo | `A closed item is not taken up again.` 并入“为了什么” | 只改写，不删机制 |
| write_journal | `it does not make anything happen: things I mean to do are in my schedule and todos, …` | 防御性条款；改为写明用途 |
| say | `It does not change my schedule or todos.` | 防御性条款 |
| note_region | `(x0, z0) and (x1, z1) are opposite corners, whole columns, both included, with x0 <= x1 and z0 <= z1. Once noted, … at most 8.` | 次序由程序查；“至多 8 个”是列举细节。新增“名字不与别的区域重”（Q6）与用途 |
| write_understanding | `Values that change from moment to moment (where I am, what I hold) are read from the world each time and shown under Right now.` | 防御性条款 |

---

## C. 推送心智、事实、回执与拒绝原因的文本模板

### C.1 条目行（`render.Render._line`；Jev 与表思考的推送心智同一处，里思考视图不列条目行）

现有各段（方式、Why、档位、not before、last run、I judged at）不变，末尾追加：

- **前驱段**（条目自己写了 `after` 才有，紧接“上次结局”之后）：`— after [t3] (t3: <前驱状态>)`

  | `after_state` | 写法 |
  |---|---|
  | `done` | `done: last run completed at day 2, 10:12` / `done: I closed it as done at day 2, 10:40` |
  | `given_up` | `I closed it as given up at day 2, 10:40` |
  | `failed` | `last run failed (gather: unreachable) at day 2, 10:12`（结局原文） |
  | `window_ended` | `its time ended at day 2, 10:15, with no completed run` |
  | `not_run` | `not run yet` |

- **状态段**（全部未关条目都写，写法一样）：`— now: <状态>`

  | `state` | 写法 |
  |---|---|
  | `not_rated` | `now: not rated yet` |
  | `waits_for_thinking` | `now: waits for my thinking about a value of [f12]` |
  | `waits_for_time` | `now: waits until day 2, 14:00` |
  | `window_ended` | `now: its time ended at day 2, 10:15, not started`（开始过的不写 `, not started`） |
  | `waits_for_after` | `now: waits for [t3]` |
  | `not_taken_up` | `now: not taken up again (<原因>)`，原因如 `no values were listed for the pile to dig from, day 2, 11:02`、`I judged it needs no more doing`、`a one-time command is run once` |
  | `started` | `now: being done ([f12])` |
  | `waits_for_steps` | `now: waits for its open steps` |
  | `can_start` | `now: can be started` |

- **一次性指令的行**（方式一格写原子个数，不写具体值）：

```text
- [c40] Climb out of the dip (one-time command: 12 basic actions — move_to 7, dig_cell 4, place 1). Why: to get to the stone — how much it matters: urgent — last run: failed (dig_cell: protected_region) at day 1, 18:52 — now: not taken up again (a one-time command is run once)
```

- 示例（M-3d walled-1 那种处境）：

```text
- [t41] Haul stone for my hut (way: haul_stone_for_my_hut). Why: the hut needs stone. — how much it matters: important — after [c40] (c40: last run failed (dig_cell: protected_region) at day 1, 18:52) — now: waits for [c40]
```

- “已开始的调用”一区里指令帧写 `by my one-time command [c40]`。

### C.2 新事实的文本（都由决策循环提交，`refs` 带条目 id）

| 种类 | 文本 | refs |
|---|---|---|
| `stopped_to_think` | `At day 2, 12:00, with [s12] "Eat lunch" up next, I stopped to think over my plans.` | `[{"name": "plan item", "id": "s12"}]` |
| `window_ended_unstarted` | `The time for [s12] "Climb out of the pit" (day 2, 10:00–10:15) ended without it being started.` | 同上 |
| `after_not_done`（前驱失败） | `[t4] "Quarry stone" comes after [t3] "Climb out of the pit", whose last run (day 2, 10:12) ended: failed (gather: unreachable); [t4] has not been started.` | `[{"name": "plan item", "id": "t4"}, {"name": "after", "id": "t3"}]` |
| `after_not_done`（前驱被放弃） | `[t4] "…" comes after [t3] "…", which I closed as given up at day 2, 10:40; [t4] has not been started.` | 同上 |
| `after_not_done`（前驱时段过了） | `[t4] "…" comes after [s3] "…", whose time (day 2, 10:00–10:15) ended with no completed run; [t4] has not been started.` | 同上 |
| `outcome`（指令的结局，现有种类与路径） | `I ran my one-time command [c40] for "Climb out of the dip". Result: failed (dig_cell: protected_region). Steps: move_to done, move_to done, dig_cell rejected (protected_region).` | 现有 |

事实的 `at` 取写下它的那一轮的此刻；时段写在文本里。

### C.3 经验行的评价与被丢方式的注记（`render.Render._ways`、`_how`、`_kind`）

- 经验参数行写出区域名（`_kind`）：`  - route (calls; kind: route, role calls, region "my plot")`；region 为 null 不写。
- 当前版本有评价时，在使用统计那行之后写最新一条：`  My judgment at day 2, 03:10: 3 of 10 — It failed twice today, blocked at the second dig; it may not be right and needs trying again.`；没有评价不写。
- 条目的方式已被丢掉、评价栏里有它的 `dropped` 记录时：`climb_out_of_pit — a way I no longer know (I dropped it at day 2, 03:15: It never got me out.)`

### C.4 里思考的推送心智（新视图 `render.inner_view`）

| 区 | 列不列 | 内容 |
|---|---|---|
| 我是谁 | 列 | 人物卡 |
| 我的认识 | 列 | 它能整段改写 |
| 我写的做法及用得怎样 | 列 | 每条：名字、参数、版本、意图、步骤、使用统计、写着它的未关条目（`Named as the way of: [t3] Get out of the pit`，只写 id 与 what）、这一版的历次评价（时刻、几分、理由） |
| 上次回顾以来发生的事 | 列 | 游标区间里的事实全文（`inner.facts_text`），末尾照旧是入睡 / 钟点那句 |
| 此刻、区域、设计、日记、日程、待办、已开始的调用 | 不列 | 评价用不到 |
| 基本动作、查询 | 不列 | M-3d 里思考调没有的工具 9 次的根因 |

“我写的”= 当前版本由表思考写入的（正文 §一 已定 ⑥）：与 `presets.starting_experiences()` 里同名那条逐字相同的就是启动给的原版，不列。

### C.5 回执与其余拒绝原因（规则码见正文 §3.0）

- 回执（心智原子，接纳与拒绝都带；只读查询与 say 不经接纳边界）：
  `{"ok": true, "id": "s12", "game_time": "day 2, 12:07"}`、`{"ok": false, "errors": ["…"], "game_time": "day 2, 12:07"}`。

| 规则码 | 原因 |
|---|---|
| `window_ended` | `day, from and to: day 2, 10:00–10:15 has already passed; it is now day 2, 10:27.` |
| `after_missing` | `after: there is no plan item with id 'x9'` |
| `after_closed` | `after: plan item t3 is closed` |
| `after_ancestor` | `after: t1 is the item this is a step of, and an item with open steps waits for them` |
| `command_calls` | `calls: …`（`formats.tree_problems({"do_in_order": calls})` 的现有原因，如没有一步、多于 40 步） |
| `command_decode` | `calls[2]: the world cannot read these arguments for dig_cell (…)`（`Acceptor._prepare_steps` 的现有原因） |
| `region_name_taken` | `name: 'the plaza' is already the name of a region I know (told to me when I arrived), columns (40, 12)–(52, 20).`（记下的写 `I noted it at day 2, 09:10`） |
| `way_unknown` | `name: there is no way named 'x' among my ways` |
| `version_mismatch` | `version: experience 'x' is at version 3, not version 2`（同 `store._experience_write` 那句） |
| `given_at_start` | `name: 'make_my_way' is a way I was given when I arrived, not one I wrote.`（正文 §一 已定 ⑥） |

- 使用时区域名不认识（不是接纳拒绝，是事实；沿用 `decide.NO_CANDIDATES_FACT` 的句式，日志 `reason_kind = region_unknown`）：
  `"Go home" has no values listed for the region to go to: "my plot" is not among the regions I know by name, so nothing was run.`
