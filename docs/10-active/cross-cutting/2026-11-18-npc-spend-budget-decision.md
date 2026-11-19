# NPC 每天模型花费额度：产品侧怎样连 Hindsight 一起兜住（2026-11-18）

分类：生产化入口的决策稿（只定计量口径、所有权、超额后的拒绝顺序与测试矩阵，不调取值）。状态：**用户已定（§6 Q-1–Q-6，2026-11-18）；T1–T3 已实施、独立评审修正已合入（2026-11-19，§7），T4 真实短场景待做。**
上游：[`2026-11-18-npc-scale-and-qinglan-entry-decision.md`](2026-11-18-npc-scale-and-qinglan-entry-decision.md) §3（依据）、§7（D-3：进青岚首批 3 人，
每天模型花费上限 **$50**，用户 2026-11-18 定；超出即拒后台请求，要连 Hindsight 自己的用量一起覆盖）。进度见
[`2026-11-11-npc-coordination.md`](2026-11-11-npc-coordination.md)。

## 1. 目标

进青岚之后，NPC 一天（自然日）花在模型上的钱不超过用户定的上限；到上限后先停“没人在等”的工作，NPC 仍能被看见、能动、能回话。
这是 SRE *Handling Overload* 的“按客户定额、过载时按重要性先拒低优先级请求”在本仓的对应物（依据见 §3）。

不做：调取值（阈值、刷新间隔、思考档位都是后调项，本稿只给读数与推断）；NPC 之间分配额度（首批 3 人共用一个全局额度）；
改 Hindsight 源码或镜像。

## 2. 现状事实（各附证据）

### 2.1 钱花在哪：M-4 读数（`scale3-direct-02`，3 人、37.4 min、直连 deepseek-flash，按高峰价折算）

价目同扩人数稿 §7（DeepSeek 官方价目 2026-11-18 核对：每百万 token 入未命中 $0.3 / 命中 $0.006 / 出 $1.2，思考按输出计）。
产品侧来自 release 日志的 `npc_model_request` 回执；Hindsight 侧来自它自己的 `llm-requests` 追踪（`hindsight-llm.json`）。

| 来源 | 操作 | 车道 / 谁触发 | 37.4 min 花费 | 每 NPC 每天（全高峰） |
|---|---|---|---|---|
| Hindsight | 认识刷新 `refresh_mental_model`（32 次收尾 + 183 次工具调用） | 产品 Life 后台槽 | $0.639（48%） | $8.2 |
| Hindsight | 巩固 `consolidation`（78 次） | Hindsight 自己排队（每次 retain 后入队） | $0.347（26%） | $4.5 |
| Hindsight | 写入抽取 `retain_extract_facts`（140 次） | 产品 Life 后台槽（同步） | $0.134（10%） | $1.7 |
| 产品 | 活动选择（100 次，入 47.8 万，**缓存命中仅 128**） | 交互 | $0.150（11%） | $1.9 |
| 产品 | 说话（18 次） | 交互 | $0.033（2.5%） | $0.4 |
| 产品 | 反思（18 次）+ 日计划（3 次） | 后台 | $0.033（2.5%） | $0.4 |
| 合计 | | | $1.34 | $17.2（加权 $10.4） |

推论：**产品后台车道只占 2.5%**。若“拒后台请求”只拒产品后台车道，额度几乎拦不住任何花费；真正的大头（84%）是 Hindsight 的刷新、巩固与抽取——
它们在概念上都是“没人在等”的后台工作，只是不经产品的出站车道。额度必须能停住它们。

### 2.2 Hindsight 侧的控制面（0.10.3，容器内源码 `/app/api/hindsight_api/`，2026-11-18 只读核对）

- **没有花费 / token 预算，也没有按库配额**：只有进程级并发信号量 `HINDSIGHT_API_LLM_MAX_CONCURRENT`（默认 32，`config.py:163`）与按操作的并发项（默认不设）。
  有一个可装自写 Python 的 `OPERATION_VALIDATOR_EXTENSION`（文档原文 “Quota enforcement (pre-operation)”），但它对巩固的 `validate_consolidate` **没有调用点**，拦不住巩固。
- **认识刷新完全由产品触发**：产品建心智模型时写了 `refresh_after_consolidation: false`、不设 cron（`life/hindsight.ex:338-358`）。
  Life 在“有新写入（`dirty`）且距上次刷新 ≥ `@refresh_ms` 600 000 ms”时起刷新槽（`life.ex:1858-1860`），一次刷新串行刷 `self` / `relationships` / `world` / `commitments` 四个模型
  （`hindsight.ex:60-67`、`:136-146`）；每个模型在 `mode: "full"` 下从头跑一轮反思代理（最多 10 轮工具调用，`config.py:1913`）。
  “没有新事实就跳过”只在 `delta` 模式生效（`memory_engine.py:17806-17828`），而产品只在有新写入时才刷新，所以这条跳过对我们几乎不起作用。
- **retain 同步抽取，巩固异步入队**：产品 `POST /memories`、`async: false`（`hindsight.ex:115`）；抽取在请求内完成，之后把巩固入队（`memory_engine.py:6737`、`:6845`）。
  反思存档库 `npc-reflect-<cid>` 同样会抽取与巩固。巩固可按库 `PATCH /config` 设 `enable_auto_consolidation=false` 关掉（`config.py:3813-3814`），
  也可显式 `POST /consolidate` 按需跑。
- **用量能读回，但不是账本**：`GET /v1/default/banks/{bank}/llm-requests`（逐行：input / cached / output / thoughts）与 `/llm-requests/stats?period=1d`（滚动 24 h）。
  只按库查；追踪只留 1 天（`LLM_TRACE_RETENTION_DAYS`）；写入尽力而为、可能丢行；JSON 解析失败的重试被计费但只记最后一次（少计）。
- **对 402 / 429 的反应**：401 / 403 不重试；其余（含 DeepSeek 余额不足的 402）调用内重试 3 次、任务级再重试 3 次；**巩固无限重试**（5 s 起翻倍、封顶 1800 s）。
- 产品现有的 `Hindsight.status/1` 只加了 input 与 output，**漏了思考 token**（`hindsight.ex:231-237`），不能直接当计量来源。

### 2.3 供应商侧与产品侧

- DeepSeek 只有账户级预付余额：用完回 402 Insufficient Balance（`api-docs.deepseek.com/quick_start/error_codes`，2026-11-18 核对）。
  它是最后一道硬底，但按账户、不按天、不分轻重：一停就连选择与说话一起停。
- 产品所有出站 HTTP 已经只有一个出口 `NpcServer.Http`（两条车道），产品发起的模型请求都经 `NpcServer.ModelUsage.request/4`，
  回执里有完整 token 计数（`model_usage.ex`）。Hindsight 的工作由 Life 的后台任务槽发起（`life.ex:1846-1900`，同一时刻每人一个槽，retain 优先于刷新）。
- Life 的待写片段上限 8 段（`@max_fragments`），写不进 Hindsight 时丢最旧的并告警（`life.ex:1809-1838`）：暂停 retain 几个小时会丢经历。

## 3. 依据

- Google SRE Book，*Handling Overload*（sre.google，2026-11-18 核对，扩人数稿 §3 已引）：按客户定额，过载时 “accept only the requests that it can process
  and reject the rest gracefully”，并按请求重要性（criticality）先拒低优先级。对应本稿：额度是全局定额；交互请求（选择、说话、召回）是高重要性，
  后台工作（刷新、巩固、抽取、反思、日计划）是低重要性，额度用完先停后者。
- Hindsight 0.10.3 源码（§2.2 行号）：决定了哪些手段可行（产品控制触发，而不是依赖 Hindsight 自带上限）。
- 原创部分：计量口径（产品回执 + Hindsight 追踪读回、按自然日落库）与“停触发而不是拦请求”是本稿的组合，没有找到同形态的现成实践；风险与验证见 §5。

## 4. 方案

```mermaid
flowchart LR
  subgraph 产品 release
    MU[ModelUsage 回执<br/>选择 · 说话 · 反思 · 日计划] --> B[SpendBudget<br/>当日花费 owner]
    HR[Hindsight 用量读回<br/>按库增量] --> B
    B -- 未到线 --> OK[照常]
    B -- 到线 --> STOP[停后台：不起 retain / 刷新槽<br/>拒后台车道模型请求<br/>关各库自动巩固]
    STOP -.-> KEEP[交互照常：选择 · 说话 · 召回]
  end
  HR <-- GET llm-requests --> H[(Hindsight)]
```

### 4.1 计量（谁记、记什么）

新增一个全局 owner（暂名 `NpcServer.SpendBudget`，每节点一个），只做一件事：维护“今天花了多少”。来源两条：

1. **产品请求**：`ModelUsage` 结束记录里的用量（已有），按价目表折成美元。
2. **Hindsight 用量**：按库（`npc-life-*`、`npc-reflect-*`）增量读 `llm-requests`（按 `started_at` 游标），折成美元累加。Hindsight 只留 24 h，
   所以累计必须由产品按自然日落库（PostgreSQL，`DataService` 现有 NPC 表或新表），重启不清零。

价目表（每模型的入未命中 / 入命中 / 出，思考按出计）是运行配置，不写死在代码里；高峰 / 非高峰按供应商的时段规则折算。
可观测面：一行 `npc_spend day= product_usd= hindsight_usd= threshold_usd= state=`（状态变化时与定期），CLI observe 同样读出。

### 4.2 到线后做什么（“拒后台”的具体含义）

到线（当日花费 ≥ 阈值）时，`SpendBudget` 进入“后台暂停”，到下一个自然日零点恢复：

| 工作 | 到线后 | 理由 |
|---|---|---|
| 认识刷新槽 | 不起 | 最大头（48%），由产品触发，停得住 |
| retain（写入抽取 + 引发巩固） | 见 Q-3 | 抽取 10% + 巩固 26%；但停 retain 会丢经历（§2.3） |
| Hindsight 自动巩固 | 各库 `enable_auto_consolidation=false`，次日恢复 | 巩固 Hindsight 自己排队，只有关掉才停得住 |
| 反思、日计划（后台车道写作） | 显式拒绝（`{:budget_exhausted, …}`，记一行），不发请求 | 2.5%，但同属后台 |
| 选择、说话、对话回合、召回 | **照常** | 交互，有人或 NPC 本身在等；召回在 Hindsight 侧不调模型 |

到线后的残余花费：交互请求每 NPC 每小时约 $0.10（高峰），3 人一天剩余时段最多约 $7；加上读回滞后（下一节）与在途的那一次刷新。
所以“$50”是后台的停止线，不是全部请求的硬上限——若要硬上限，见 Q-2 (b)。

### 4.3 读回滞后与少计

Hindsight 的用量是事后读到的：读回间隔内、以及到线那一刻在途的一次刷新（最多 4 个模型 × 10 轮）和已入队的巩固仍会花钱；追踪丢行与 JSON 重试少计也会让读数偏低。
处理：后台停止线设在上限下方留余量（用户定为上限的 90%：$65 → $58.5，取值后调），并在收尾核对时用 Hindsight 的 `/metrics` 进程级计数器交叉核对少计比例。

### 4.4 不到线时的降本杠杆（只评估，取值后调）

| 杠杆 | 影响面 | 估计 | 代价 / 不确定 |
|---|---|---|---|
| 认识刷新间隔 10 → 30 min（`@refresh_ms`） | 刷新 48% | 若每次刷新成本不变，刷新约省 2/3，总花费约 −32%（3 人全高峰 $51.6 → 约 $35） | 认识最长 30 min（游戏钟 ×24 下约半个游戏日）才更新；刷新成本随库变大而变，未测 |
| 按需刷新（只在要读认识的时刻前刷） | 刷新 48% | 取决于读认识的频率；选择每次都读认识，按需刷新退化成“每次选择前刷”，反而更贵 | 不建议，除非改成“过期才刷”的读侧缓存，那与现状等价 |
| 刷新改 `delta` 模式 | 刷新 48% | 未知（只知无新事实时跳过；产品本来只在有新写入时刷） | 首次会回退 full；需实测 |
| 四个心智模型分频（如 `commitments` 每次、`world` 低频） | 刷新 48% | 按比例 | 改刷新单元，要先定哪些模型多久过期 |
| Hindsight 反思思考档位下调（`*_REFLECT_LLM_REASONING_EFFORT`） | 刷新与巩固的思考 token | 思考约占 Hindsight 出向 token 一半 | 认识质量；需实测 |
| 选择提示词前缀稳定以命中缓存 | 选择 11% | 入向从 $0.3 降到 $0.006 / 百万（命中部分） | 只改提示词顺序；DeepSeek 前缀缓存按字节前缀匹配 |

结论（推断，未实测）：只靠降本杠杆能把 3 人日花费压到 $50 以下的“常态”，但没有任何杠杆能保证“不超过”；额度（§4.1–4.2）仍是必须的，降本是减少触线的手段。

## 5. 测试矩阵（本层只验链路与概念，阈值只在测试侧）

| # | 层次 | 证明什么 | 做法 |
|---|---|---|---|
| T1 | 算法 | 价目折算：入未命中 / 命中 / 出 / 思考四项、高峰与非高峰、自然日边界 | 小例手算 |
| T2 | 集成 | 产品回执累加；Hindsight 增量读回不重不漏（游标、分页 ≤ 500、库不存在）；重启后当日累计从库恢复 | 回环 Hindsight 替身给 `llm-requests`，独占 PostgreSQL |
| T3 | 集成 | 到线后：不起刷新 / retain 槽、各库关自动巩固、反思与日计划显式 `budget_exhausted` 且不发请求；选择与说话照常；次日恢复（注入时钟） | 真实 Life / Registry + 回环替身 |
| T4 | 真实 release 短场景 | 正式 release 上把阈值设得很低（如 $0.05），3 人、真实模型直连，看到线时刻、到线后 Hindsight 新增用量只剩在途尾巴、选择继续成功 | 复用扩人数驱动，窗口 ≤ 10 min，UDP / 4266 守护同前 |

不覆盖：长期账单与供应商实际扣款的核对（上线后按 DeepSeek 账单对一次）；多节点（首批单节点）。

## 6. 要用户定的

**已定**（用户 2026-11-18 答复，经第十九个统筹会话转达，原话：“全按建议。”）：Q-1 (a)、Q-2 (a)、Q-3 (b)、Q-4 停止线 = 上限的 90%（按已定的 $65 即 **$58.5**）、北京时间零点切日、Q-5 先量两项读数；Q-6 = $65（见下）。Q-3 (b) 的“次日恢复巩固后补漏扫描补跑”未实测，实施时由 T3 / T4 覆盖。

1. **Q-1 计量来源**：(a) 产品回执 + Hindsight `llm-requests` 读回，产品按自然日落库（**建议**：不改 Hindsight，只读接口）；
   (b) 让 Hindsight 的模型请求改经产品可控的代理出站（`HINDSIGHT_API_LLM_BASE_URL` 指向它），实时计量、到线回 429 + `Retry-After`——更准、能拦在途，
   但要新增一条出站服务、改 Hindsight 部署环境；(c) Hindsight 内装 validator 扩展——拦不住巩固，要往镜像里装代码，不建议。
2. **Q-2 到线后的范围**：(a) 只停后台（§4.2 表），交互照常，残余每天约 $7（**建议**，与你说的“超出即拒后台请求”一致，NPC 不会在当天剩余时间里呆住）；
   (b) 另设一条更高的硬线（如 $60），到了连选择与说话一起拒，NPC 原地待着、说话失败有显式提示。
3. **Q-3 到线后 retain 怎么办**：(a) 暂停 retain，经历留在 Life 的待写片段里（上限 8 段），超出丢最旧的并告警（省抽取 10% + 新巩固）；
   (b) 继续 retain、只关自动巩固（只停巩固 26%，经历不丢，抽取继续花钱；次日开回巩固后由 Hindsight 每 300 s 的补漏扫描补跑积压——读源码所得 `maintenance.py:476`，未实测）（**建议**：经历是 NPC 的长期记忆，丢了不可恢复）。
4. **Q-4 后台停止线与余量**：建议在上限下方留 10%（初稿按 $50 写的是 $45；已定上限 $65，停止线 **$58.5**），取值后按 T4 与上线后的账单再调；自然日按北京时间零点切。
5. **Q-5 降本杠杆先做哪一个**（§4.4，都是取值后调，不阻塞额度实施）：建议先量“刷新间隔 30 min”与“选择提示词缓存”两项的读数。
6. **Q-6 每天花费上限的档位**（**已定 $65**（用户 2026-11-18 答复，经第十九个统筹会话转达，原话：“1同意。2是的，都可以放宽”）；放宽后的学习额度见稿 B Q-3，放宽后学习上界：每次学习写作入约 6k、出 ≤ 4k，高峰价约 $0.0066；每人每现实小时（= 一个游戏日）≤ 12 次，约 $0.079，每人每天约 $1.9，3 人约 $5.7（按高峰时段加权约 $3.4）。3 人全天高峰最坏 $51.6 + $5.7 = $57.3，低于 $65 的后台停止线 $58.5（Q-4 的 90%），**在 $65 内，直接采用**；余量约 2%，认识刷新随库变大的增量尚未量到，若上线后读数推高，先报用户在“收回学习额度”与“再上调上限”之间选，不自行突破 $65。）（用户 2026-11-18 答复“额度可以增加上限”，经第十九个统筹会话转达；理解为 D-3 的 $50 可以上调）。读数：3 人按高峰时段加权约 $31 / 天，全天都按高峰价约 $51.6 / 天（M-4，§2.1）；学习（稿 B Q-3 额度上界）3 人约 +$3 / 天；Hindsight 认识刷新的成本会随库变大而上升，M-4 只量了 37 min，尚未量到。档位如下，“后台停止线”按 Q-4 取上限的 90%：
   - **$50**（原定）：加权日 $34 碰不到线；全天高峰的最坏日（$55）会在当天后段触线，之后只停后台（经历照写，见 Q-3）；
   - **$65**（**建议**）：停止线 $58.5，高于全天高峰最坏日加学习（$55）约 6%。正常日不触线，线只用来拦异常（刷新失控、重试风暴）；
   - **$100**：给扩到 5 人留空间。5 人加权约 $57；5 人全天高峰约 $91，仍在停止线 $90 附近。
   另：若“额度可以增加上限”指的是稿 B 的**学习额度**（Q-3：每人每游戏日 ≤ 2 任务 / ≤ 6 次写作）可以放宽，请一并说明；放宽到两倍，3 人每天约再加 $3。

## 7. 进度

- 2026-11-18（第二十个统筹会话）：本稿写成。事实来源：M-4 `scale3-direct-02` 的 `release.log` 与 `hindsight-llm.json` 按操作拆分；Hindsight 0.10.3 容器内源码只读核对
  （只用 GET 与 `docker cp`，未改容器）；DeepSeek 错误码页。等 §6 答复后实施（先 T1–T3，再 T4）。
- 2026-11-18：用户答复“额度可以增加上限”（稿 A / 稿 B 的 §6 全按建议，经第十九个统筹会话转达）。按读数加上学习上界，补 Q-6 档位，请用户选定。
- 2026-11-18：用户定 Q-6 = **$65**，学习额度也可放宽（用户 2026-11-18 答复，经第十九个统筹会话转达，原话：“1同意。2是的，都可以放宽”）。稿 B Q-3 放宽为每人每游戏日 ≤ 4 任务 / ≤ 12 次写作 / 每任务 ≤ 4 轮；放宽后学习上界：每次学习写作入约 6k、出 ≤ 4k，高峰价约 $0.0066；每人每现实小时（= 一个游戏日）≤ 12 次，约 $0.079，每人每天约 $1.9，3 人约 $5.7（按高峰时段加权约 $3.4）。3 人全天高峰最坏 $51.6 + $5.7 = $57.3，低于 $65 的后台停止线 $58.5（Q-4 的 90%），**在 $65 内，直接采用**；余量约 2%，认识刷新随库变大的增量尚未量到，若上线后读数推高，先报用户在“收回学习额度”与“再上调上限”之间选，不自行突破 $65。
- 2026-11-18：用户答 Q-1–Q-5 全按建议（用户 2026-11-18 答复，经第十九个统筹会话转达，原话：“全按建议。”）：(a) 产品回执 + Hindsight 只读读回、按自然日落库；(a) 只停后台；(b) 继续 retain、只关自动巩固；停止线 $58.5（上限的 90%），北京时间零点切日；先量刷新间隔 30 min 与选择提示词缓存两项。状态改为“用户已定，实施待排”。实施按先测后改 → 独立评审 → 提交。
- 2026-11-19（第二十一个统筹会话）：实施方案（只读规划子会话）核对 Hindsight 0.10.3 源码后，统筹会话定下列实施细节：
  - **修正 §4.1 的游标**：Hindsight 的追踪行在调用结束后才异步写入，`started_at` 由 `ended_at − duration` 倒推（`engine/llm_trace.py:504-611`），读接口只按 `started_at` 过滤 / 排序，长调用的行可能在游标越过它之后才出现。改为每次往回多读一段（回看 10 min，**原创取值**；Hindsight 单次调用上限 120 s）并按行 id 去重（账本 `unique(source, source_id)`，只把新插入的行计入）。
  - **计量口径**：Hindsight 一行 = (input − cached) × 未命中价 + cached × 命中价 + (output + thoughts) × 输出价（OpenAI 兼容通道的 `output_tokens` 不含思考，`providers/openai_compatible_llm.py:467-476`）；产品 `usage = nil` 的请求不计（残余少计，T4 用 `/metrics` 核对）。按 `ended_at` / 完成时刻定北京日与高峰档，金额用整数 nano-USD。顺带修 `Life.Hindsight.status/1` 漏 `thoughts_tokens` / `cached_tokens`。
  - **关自动巩固**：`PATCH /v1/default/banks/{bank}/config` `{"updates":{"enable_auto_consolidation":false}}`（jsonb 合并，Life 写 mission 的 PATCH 不冲掉）；关后 retain 不再入队、补漏扫描跳过该库，**已入队的巩固照跑**（残余，T4 量）。由 `SpendBudget` 维护期望状态，每个读回周期对未确认的库补 PATCH（幂等）。
  - **原创决策（已报用户，2026-11-19）**：① 价目表没有的模型行、或 Hindsight 用量连续 30 min 读不回 → 后台按“无法计量”暂停（`state=paused reason=unpriced | unmeasured`），不只告警——额度是用户定的硬约束，宁停后台不少计；② NPC 启用时价目与上限配置必填，缺即 release 启动失败，不设“未配置即不限”的分支；③ 计量边界：首批只用统一形态（`"npc"`），绕过 `ModelUsage` 的旧调用方（`brain/llm.ex`、`builder.ex`、`skills.ex`、`skills/wilderness.ex`）不在计量内，只读部署配置的那一台 Hindsight（`NPC_LIFE_HINDSIGHT_URL`）；扩到这些之前须先补计量。
  - 拒绝点只在 Life 的后台触发处消费 `SpendBudget.background/0` 的类型化结论（刷新槽、反思 `cannot_start`、日计划在 `admit` 之前），不放进 `ModelUsage`；选择、说话、召回不过闸门。实施待稿 A 批 0 评审修正合入后开始，DeepSeek 非高峰时段规则实施前再核官方价目页。
- 2026-11-19（实施子会话）：**DeepSeek 非高峰规则核对**（官方价目页 `api-docs.deepseek.com/quick_start/pricing`，2026-11-19 读）。原文要点：
  “Off-peak rates are half of the peak rates.”；“Peak hours are 01:00 - 04:00 and 06:00 - 10:00 UTC, Monday through Friday, excluding Chinese public holidays.”；
  “All other hours are off-peak, including weekends and Chinese public holidays in full.”；计费 “expense = number of tokens × price”。deepseek-flash 每百万 token
  高峰 入未命中 $0.3 / 命中 $0.006 / 出 $1.2，非高峰 $0.15 / $0.003 / $0.6（与 §2.1 一致）。页面**没写**按请求开始还是结束定档，按统筹会话所定以完成时刻
  （`ended_at` / 回执到达）定档与归日。与方案的差异：官方高峰只在工作日、且不含中国法定节假日，`NPC_SPEND_OFF_PEAK` 只能写每天相同的北京时段
  （`00:00-09:00,12:00-14:00,18:00-24:00`），周末与节假日白天会按高峰价计（多计、不少计，最多把这些时段的花费算成两倍）；要按星期 / 节假日精确折算需另定配置形状，
  未做，待统筹定。
- 2026-11-19（实施子会话）：T1–T3 实施完（提交见统筹页）。`SpendBudget`（`spend_budget.ex`）+ `Price` / `Config` 纯函数 + 账本 `npc_spend_ledger`
  （`DataService.NpcSpend`）+ `ModelUsage.finish` 记账 + Life 三处拒绝点 + `Registry` 注入 + 监督树 `[Http, Names, BodySupervisor, SpendBudget, Bootstrap]`。
  测试：T1 `npc_spend_price_test` 8 项、`npc_hindsight_test` 的 status 用量 1 项改写；T2 `npc_spend_budget_test` 7 项、`data_service/npc_spend_test` 3 项；
  T3 `npc_spend_life_test` 1 项（到线 → 停后台 / 关巩固 → 零点恢复整条链路），均先红后绿。实施中按源码事实定下、待统筹确认的几处：
  ① “NPC 启用”在源码里没有 release 级开关（只有登记行的 `enabled`），取“配了 `NPC_LIFE_HINDSIGHT_URL`”为判据（额度要读的就是它，统一形态的 Life 缺省也连它）；
  没配时不读其余变量、后台按 `:unmeasured` 一直停（不设“未配置即不限”，现状生产照常启动）；本节点从未发布过结论时 `background/0` 同此。
  ② CLI `Life.reflect/1` 有新经历时同样回 `{:error, {:budget_exhausted, 北京日}}`（与 CLI 刷新一致；方案只点名了刷新）。
  ③ `SpendBudget` 崩溃重启会经 `:rest_for_one` 带起 Bootstrap 重启，`Registry.start_all/0` 把全部 enabled NPC 停掉再起（结果同前，但不是无操作）。
  ④ 未定价的行留在账本里（`nano_usd` 为 null），当日一直 `:unpriced`，补价目重启也不重新计价，次日恢复。
  ⑤ 入库失败的行在写进账本之前不计入总额（只在 `unsaved=` 可见）。T4 未做。
- 2026-11-19（实施子会话，独立评审修正）：按独立评审与统筹会话定下的 8 条修正（提交见统筹页），均先写反例跑红再改：
  ① **故障不拖垮节点**：账本读写失败一律转成 `state=paused reason=unmeasured`（`npc_spend_ledger_failed op= reason=`），下个读回周期与
  `sync/0` 重试，不崩；`init` 先以本进程为 owner 发布 `:unmeasured`。结论连同 owner 进程一起发布，owner 不在（启动中、已停、崩溃后重启中）时
  `background/0` 一律给 `:unmeasured`，不读上一个 owner 留下的 `:open`。监督树改为 `[Http, Names, BodySupervisor, Bootstrap, SpendBudget]`：
  它崩溃只重启它自己，不带起任何 NPC（取代上面 T1–T3 记录里的③）。
  ② **写不进账本时停止线仍有效**：`unsaved` 的行照样计入当日总额；`unsaved` 非空持续 30 min（与读不回同一阈值）→ `:unmeasured`（取代⑤）。
  断档期间回看窗口里已入账的行会再进 `unsaved`，最多多计约 10 min 的 Hindsight 花费，写回后回到准确值（多计，不少计）。
  ③ 产品回执按**请求时配置的模型名**计价（`Config` 启动时核的就是它；供应商应答常回报带版本号的名字）。
  ④ `llm-requests` 每页 500 → 100：Hindsight 0.10.3 的每一行带完整 `input` / `output`（`engine/llm_trace.py:339-366` 的 `LLMRequestEntry`，
  2026-11-19 只读核对），页字节数随对话长度涨；实际页字节数留 T4 量。
  ⑤ 四项 token 的合法性只定义一次（`SpendBudget.Price.tokens/1`：非负整数、命中不多于输入），产品回执在 `ModelUsage`、Hindsight 追踪行在
  `Life.Hindsight.llm_requests/3` 各调一次；不合法的产品回执记为未定价（`npc_model_usage_invalid`、`npc_spend_unpriced … reason=invalid_usage`），
  不合格的追踪行整库这一轮读失败，日志带库名与行 id、不带内容。
  ⑥ Hindsight 地址的校验与“`NPC_JEV_API` → 选择位置模型名变量”的规则只留在 `NpcServer.Registry`（`hindsight_url/1`、`jev_model_env/1`），
  `Config` 调用；取更严的一份（主机非空；`NPC_JEV_API` 认不出的值 raise）。
  ⑦ **高峰按 UTC 工作日规则配置**：`NPC_SPEND_OFF_PEAK`（北京时间、每天相同）换成 `NPC_SPEND_PEAK_UTC`（如 `mon-fri 01:00-04:00,06:00-10:00`，
  分号可写多条；不配即每一刻按高峰）。周末不再按高峰多计。**边界：中国法定节假日不建模**——官方节假日全天非高峰，这里节假日的工作日白天
  仍按高峰计，最多把这些时段的花费算成两倍（多计，不少计）；要精确需另给节假日表，未做。
  ⑧ 补测试：`unsaved` 写回后只计一次、读回 worker 崩溃（`:DOWN`）按列库失败计且不卡住、零点由真实定时器换日、账本启动 / 换日读失败、
  owner 不在。T3 零点那一刻的瞬时 `state=paused reason=unmeasured hindsight_age_ms=3900000` 查明是**测试手动拨钟的假象**：用例只在 15:00 读回过一次，
  之后把时钟直接拨到 16:05、中间没有读回，换日时“已 65 分钟没读全”确实成立；同一轮读回读全后立即转开。生产每 60 s 读回，换日不动“上次读全”
  的时刻，不是产品缺陷；用例里已写明原因并断言恢复。
