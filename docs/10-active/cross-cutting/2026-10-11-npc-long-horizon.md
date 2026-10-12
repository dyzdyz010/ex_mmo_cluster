# NPC 长期自洽：续验契约与执行计划

## 2026-10-12 收口设计：角色卡、共享提示词与心智边界（待实施）

用户决定本轮先记录设计、整理并合并既有代码，不继续开发角色卡或归档修复。
目标是复用所有NPC的大部分提示词，让角色设定成为独立数据，同时保留每个永久cid自己的经历与成长。
采用 **共享任务模板 + 角色卡 + 个体运行状态**；模板按决策、反思等任务划分，建设者/探索者/学者使用同一模板。

### 职责与唯一来源

- **角色卡**：稳定身份/背景、兴趣、价值取向、长期愿望、表达与行为习惯，以及初始气质。
  第一版使用JSON与固定字段；NPC登记引用`card_id`，通用规则中移除写死的builder身份。
- **共享提示词**：解释观察、行动结果、工具、记忆与心理状态；按任务选择所需上下文。
  决策与Hindsight的mission/source_query从同一角色卡取得身份，不各自维护职业文案。
- **Life**：唯一维护当前情绪、人格倾向、逐人信任与事件证据；卡片初值只用于新个体构造，
  已有个体继续读取持久状态，重新载入卡片不能重置已经形成的性格与关系。
- **Memory / Hindsight**：保存真实笔记、计划、经历与派生认识；每个cid继续独立记忆，卡片不充当人生存档。
- **World / Body / Abilities**：继续拥有当前位置、库存、动作结果与可用能力；卡片中的职业叙述不授予技能或权限。

拟议卡片内容示例（不是已实现schema）：

```json
{
  "card_id": "zhiheng",
  "identity": "学者",
  "background": "喜欢通过实地观察理解周围世界",
  "interests": ["植物", "自然现象"],
  "values": ["亲自验证", "尊重邻居劳动"],
  "aspiration": "逐渐记录附近植物知识并与邻居分享",
  "habits": "观察足够就实践，遇到不懂的事情愿意请教",
  "speech_style": "简洁、具体、愿意分享发现",
  "initial_traits": {"caution": 0.2, "sociability": 0.5}
}
```

```mermaid
flowchart LR
  Card[角色卡] --> Compose[按任务组装上下文]
  Template[共享决策 / 反思模板] --> Compose
  State[Life 当前心理状态] --> Compose
  Context[观察 / 目标 / 记忆] --> Compose
  Compose --> Decision[LLM 行动决策]
  Compose --> Reflection[Hindsight 认识更新]
  Card -->|仅新个体初值| State
  Events[权威损坏 / 修复事件] --> State
  Decision --> Body[Body 权威动作]
```

### 心智现状与拟议调整

继续保留四类文字认识：self（自我与经验）、relationships（他人及关系依据）、world（地点与环境经验）、
commitments（约定及履行情况）。问题模板改为职业无关的问法，例如“我是怎样的人，从经历中学到了什么”，
身份来自角色卡，内容来自已记录经历。已有bank中的source_query不会因改代码自动更新；落地时应显式更新问题并刷新认识，
保留原始经历，不重建或清空人生库。

当前数值层只有anger/gratitude两种情绪（120秒半衰期）、caution/sociability两项人格倾向（初值0.2/0.5），
以及逐人trust。损害/修复关心构件由规则评价，对话只进入经历，不直接改数值。第三次起同类损害/帮助会引起缓慢人格变化。
LLM路径把这些状态放进提示词；Social/Tree路径才直接使用社交距离公式，本轮三人走的是前者。
当前没有好奇、快乐、恐惧等独立数值机制；第一版角色卡可用文字表达兴趣与习惯，不为此扩展人格维度。
完整行动流水、普通remember笔记尚未统一进入Life长期提炼，不能把一次记事视为四份认识已同步更新。

### 归档边界的后续修复

已复现的两个问题分别是：checkpoint把经历写入与四模型后台refresh一并等待600秒；flush遇busy在封尾前返回，
调用方却当已接纳且漏查pending_episodes。应由Life维护flush接纳与完成的明确契约，区分“经历已写入”和“认识已刷新”。
本轮保留失败原样，后续不以加长超时、自动重试或备用写入路径代替这两个边界修复。

### 后续最小验证与观察面

1. 角色卡组装：同一模板装入两张不同卡，决策身份与反思身份保持一致；复用现有Registry/Brain/Life入口验证，
   模型边界使用显式替身，不复制组装实现来判定自身。
2. 个体成长：新个体使用卡片初值；已有持久人格与关系在重新载入卡片后保持，名字/职业变化不换cid或记忆bank。
3. flush：先以正在refresh且存在不足3000字尾部的状态复现busy未封尾，验证真实Life与存储接缝，
   第三方慢任务使用可控替身；另核对“写入完成”不被后续认识刷新拖成同一完成条件。
4. 正常玩法：继续用三人短场景观察身份表达、交流、行动和经验复用；使用真实Body Outcome与已接纳Speech，
   不预写工具序列，不把理论归因、全量人格维度或长时挂机作为本轮验收条件。

CLI/trace应能读出永久cid、角色卡标识、任务模板标识、最终上下文，以及经历写入和认识刷新各自状态。
角色卡本身没有用户GUI入口要求；若后续增加编辑界面，再同步提供操作、自动化和CLI入口。

依据：[SillyTavern Prompt Manager](https://docs.sillytavern.app/usage/prompts/prompt-manager/)与
[Character Design](https://docs.sillytavern.app/usage/core-concepts/characterdesign/)提供角色资料与提示词组合的成熟做法；
采用其字段注入思路，第一版只实现本项目当前需要的固定字段，不引入整套卡片导入、宏语言或插件系统。
[Hindsight Mental Models](https://hindsight.vectorize.io/developer/mental-models)说明认识是后台预计算的文档；
本项目继续按已固定0.10.3适配器实际接口接入，现代文档中的新刷新能力不自动视为已部署。
这一拆分遵守本仓系统正交与SSOT约束：角色内容、行为能力、动态心理状态和派生认识各有唯一owner。

## 2026-10-12 邻里植物散步 happy path 实验

用户要求按实际效果判断经验和心智，不做严格理论归因；已授权设计后直接开始，只跑正常玩法。
本轮是既有三人连续人生的短场景：同一 Demo、同一身份/位置/记忆，不从空白世界重新初始化。
先给共同目标“各找一处近邻植物点，实地行走并分享”，再给目标“亲自去邻居介绍的地点，应用已有经验并记事”。
每段最多发起24次决策、600秒内发放许可，已发请求和动作等正常终态；两段后结束并恢复原登记。
每个模型自行选工具和顺序，等待沿用其真实时长及直接对话唤醒；阶段切换是新任务输入。
不注入故障、不重启恢复测试、不补资源、不改写心智、不做消融，不切换模型或自动重试。

观察只回答：是否实际行走、是否有已接纳交流、是否记下可用经验、第二段是否采用已有认识。
动作以正式Body同调用号Outcome和实际位置核对，笔记/对话人工阅读；不把完成请求当作完成目标。
复用Registry、Body.step、hourly_year.step/step_complete、checkpoint、原决策trace及CLI桥接；
只给step增加可选场景context，避免短实验冒用8760小时标签，新增接缝用例先RED后GREEN，相关12项通过。
依据为现有已实跑接口与本仓Testing.md的最小充分验证；不改变生产运行时或记忆算法。

```mermaid
flowchart LR
  A[各自实地发现] --> B[交流与记事]
  B --> C[亲自访问邻居介绍的点]
  C --> D[读取真实动作与经验表现]
```

入口：`python -B -X utf8 scripts/npc_life/happy_path.py --out .demo/observe/npc-happy-path-20261012/run-02`。
原始产物包含progress、protocol、execution、steps、model-results、两阶段checkpoint及独立bridge日志。
当前既有run-05已停止：269步、两个真实小时后模型返回capacity；本轮保留其证据，单独记录新实验。
以下按时间保留当时设计、启动与运行证据；最终行动与归档结论见本节后文，不以启动快照当作当前状态。

启动记录：run-01在准备阶段误等Life后台refresh，120秒超时，NPC决策0次，原始失败保留。
核对`Life.handle_call(:context)`可知已有cache即可读，后台刷新不属于决策readiness；只删除实验侧`job=nil`等待。
桥接按独立现有服务使用，不随每轮场景重建。run-01启动的桥接PID208556仍供本轮使用，模型已返回真实成功终态。
run-02驱动PID208168于2026-10-12 17:32:25（UTC+8）启动；不是重试失败的模型调用或重放旧NPC动作。
该轮实际状态读取`.demo/observe/npc-happy-path-20261012/run-02/progress.json`。
17:33首个真实决策已完成：LifeBuilder自主say分享旧的枫木/蕨观察与行走经验，同调用号Body结果done。
这是本轮已接纳交流证据，不能把其讲述的上轮行走计为本轮新移动；后续轮转继续。

行动结果（2026-10-12 17:52）：两段共30次真实决策，3次移动全部到达并停稳；
6次观察、6次记事、6次接纳发言、1次会话过期拒绝、7次计划更新、1次自主休息。
知衡听取南侧介绍后实地到访，LifeBuilder听取东侧介绍后实地到访；松岚第一段已实走东侧，
第二段完成分享与记事后休息，没有再访问第二处。三人均完成本轮实走、观察、分享、记事。
知衡四份认识在行动期更新，纳入本轮提议；其self仍自称builder，现有统一建设者问题模板不匹配学者身份。
这说明已有可用的经验复用与认识更新；本轮没有数值人格/信任变化，也没有采集、建造或完整往返路线验收。
决策共1,433,907 token，约20分钟；这是决策usage，不含记忆后台，不换算虚构金额。
行动汇总在 `run-02/action-summary.json`，可由 steps 与阶段检查点复核。
最终18:02:45（UTC+8）以 `failed_cleanup` 结束：记忆归档等待600秒超时，未生成final checkpoint；
三人已通过实际Registry核对恢复原登记、均未启用Life。不能称整轮无错误完成或记忆已全部归档；
已有30步与阶段检查点保留，不追加重试。

19:05只读诊断确认：经历落库后自动接续四模型串行刷新，驱动却把所有job归零放进同一个600秒完成条件；
建设者最后的认识刷新18:04:42完成，超出18:02:45收尾期限。另查松岚flush遇busy未封尾，
6条2404字符经历仍持久保存在pending而未送入Hindsight；驱动忽略busy状态且漏检pending_episodes。
完整证据、两个问题的边界及当前心理状态生效路径见[交接页诊断](2026-10-11-npc-next-session.md)。
本次未实施修复或追加模型调用。

## 2026-10-12 小时内连续自主决策修正（历史记录）

当前轮为run-04，详见[交接页首](2026-10-11-npc-next-session.md)。
用户再次确认预算全部放开，并要求像真人一样思考；此前run-03每人每小时一工具调用是驱动缺陷，
不能把set_plan完成当作计划已执行。真实请求有完整40个工具，故排除接口列表漏注入。

修正契约：小时是时间观测桶，不是动作门禁；动作同调用号终态后，继续公平三人轮转。
仅模型wait推迟该角色下一许可，新直接发言通过正式Dialogue契约唤醒。
同小时可以多次思考与行动，sequence/tag独立；模型自由选择工作、交谈、记事或休息。
小时内无新增决策也可以是真实休息，不强制每小时醒来一次制造活动。
每步与真实hour完整度仍分别记录，不加速身体、不制造饥饿或补料、不编造年度完成。

最小验证在驱动测试中证明set_plan → 三人轮转 → 同小时同人新许可，并验证wait延时及独立tag；
真实启动建设者survey/Body done，原计划、记忆、库存保留。run-03及其成本不覆盖。

## 2026-10-12 三角色真实小时新轮（当前执行）

当前实际接管、身份、后端、失败及成本入口见 [交接页首](2026-10-11-npc-next-session.md)。
新轮 `npc-three-life-20261012/run-03` 目标8760真实小时，已经开始，尚未完成。
共同目标在 `hourly_year.py:LIFE_GOAL`，三个兴趣角色在 `ROLES`；不强制调用say、采材或建造。
原两人既有心智保留，新学者通过正式Registry取得永久cid，由Life建立自己的bank。

契约：三人各一次真实决策完成且同调用号终态可信，计一次决策轮；真实小时边界经过后才计完成小时。
先手每小时按三人循环轮换。记忆/模型/基础设施失败停止，玩法拒绝保存原样，停止后恢复原登记。
前提：固定27361/27363 Demo与18908 Hindsight，原镜像、DB、卷和存档不变；本机官方CLI复用现有登录。
观察：progress的轮数/实际小时/活跃cid/usage/心跳，steps的调用与终态，checkpoint的三个bank和World。
范围：真实CLI、Hindsight抽取及正式Npc模块接线；不验证UE复制、不加饥饿模型、不加速物理、不声明全年完成。

决定依据：固定Scene `Movement.Player` 的1Hz身体推进与Life `State.view`的事件时间锚说明小时标签不具备加速语义；
采用真实小时避免另造时间真值，代价是8760小时需要365天在线。
CLI接口按 [官方非交互文档](https://learn.chatgpt.com/docs/non-interactive-mode) 的 JSON事件与schema输出实现，
认证按 [官方登录文档](https://learn.chatgpt.com/docs/auth)由CLI自己读取；
Hindsight消费契约直接核对固定容器 `openai_responses_llm.py`，桥接使用既有正式Responses译码与Body管线。

```mermaid
flowchart LR
  H[真实小时边界] --> R[三人轮换 / 正式手动许可]
  R --> N[Registry / Body / Runtime / Llm]
  N --> C[本机官方 Codex CLI / 指定模型]
  N --> W[既有 World 权威结果]
  N --> M[三个独立 Life / Hindsight bank]
  M --> C
  W --> E[同调用号终态与检查点]
  H --> P[真实完成小时 / 决策轮数分开]
```

## 2026-10-11 追加：8,760 小时自主生活实验（10月12日因余额不足停止）

最新核验（2026-10-12 06:54，UTC+8）：`run-01`于03:44:54以 `failed` 结束，已完成1,689小时、3,379步；第1,690小时LifeBuilder请求收到HTTP403 `insufficient balance / billing_error`。实验侧无token上限，阻塞来自外部服务余额。PID199876已退出，两NPC登记已恢复settler，服务容器仍在；最终检查点 `checkpoint-01689-final.json` 已保存且无待存片段、话语或Life错误。没有新发言（say=0），3,301次等待；决策58,886,946 token、记忆新增404,386、预检4,278，失败请求usage未知1次。全年和自主交谈尚未达成。继续前需恢复服务余额并明确第1,690小时半完成步骤的续接；当前驱动无原地resume，不能覆写旧run或重置计数。以下保留启动与执行证据。

### 2026-10-12 结果复盘：等待与驱动力

复核命令：`python -B -X utf8 .demo/observe/npc-year-20261011/analysis-01/audit.py`。离线读取3,380条模型结果与完整请求、3,379条步骤以及72个检查点；按hour/cid关联请求、usage、工具及同调用号Body终态，检查唯一性与1–1,689回合双人完整性，保留第1,690回合只有松岚完成的事实。所有断言通过；汇总与原始文件SHA256见 `analysis-01/results.json`。本次分析未调用模型、未重启实验、未改写原始证据。

**实际行为**：等待3,301次，占97.6916%；其余78次动作均有对应done，分别为look48、inspect26、set_plan2、survey1、move_to1。LifeBuilder共1,689次决策，45次look、26次inspect、1,618次wait，位置与当前计划未变。松岚第73–76回合自行制定勘察休息地点计划、勘察、移动约3.2045米并保存新计划；此后77–1,690连续1,614回合wait。没有say、remember、采集、建造或进食调用。这说明本轮出现过有限的自主目标与执行，但没有持续生活活动或自主交谈。

**排除简单输入缺失**：全部3,380个请求都包含say工具；除第一条外均收到另一NPC的entity，距离0.6801–2.5710米，处于工具声明的12米范围内；heard始终为空，无memory_error/working_memory_error。由此排除“全程没给聊天工具”或“一直看不到/超距”的解释；没有实际say调用，因此不能用本轮验收发言传递链路。

**驱动力证据与边界**：初始计划明确规定“无新问题或异常时长时间等待”；构件保持完好，所有材料快照的seq均为48且逐项相等。两NPC的关系、人格canonical记录和旧笔记未变；每个请求里的life均100、protein_g均100。当前 `Life.State.behavior/3` 的sociability只调节活跃感激时的接近距离，未定义按独处时间累积的社交需要；提示词也明确沉默是合法选择。松岚的新计划收束为“安静休息，有人交谈时回应”。这些证据支持“已满足的守望目标、变化稀少的环境与有限的持续需求使等待稳定延续”，但没有做对照消融，不能确定各因素贡献或归因于模型本身。

**时间口径必须收紧**：实际运行17,941.64秒（4小时59分）；1,689仅为按小时命名的决策采样回合。manual step设置dirty并发放新许可，未推进World/身体/Life统一时钟。3,286次wait请求3,600秒，但从wait返回到同角色下一次请求的真实间隔中位数仅3.8485秒（3,300个可观察间隔）。这属于外部回合驱动，与自动模式wait到期不同；不能将编号换算为真实70天生理、社交或世界演化。原实验设计不足以验证用户所需的长期生活，不能只靠多跑回合补足此缺口。

**记忆与成本**：首个检查点双方各有4条既有pending episodes，首日flush后归零，Hindsight文档分别4→5与1→2；第24回合检查点到结束用量没有继续增长。检索中新增可见speech片段的事件时间早于本轮启动，不计为本轮新交谈。决策token为输入58,813,940+输出73,006；输入已含缓存14,354,688（24.4069%），不能重复相加或直接换算金额。返回wait的请求占决策token的97.5636%，单次成功决策平均17,427.33 token；输入平均约37,554字符，主要是检索记忆和四类摘要。加记忆404,386与预检4,278，本轮已知合计59,295,610 token，另有1条失败usage未知。高消耗主要落在重复决策，不能据此宣称获得等量新经历。

后续应先验证时间契约与目标/需求如何触发变化，再决定续跑范围；目前仅记录待验证方向，没有新增生产需求模型或强迫NPC发言。现有证据支持的是调用持续性、当前小范围动作关联及错误后停止，不是完整长期生活验收。

用户本轮明确要求至少一年、预算全部放开、`gpt-6.1-sol` / `medium`，并选择按小时推进，共 8,760 小时。新授权覆盖旧 3,000,000 token 上限；历史实际 2,010,947 不清零。指定模型的真实 Responses 工具预检成功，新增 4,278 token，证据 `.demo/observe/npc-year-20261011/preflight-01/`。

本轮契约是 **Test-only 小时决策采样**：同两个永久 NPC、同 World/库存/意图/记忆连续演进，每小时每人一次模型决策，轮流先行动；模型自由选择交谈、工作、查验、记事或等待。非等待动作必须取得同一调用号的 Body 终态，才能记为完成该小时。拒绝动作作为真实经历保留，不伪装成功；基础设施、模型、记忆写入错误停后续。没有玩家代答、代修、补料或脚本编造一年经历。

模拟日历只表示决策机会；World 物理、原事件时间与 Life 情绪衰减仍使用真实时钟。因此不能从本轮结果推出全年物理/饥饿/情绪演化或完整生存验收。此边界同时进入模型上下文和进度产物。生产默认自动后端不变，小时驱动经正式 Registry → Body → Runtime → Llm 手动 step 接缝，复用原请求、工具译码和命令流水。显式 `max_requests_per_hour="unlimited"` 解除预算；不通过反复重启重置滑动窗口。

依据：现有 Brain 行为契约、Runtime 的单终态、Registry 的登记接纳边界；[Erlang 消息顺序保证](https://www.erlang.org/doc/system/ref_man_processes.html#signals)用于单发送者 step/结果关联；[OpenAI 模型规范](https://developers.openai.com/api/docs/models/gpt-6.1-sol)确认 Responses 函数工具及 medium。本轮只增加当前实验所需的单许可控制，不另造模型循环、世界 owner 或通用时钟框架。旧严格计数预检失败继续保留；无总额上限时不再依赖它作为开跑条件，仍记录全部实际 usage。

观察与验证：`progress.json` 分开记录已完成小时、目标、真实时间、模型 usage 和失败；每步保存 hour/cid/tag/response/命令号/Body 终态；每模拟日保存 Life/World/记忆用量检查点。测试范围是手动模式无额外请求、一次许可对应一次结果、错误不重试、显式无限预算与原有限预算、错误/缺失/错配终态不得推进小时。模型使用替身的离线测试不称真实模型验收。真实首次启动后确认双方模型调用及实际对话，再把后台任务的 PID、命令、版本与输出目录写回本节。一年尚未完成。

```mermaid
flowchart LR
  H[小时驱动 / 8760机会] -->|一次许可与模拟日历| B[正式 Body / Runtime / Llm]
  B --> A[既有能力库与 World]
  A -->|同调用号终态| H
  A --> L[Life 与持久记忆]
  L --> B
  H --> E[逐步证据与每日检查点]
```

启动证据：2026-10-11 22:45（UTC+8）启动 PID199876，`run-01/progress.json`为实时进度；首小时两人均真实 `look` 并取得对应 `Body done`。正式镜像 `voxim-server:20261011-npc-year-manual02`（image ID/source hashes见 `build-02/manifest.json`）；服务端与18908记忆配置均实际核验 `gpt-6.1-sol / medium`，`wiring-01/stored-before.json`与after逐项相等。模型调用与usage在 `model-results.jsonl`，动作/对话证据在 `steps.jsonl`，完整无凭证请求在既有server挂载的 `year-run-01-requests.jsonl`。

首次行为观察：第1至24小时共48次决策，2次 `look`、46次 `wait`，没有新增自主交谈。实际请求输入中双方能够看到彼此，旧 `current_plan` 都倾向于没有新情况便等待；这与所见行为一致，但不是严格因果证明。保留旧计划和负面结果，不为制造聊天成功而中途改写记忆。第24小时须在每日记忆检查点完成后才计入 `completed_hours`；每小时决策数不能冒充完整生活活动。

首次跨日验证：22:54:38（UTC+8）写出 `run-01/checkpoint-00024.json`，双方 Life 无错误、无在途 job、无待存片段或话语；随后继续小时25及以后。22:55:10快照为26小时完成、53步，决策711,902 token、记忆新增404,386 token（记忆计数按日更新）。只作为当时快照，最新进度仍读 `progress.json`；证据 `validation/startup-verification.json`。后台 PID199876 在快照后仍存活。

审查修正：manual读取记忆失败在HTTP前终止；`remember/set_plan`的明确存储故障不能按普通玩法拒绝放行；空工具应答的原response/usage保留；终态等待失败也计已发生请求费用；失败尾部使用独立checkpoint文件，不覆盖旧结论。Python6个反例/判定测试通过，生产Brain最终35个用例覆盖（34一次通过，1个异常类型夹具期望修正后定点通过），LifeRegistry8个用例此前通过；原始日志与范围见 `validation/`。首轮镜像build-01未部署，正式仅部署审查修正后的build-02。尚未完成全年，不以局部测试或短对话扩写结论。

> 用户要求继续验证并修复，直到得到可复核结果；工作仅在本 worktree。起点 `c6c6dabd`。本页是续验的 spec 与执行计划，继承 [人生闭环](2026-10-11-npc-life-loop.md) 和客户端 `Docs/Gameplay/NpcEvolve/NextLoop.md`，不改写前轮失败。

## 契约

“长期自洽”本轮可证伪定义：同一 NPC 的当前意图跨决策/进程重启延续；关系与人格只有权威经历能改变，情绪随经过时间衰减；当前 World 与旧记忆矛盾时采用 World；同 World 下互换自传中的伤害者/帮助者身份后，选择应随经历改变；模型输出最终经正式 Body/World 执行，不能把计划文字当完成。有限场景通过不推导无限期或完整人类生活保证。

当前发现：Life 模式完全替代 `Memory.context`，导致普通 `remember` 笔记不进入下一轮上下文；最近 8 个 Outcome 也不构成持久计划。笔记最多 200 条、仅取最近 5 条，本来就不能承诺当前意图永不被挤掉。

最小修复：由既有 `Memory` 能力 owner 提供 `set_plan(text)`，保存唯一 `npc_memories` 工作记录 `kind=intention/key=current`，最多 1500 字，空文本清除。它是 NPC 的主观打算，可自由更换，不是任务进度/人格/世界状态。每次决策现读当前计划；Life 模式另读最近 5 条笔记，不调用词法搜索，Hindsight 仍是缓存四模型 + 一次 recall。没有新表、进程、规划框架或新 World 真值。普通 remember/recall/search_memory 保持原语义。

依据与取舍：
- [Generative Agents §4.3](https://arxiv.org/html/2304.03442v2#S4.SS3) 区分计划、观察和环境变化后的重规划。采用持续可见的意图，不照搬日程分解或其检索算法；当前玩法只需一个可覆盖计划。
- [AMA-Bench §3](https://arxiv.org/html/2602.22769v1) 将记忆验证分为时间召回、因果前提、状态更新与概括。本轮采用状态更新/先决条件的反例和消融，不引入论文的另一套记忆框架。
- 持久化复用 `DataService.NpcMemory` 的既有 `{cid,kind,key}` 唯一行契约；非 note/event 工作记录按键覆盖。Hindsight 仍锁定 0.10.3/flashrank，数字永远查 World。

```mermaid
flowchart LR
  W[World 当前事实与权威 Outcome] --> B[Brain 选择]
  H[Hindsight 模型缓存与一次召回] --> B
  P[Memory 当前计划与近期笔记] --> B
  S[Life 显式人格与衰减情绪] --> B
  B --> R[Runtime / Body]
  R --> W
  R -->|set_plan 主观意图| P
```

## 全局约束与观察面

- 不触及主树，不用 18888/18898，不复活已停止的 Concordia 实验；沿用独立 18908 实例，真实 Demo 同 cid/world/bank。
- 不写入 LLM key，日志只保存脱敏请求体、响应工具、usage、World/Body Outcome 与时间。所有新观察产物在 `.demo/observe/npc-long-horizon-20261011/`。
- 先自动测试，再固定模型实验，再必要的短客户端验证。服务端受控时钟承担 30 天/重启验证；不挂机 30 天、不用改变真实服务时钟模拟。
- 模型实验预设上限：12 次配对选择 + 最多 24 次真实自主决策，共 36 次；Life 每小时上限仍 60。总模型 token 计入用户 200 万额度（此前本任务约 712464）；遇到失败保存首次结果，修复有新版本依据才重跑。
- 可观测面：cid/world/版本、当前计划与写入/清除 Outcome、决策上下文 hash、记忆处理方式/错误、模型工具与 usage、权威终态、心智 canonical/cursor/cache、控制时钟/实际时间分列。

## Task 1: 持久意图与 Life 决策输入

**Files:** `npc/memory.ex`、`npc/runtime.ex`、`npc/brain/llm.ex`、最近 README；`npc_memory_test.exs`、`npc_life_test.exs`。

**Interfaces:** `set_plan(text)` 能力属于 memory 组，映射 `%{verb: :set_plan, text:, id:}`；Memory 执行唯一写入/清除，返回正常 Outcome。`Memory.working_context(memory,cid)` 返回 `current_plan`（body 或 nil）、`recent_notes`（最多五条带时间记录），失败返回 `working_memory_error`，不得伪装空计划。Llm 在原记忆上下文外合并该字段，不改变 Life 的一次召回与缓存职责。

1. RED：正式 Llm 的 Life 决策必须收到经 Memory 写入的计划与近期笔记；不许触发词法搜索。新增计划工具接纳/覆盖/清除/角色隔离/真实 DB 失败；201 条普通笔记不能淘汰当前计划。先运行并记录真实失败。
2. GREEN：按上面边界实现；提示明确区分意图、历史和 World，遇到冲突更新计划，动作完成只认 Outcome。
3. 最小回归覆盖 memory/Life/Llm/Runtime 的现有直接测试，不扩大到无关全仓。文档同步、提交。

## Task 2: 受控时间与重启的组合验证

**Files:** Life 集成测试，必要的 Test-only 验证脚本；不新增生产时间开关。

**Interfaces:** 使用现有 `Life` 注入时钟，真实 World/Body/NpcMemory，外部 Hindsight 在自动化接缝测试中用明确替身；纯规则试验与真实权威经历分开标注。

1. 真实 World 伤害/帮助后将 Life 观察时钟推进到 1、7、30 天，canonical 不被观察写坏；重启 Life/Body 同 cid 后关系/人格不重置、情绪不复燃、计划不丢，重复旧事件不重复评价。
2. 通过正式 Runtime 命令覆盖/清除计划，验证下一轮上下文收到当前意图。无效参数/存储失败的旧计划必须保留。
3. 测试旧实现已满足的长期状态不变量可以直接通过，不为制造 RED 修改正确代码；新增能力的 RED 由 Task1 提供。保存命令/版本/结果。

## Task 3: 真实选择、正式 Demo 与最终审查

**Files:** `scripts/npc_life/` 的 Test-only 续验入口与说明、本页进度。

**Interfaces:** 使用生产 `Llm.body`/Http 与正式 Brain/Body；仅消融分支是 Test-only，不写回真实 NPC 心智。沿用真实历史、四模型和一个召回；World 观察同源。保存首轮所有样本。

1. 冻结 6 组同 World 配对选择（原自传/自传身份互换，共 12 请求），保留可选能力，不给唯一正确工具、角色标签或硬编码正确答案；判断依据在请求前落盘。失败不得从统计中删去。
2. 自主维护目标只给目的，不给动作序列；最多 24 请求观察自选计划、实际动作/等待和受拒后的调整。用真实 World/Outcome 判定，不按模型自述判成功。
3. 冻结提交构建正式 release，升级本任务唯一 Demo、检验同 cid 持久状态。客户端只在需验证新可见行为时启动短场景（每场景约 10 分钟），不重复前轮整套伤害循环。
4. 最终独立代码审查、针对 Important 的红绿修复、最终证据索引；区分已实现/已实跑/已验收/未证明。保持工作分支，不合并推送。

## Review Focus

关注计划文本被误当 World 真值；当前计划意外受普通笔记淘汰；读取失败变成 nil；Life 多次召回/模型刷新落入决策热路径；新增工具没有经过 Runtime；控制时钟证据冒充真实长时运行；配对输入泄漏正确答案；失败样本被隐藏；服务升级版本与证据不一致。

## 进度与裁定

- Task3 开始前发现并用两个反例确认：等待与请求期间的新心智评价不能可靠触发后续选择。沿用已有 Brain 的 dirty 义务，比较权威 `mind.evidence`（不用随时间变化的 emotion/view），旧响应保留请求期间的新 dirty。依据为上文环境变化后重规划及本仓正交纲领“时间性不变量由 owner 持续维护”；无新计时器或重试框架。

- 2026-10-11：完成现状/一手依据调查，开始 Task1；尚无新验收结果。
- Task1：已有笔记遗漏反例 RED；新增能力 0/3 RED，owner 隔离反例 RED；最终 memory/Life/Llm/skill-runtime 59 项通过（validation/task-1-final.log）。中间失败保留：新工具表旧断言、重启测试未等旧 Life DOWN、Wilderness plan/current 键冲突。当前意图改为 intention/current；现有蓝图保留。Windows 本地无 quicer 的既有编译警告不等于正式 release 验证。
- Task2：真实 World 三次独立伤害、同格继续击打至破坏后他人补回；Life 观察时钟推进 1/7/30 天，重启 Body/Runtime/Life，canonical 与计划严格保留，情绪不复燃；Runtime 修改/清除计划和真实 PG 拒绝写入保留旧意图通过。Life+Memory 16 项通过（task-2-final.log）。首轮测试在 Runtime 首次 Observation 前发命令，被正确 invalid_session 拒绝；已改为等真实观察就绪。该结果是受控时间持久性测试，不是 30 天模型连续活动。
- Task3：等待/在途请求两个唤醒反例 RED，修复后 Llm/skill-runtime 47 项通过。配对实验预登记改为真实经历/经历中互换伤害者与帮助者身份（仍6组12请求），World/工具/人格/目标不变，仅改测试副本的自传内容。该实验检验心智关系与 Hindsight 组成的自传上下文整体，不单独归因 Hindsight；不会写回真实 bank 或 canonical。
- 最终独立审查：生产变更无 Critical/Important；实验生命周期有两项 Important。先核对现有 R7 `VoxelB3LiveInputs.cpp` 的命名 `@await_peer token` 契约，再在本 worktree 驱动复用它：本轮 A 的意图、结果、同 actor/cell/txn 的 World destroy 全部一致才放行 B；拒绝、只有旧历史、尚未破坏、角色/格错配和超时均不能放行。A 同样等 B 的权威 build 后才结束，双端保持原会话。来源为既有 R7 命名 barrier 与 `Testing.md` 首失败停止规则，不增加客户端协议。
- 清理审查修复：最终观察、恢复 settler、停止 trace、保存尾部证据独立尝试；恢复失败显式记录并停用本任务 NPC 登记，防止持续付费；原始运行异常继续上抛。测试依赖是完全离线进程/网络替身，保留真实时间轴、日志解析与门禁；不触发真实模型。初次 1/8 GREEN（2 failures/5 missing implementation errors）为 RED，修复后8项通过；接线测试发现 World 返回字段是 cursor 而非 seq，再RED/GREEN，最终10项通过（validation/review-final.log）。当前真实场景发生于修复前，其正确事件不代替失败门禁测试；修复后不重复消费模型或重开 UE。

## 本轮验收结论（2026-10-11）

本轮最小契约通过：同一 NPC 可以在维护构件的目标下自行制定、保存、修订意图，经历会改变其选择，当前 World 会纠正旧计划，重启不抹掉身份、关系和经历。**尚不能宣称完整人生、无限期自主生活或持续生存能力已经完成。**

### 已实现

- 持久意图 `set_plan` 与 Life 决策的近期笔记输入；意图和蓝图分别由不同工作行拥有，普通笔记淘汰不会删除意图。
- 等待或请求在途期间的新权威评价能唤醒后续决策，旧响应不会覆盖新消息；单纯情绪衰减不触发付费请求。
- 仍为 Hindsight 0.10.3 / flashrank、批量片段、四模型缓存 + 一次情境 recall；所有动作与数字经既有 World/Body authority。

### 已实跑、已验收的证据

观察根目录：`.demo/observe/npc-long-horizon-20261011/`，最终索引 `final-01/manifest.json`。

| 契约 | 结果与证据 | 适用边界 |
|---|---|---|
| 30 天与 owner 恢复 | 真实 World 三次独立伤害及修复，受控时间推进1/7/30天；canonical、当前计划与缓存保留，情绪衰减；`validation/task-2-final.log` 16项通过 | 安静时间经过与持久性，非30天连续模型活动；外部记忆依赖为声明的替身 |
| 经历影响选择 | 6组12请求全部完成；每组原/互换自传的合作意向跟随帮助者、戒备跟随伤害者；`pairs-results-02/human-review.json` | 冻结 World 下的意向选择；没有执行合作动作；不能单独归因 Hindsight，因为显式关系一并互换 |
| 正式自主维护 | 22个真实模型请求均结束；13个 Body done、2个 no_path rejected、7个 Brain 本地 wait；`audit-01/verdict.json`、`decisions.json` | 约7分3秒的一个维护片段；没有自主采材/重建成功，玩家完成修复 |
| 当前事实纠正旧计划 | look确认缺失→自行保存采材修复计划→两次路径拒绝→重新look确认材料19/帮助者放置→保存取消采材修复的新计划和笔记→wait；原意图与新意图均有正式写入 Outcome | 不是模型文字自报完成；不把wait算World动作，不把寻路拒绝算成功 |
| 双端真实输入与复制 | A三次准星击打对应43/44/45，B准星放置对应47；按本轮鉴权cid、client_seq、result、World actor/cell/txn逐笔核对，两端全部收到；`clients-01/`、`audit-01/` | 双端启动到退出约229.3秒，约3分49秒；站位为Test-only夹具，不宣称移动/流送验收。原驱动的失败门禁缺陷已离线修复，不改写原实跑版本 |
| 新经历进入认识 | 本轮2条经历批为第3个fragment/document；自动慢刷新四模型，人工核对最新08:41伤害/08:42帮助及“没有明确承诺”；`memory-01/` | Hindsight帮助事实仍有+10ms派生偏差；World原始时戳与状态是权威。旧饱和信任文字仍写changed，不视为数值变化证据 |
| 完整服务冷恢复 | 实际stop/start同一个Demo容器；同cid/world/bank；canonical、四模型缓存、模型自写计划与笔记严格相等，情绪继续衰减；`cold-restart-01/verdict.json` | 本次只重启整个服务端，Hindsight保持运行；前轮两者冷重启证据仍单独保留 |

首次配对调用因为 Windows 命令行过长失败（WinError206），发生在发送HTTP之前，0模型请求；改为本轮挂载目录传递无凭证请求体后运行完整12请求，旧目录与日志保留。正式 live 无请求错误、无尾部悬挂请求。两次 no_path 是实际能力限制，NPC 没有声称已抵达，也没有循环重复同一路线。

最新真实关系仍为 A=-1、B=+1；伤害/帮助评价数由6/6到7/7；谨慎特质0.36→0.40。数值只用于调试与验证，不作为产品UI。

### 版本、命令与成本

- 生产源码冻结 `c9bfe2249dfde2fa36d7c9dad63d7c9231479450`；正式 release 镜像 `voxim-server:20261011-npc-life-c9bfe224`，image ID `sha256:aae0e422df7c7d41f902e13e5de8496fa0d6a91fdb6455bdb8c271c6a4d4d603`。唯一 Demo 升级与加载身份在 `upgrade-01/`，本轮服务冷恢复共用 BEAM 摘要一致。
- 客户端/模型实跑驱动 `0843fa0e`；最终审查修复 `4b06b564` 仅改Test-only驱动、测试与文档，生产目录相对c9无变化，不重复构建相同运行时。工作保留在 `capability-library-20261007`，不合并、不推送、不改主树。
- 最小相关验证：`mix test --no-start test/gate_server/npc_memory_test.exs test/gate_server/npc_life_test.exs test/gate_server/npc_brain_llm_test.exs test/gate_server/npc_skill_brain_test.exs` 对应Task1 59项；Task2 Life/Memory 16项；Task3 Llm/skill-runtime 47项；各日志保留实际选取命令和RED/GREEN。这些有重叠，不能加起来当独立测试总数。
- `python -B -m unittest discover -s scripts/npc_life -p test_long_horizon.py`：最终10项通过；`python -B .demo/observe/npc-long-horizon-20261011/audit-01/verify.py`：离线真实日志对账通过。驱动与裁决源/hash保存于产物。
- 续验模型消耗：配对106,584 + 自主245,363 + Hindsight新增169,445 = **521,392 token**；加前轮712,464，累计 **1,233,856 / 2,000,000**。本轮决策请求34次（12配对+22现场），上限36；Hindsight后台模型请求单列入token，不冒充34次之内。没有价格输入，不虚构金额。
- 结尾NPC登记已恢复常驻settler，trace停止、临时客户端退出；持久意图与新经历保留。没有留下无界付费模型挂机。

### 仍未证明

跨月连续自主活动、多目标/承诺冲突、资源耗尽后的持续生存、复杂关系长期修复与完整人生均不在本轮已验收范围。人格与情绪目前仍是已批准的最小维度集合。本轮证明的是这些基础状态和当前意图能持续自洽、在现实反证下修订，不能把有限证据扩大为永不失常。

## 阶段后端接入与下一会话（用户追加）

用户要求先把成果做成独立后端，再新开会话继续连续自主生活、自给自足与人格模型。本轮有限接入采用 `Registry.brain/2` 已有组合入口：新增持久登记名 `life`，复用已验收的 `Brain.Llm`/`Life`/`Memory`/`Body`，强制Life配置与既有1..60/h额度，不创建第二套调度器或World owner。省略life从环境取Hindsight地址；显式false拒绝。依据为本仓Registry工厂、Body生命周期及系统正交/SSOT约束；此次不改变它们的边界。

观察面：`Registry.list/0` 的brain必须是life；`Life.observe/1`有同cid/bank/state/cache；`Memory.working_context/2`保留计划和笔记。最小验证为新登记名/缺配置/禁止关闭/额度/等价profile反例，原Registry真实PG/Body集成回归，以及正式release内同NPC接入。聊天经代码和既有测试核实仍为stub（`say -> chat_unavailable`，LLM不投影）；曾有npc-dialogue-rag工作树也仍是相同占位，不能宣称聊天已经完成。

验证产物：`.demo/observe/npc-life-backend-20261011/manifest.json`。配置RED5项中2项因life入口不存在失败；实现后LifeRegistry+Registry共17项通过。现场驱动切换独立life登记名，入口反例先RED10项2失败，修复后10项通过。正式release源码9b52cde9构建104.15秒后升级同Demo，canonical不变；LifeBuilder已登记life，实际首轮look/Body done，旧计划与笔记进入首轮上下文。新增9,755 token，累计1,243,611；目前life临时1/h，后续生命周期交接新会话。下一会话交接见 [NPC 连续生活接力](2026-10-11-npc-next-session.md)。
