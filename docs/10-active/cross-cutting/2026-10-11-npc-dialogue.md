# NPC 对话：玩家与 NPC、NPC 与 NPC

分类：全局系统功能；Demo 与驱动为 Test-only。2026-10-11 用户将对话提为首要增量，明确要求两种参与组合，并选择“附近公开交谈，可指定对象”。第一版已实现并跑通真实玩家与两个独立模型 NPC 的交谈；分层验收结果及尚未完成的持久记忆闭环见文末，不声明整轮验收全通过。

## 契约与范围

一个角色只拥有自己的发言。服务端确认谁说了什么、向谁说、谁处于听觉范围；NPC 自己决定是否回应、说什么及是否改变计划。两名 NPC 经同一条说话/听见通道交流，不由一个模型同时编写双方台词。聊天不暂停世界，也不自动控制听者。

第一版采用附近公开文字交谈，可指定对象，旁人能听见、加入；默认无回答义务。玩家↔玩家也是同一传输的自然结果。先覆盖同一 Scene；跨 Scene、耳语/私聊、语音、声学遮挡、全局频道、离线留言、任务/交易承诺执行均不在这一增量。跨 Scene 指定对象明确拒绝，不能伪装送达。听觉按权威完整 XYZ 距离，不复用视锥判定。

成功场景：玩家 A 指定 NPC 甲说话，甲依据自己的历史回答；甲自主对乙说话，乙通过自己的一次决策回答；玩家 B 在旁看到同一权威发言并能加入；远处角色收不到；离开或沉默可结束，NPC 回到自己的活动；重要对话留有来源，重启后可回忆。不能把协议收包、固定脚本台词、内部 heard 注入称为模型自主交谈。

## 选择与依据

- 附近公开交谈（采用）：具备共同场景与旁听，复用正式角色会话。纯私聊不能覆盖旁听，全球广播会让不在现场的 NPC 获得信息。默认范围 12 米，只是可调产品初值，不是文献结论。
- 感知与选择分离：[Epic AI Perception / Hearing](https://dev.epicgames.com/documentation/en-us/unreal-engine/ai-perception-in-unreal-engine) 将听觉刺激、范围/寿命与行为分开。本项目沿用边界，由服务端而不是 UE AI 感知裁定听众；第一版不模拟穿墙衰减。
- 独立代理记忆、计划、交谈：[Generative Agents](https://arxiv.org/abs/2304.03442) 支持把对话放入各自经历与后续规划；不引入其整套模拟器，也不以该论文证明我们的长期自洽。
- 有序发言：[Erlang 信号契约](https://www.erlang.org/doc/system/ref_man_processes.html) 不提供不同发送者间的全局顺序，因此由一个 Scene owner 接纳发言，生成会话内序号。客户端不拼接多个来源猜顺序。
- 片段记忆：[Hindsight retain](https://hindsight.vectorize.io/developer/api/retain) 支持带时间/文档身份的经历。继续固定 0.10.3、flashrank、片段批量写；具体 API 以仓库现有适配器及固定版本测试为准，不每说一句就 reflect/retain。

## 所有权

```mermaid
flowchart LR
  UI[玩家 UMG / CLI] --> Gate[正式 QUIC 已鉴权会话]
  BrainA[甲自己的 Brain] --> BodyA[甲 Body.say]
  Gate --> Scene[Scene 对话接纳与顺序]
  BodyA --> Scene
  Scene --> Said[不可变 Speech 事件]
  Said --> UI
  Said --> BodyB[乙 Body.heard]
  BodyB --> Runtime[Runtime 的近期对话]
  Runtime --> BrainB[乙自己的 Brain]
  Runtime --> Life[Life 持久片段 / Hindsight]
  BrainB --> BodyB
  BodyB --> Scene
```

- `SceneServer.Dialogue`：纯状态规则；由现有 `Movement.Scene` 拥有状态和生命周期，不再起一个会话监督根。接纳时使用 Scene 已接收的最新权威角色观察，记录裁决 tick，不信客户端位置/姓名/kind。
- `Movement.Scene.say(scene, identity, request)`：玩家与 NPC 共用公共入口。当前 identity 必须对应已 Ready 且仍在场角色；指定目标必须在同 Scene、同一听觉范围且可接收。失效/移交期间显式失败。
- Gate：只鉴权、译码与转发，不解释台词，不调用 LLM。Scene 经既有 Outbound.control 投递 Speech。`accepted` 仅代表完成权威接纳并向当时听众排入可靠出口，不代表听者理解、答应或已持久记忆。
- Body：`say` Outcome 是 Scene 结果；收到本人回声用于记账，不把自己说的话当作新外界刺激。收到他人 Speech 才产生 `heard`。
- Runtime：拥有近期发言尾部；传给自己的 Brain 与已有技能中断策略，不清掉尚待处理的话，不强制取消工作。
- Llm：同一个人生大脑决定工作/说话/沉默，不建立第二聊天大脑。请求在途收到的新发言在下轮保留；对话检索加入最近被直接叫到的话，每轮依然仅一次 Hindsight recall。
- Life：只接纳服务端已发生的 Speech 事件，追加经历与现有片段 outbox；不依自然语言直接修改人格/情绪/库存/关系数值。

## 发言与轮次

1. 请求：`request_id`（调用者单会话递增）、`target_id`（0 表示对附近公开说）、`conversation_id`（0 新起）、`text`。身份来自已鉴权连接/Body；用户不能提交 speaker/kind/name/position。
2. 事件：`conversation_id`（服务端随机非零 u64）、`turn`（从 1 递增）、`speaker_id`、`speaker_epoch`、`speaker_kind`、`speaker_name`、`target_id`、`at_ms`、`text`；接收者 identity 由 Outbound 携带。事件唯一键为 conversation_id/turn。随机会话号避免进程重启后复用旧序号。
3. 合法文本：UTF-8，去首尾空白后 1..512 个 Unicode 字符，最多 2048 字节；拒绝控制字符（换行可保留）。超长拒绝，不切断中文。发言间隔至少 2 秒，双方都受规则约束。数值由服务端 Dialogue 一处定义并作为能力描述的来源。
4. 指定对象是叫谁，不是保密：同范围其他人照样收到。回复须引用仍有效的 conversation_id；调用者必须是此前收到此会话发言的人，不能猜 ID 接入远程对话。每次发言重新计算听众，离开后不再收到。
5. 同一会话连续没有玩家发言时，最多 8 句 NPC 发言；下一条被明确拒绝为 `conversation_limit`。玩家新的发言刷新该计数。NPC 自己新开话题至少间隔 5 分钟，防止换 ID 绕过接话上限；听到的话仍可在额度内选择回应。会话空闲 120 秒失效；Scene 自己清理失效会话，不依赖下一条消息或别人维持活性。
6. 被直接叫到只唤醒被叫者。旁听进入近期上下文，在下一次正常决策时可选择加入，不唤醒整圈 NPC。所有决策仍计入现有 60 次/小时上限；无配额、请求失败或拒绝保持可诊断，不生成假回复。
7. 每个身份只缓存最近一次请求与结果，并维护请求高水位。相同 request_id/同内容返回原结果、不二次广播；同号不同内容拒绝 `request_conflict`；更旧号拒绝 `stale_request`。玩家/Body 不自动重试发言。会话重连即新身份。
8. 沉默是合法选择：现有 wait/继续工作即可。没有台词即没有 Speech。结束由沉默、离开或轮数上限自然产生，不额外强制生成告别词。人格/情绪影响是否接近、接话与措辞；不能用一句赞美就改写既有伤害证据。

## 线协议（已实现）

复用 Session 的 M1 envelope（大端、domain=1），在既有 kind 14 后追加，不改变任何旧消息字段。新增 Hello 40，在两端与构建清单同步，旧 Hello 显式拒绝。

| kind | struct | 按顺序字段 |
|---|---|---|
| 15 | Session.Say | identity, request_id:u64, target_id:u64, conversation_id:u64, text:utf8 |
| 16 | Session.Speech | identity, conversation_id:u64, turn:u32, speaker_id:u64, speaker_epoch:u64, speaker_kind:u8, speaker_name:utf8, target_id:u64, at_ms:u64, text:utf8 |
| 17 | Session.SayResult | identity, request_id:u64, conversation_id:u64, turn:u32, reason:utf8 |

SayResult.reason="ok" 为接纳；拒绝 conversation_id/turn 为 0。跨进程调用超时为 `delivery_unknown`，表示结果未知，不等于拒绝；显示“发送结果未知”，不自动重发。正常结果必须关联 request_id；Speech 不依赖 EntityEnter 到达顺序即可显示名字。旧 G0 字节冻结样本保持原样，不以新 Hello 重捕获。

## 短期上下文与长期经历

近期对话按权威接收顺序保留最近 24 句（自己的句子也保留）；呈现明确 speaker、target、conversation、turn、时间和原话。短期尾部是有界上下文，不是永久聊天存档。独立 `heard` 输入不混入 instructions；提示说明台词是角色声明，不能变成系统指令。

Life 对自己的发言、被叫到的发言以及实际听到的旁听统一留来源明确的经历，批量封存，复用原 outbox/refresh。存储的是 “我听到/我说了……”，不是把引号内容当成已验证世界事实。聊天经历不推进 World transaction cursor；片段 ID 使用经历本身的唯一 ID，不用 World seq 假装聊天事务。持久化失败可见，不能声称重启记住了。

人格/情绪本轮不新增数值维度、不做语言情感分类器。已有 caution/sociability、anger/gratitude、关系以及缓存 mental models 进入同一个选择上下文。后续若要“被辱骂会生气”必须另行定义可审计的权威评价规则，不能靠自由文本分类结果任意写心智。

## 玩家入口与可观测性

复用 Voxim 唯一生产 `VoxelWorldActor`/M1 连接与现有 PlayerController。新增全局 UMG 对话组件与资产：Enter 打开输入、Enter 发送、Escape 取消，中文输入法组合 Enter 不能误提交；选择当前目标后显示“对 某某 说”，无目标显示“附近”。附近日志显示确认后的原话、发言人和指定对象；待确认/拒绝单独显示。输入中暂停角色移动/工具输入，关闭后恢复原输入模式，不挂住按键。

CLI 和 UMG 共用 `Say` 调用；日志 `dialogue.request/result/speech` 包含 request_id/conversation_id/turn/speaker/target/receiver/reason；Scene 只读观察包含活跃会话/接纳和拒绝计数；NPC 观察包含近期对话与决策输入依据。默认输出 `.demo/observe/npc-dialogue-20261011/`；客户端截图遵从 Voxim `Captures/`。

## 实施计划

按仓库 `AGENTS.md` 与 `Voxim/Docs/Testing.md`，已授权范围自主推进，无额外逐文件审批。服务端在当前 worktree；客户端另建隔离 worktree，不动主树。旧自主生活会话已保存并让出共享产品文件和 Demo。

- [x] 1. 纯协议与 Scene：`session/types.ex`、`session/codec.ex`、`scene_server/dialogue.ex`、`movement/scene.ex`；先红再绿。证明中文 golden、未知版本/截断、完整 XYZ 范围、身份冒用、离开/重连、重复请求不重播、会话过期/轮次限制。纯规则受控时钟；真实 Scene 测试经正常 join/Ready 建立角色。
- [x] 2. NPC：`npc/dialogue.ex` 能力定义、Abilities、Body、Runtime、Brain.Llm、Brain 文档、Life。工具 `say{text,target_id,conversation_id}` 的 target_id/conversation_id 可空、译码为0；统一 Outcome。证明每个大脑只见实际听见的消息、在途不丢新话、旁听不群体唤醒、记忆来源与 World cursor 不串、重启恢复及出站失败不被记成成功。
- [x] 3. Gate 与客户端：控制流 Say 转发、SayResult/Speech 解码与 identity 隔离，Hello40；Voxim 网络类型、M1数据桥、PlayerController、authored UMG、CLI、自动化与现有生产根接线。为双方共用固定 golden，不复制裁决规则。
- [ ] 4. 正式 Demo：冻结代码/两端/镜像版本；沿用独立18908记忆实例，不碰18888/18898、不落盘key。先驱动干跑与反例，再约10分钟真实双端，两个独立 LLM NPC、附近旁听玩家、远距负例；核对每个确认事件。然后服务端重启读取持久对话记忆；长时间规则在受控时钟测试。
- [x] 5. 审查本次边界、修复、复核最小相关回归，更新 NPC README 与此处证据。分别报告已实现/已实跑/已验收。

## 验收与风险

需要实证的五类破坏：两个玩家并发叫同一 NPC 后答错对象；NPC 模型在对方离开后迟到应答；技能途中聊天导致未完成动作丢失；重连回放旧身份台词；恶意台词被误当作系统命令/已证世界事实。上述分别落在 Scene 顺序、目标重检、Runtime技能回归、客户端代际过滤和上下文/记忆断言；真实模型验收承认语言生成非确定，不能只靠单条输出证明永不受诱导。

已知限制：12米范围是简单距离模型；同Scene边界明确；Npc↔Npc预算限制降低交谈长度；真实模型可能选择沉默，需要区分自主不回应、预算拒绝、网络失败。模型说“答应”只是一句发言，不证明承诺已履行。第一轮不声称长期人格一致性或完整自主人生已经验收。

## 进度与证据

- 设计前已核对：旧 Body.say 恒拒 `chat_unavailable`；Abilities 不投影；Llm.heard 只置 dirty、不保留文本；无当前正式 UI/QUIC 对话契约。不能复用旧归档客户端聊天当完成品。
- 已协调原自主生活会话冻结共享产品文件和 Demo；当前 release 为5b4cd58e，模型本轮未发起，累计外部 token1,243,611/2,000,000。
- 用户已明确选择“附近公开交谈，可指定对象”。服务端首轮实现提交381f5388/6303a114/530c91c0；客户端隔离工作树 `C:/Users/DYZ/orca/workspaces/Voxim/npc-dialogue-20261011`，提交3594478a；尚未合并主树。
- 分层证据：纯合同151项通过；Scene新规则与真实模块回归40项通过；NPC相关8文件88项通过；客户端独立构建及16项Session/Hello/对话边界测试通过。各自替身与覆盖边界见 `.demo/observe/npc-dialogue-20261011/{scene,npc}/` 与客户端 `Saved/Dialogue/`。这些不等于真实QUIC/模型/UMG完成。
- 独立审查发现NPC说话调用超时的身体退出与技能中断提示来源漂移，两项已在954528c1修复：真实Scene已经接纳、回复丢失时Body仍存活且报告未知；Jev明确自己的话、旁听、直接叫到及接收顺序。最小反例先红，5个直接相关文件最终63通过、2排除，证据 `npc/review-verification.json`。用户端超时为 `delivery_unknown`；NPC沿用既有 `Outcome.status=rejected` 表示本次调用未获确认，必须看reason，不能把 `delivery_unknown` 当成Scene权威拒绝。未新增全局Outcome状态集合。
- 双端驱动 `scripts/npc_dialogue/run.py`：保留本任务独占的长期世界与LifeBuilder历史，合法登记第二个NPC“松岚”，不改心智。两端使用正式登录、QUIC、生产地图与UMG；玩家只提出话题，两个life大脑各自决策，每个最多16请求。本轮模型使用量另加至1243611/2000000累计额度。初次UMG发言双端确认前，后续阶段与模型不启动；结束恢复无模型的settler后端。
- 判定器先过8个离线最小用例，包含漏一笔、重复、错误角色/文本/收件人、超范围仍收到、错误request关联和缺失服务端收件人记录；不能以共有一条消息或回放退出成功当完整复制。
- 上述未运行状态是第一次集成前的历史检查点。下面收口记录覆盖运行状态；不修改失败轮证据。

### 真实运行收口（2026-10-11）

- 正式服务端为源码954528c1、镜像 `voxim-server:20261011-npc-life-954528c1`，image ID `sha256:ba82b37a4bf592b9f1eaf88ceddc37eb6dac4229eac91b2ecf3d22b592695093`。已有长期世界、两玩家账号、LifeBuilder历史保留；新增“松岚”cid51107598336。HTTP27361/QUIC27363，Hindsight18908；未触碰18888/18898。实际身份在 `release-954528c1/`、各运行 `execution.json`。
- `dual-01` 准备失败：新NPC出生探针位于地面实心格，只查缓存就绪会放行没有Body位置的NPC。已发生2次决策21230token计费；保留失败。修复测试夹具从实查有净空的位置经正式出生入口下扫，并要求身体入场，最小反例先红后绿；没有修改碰撞规则。
- `dual-02` 使用客户端3594478a、真实QUIC、UMG输入与两个独立life大脑。权威接纳14条发言，A完整收到14条，B完整收到应收到的13条；远距那一条未投递给B，B远处指定NPC的请求返回 `target_out_of_range`。其中8条NPC向对方指定发言，全部逐句对应本人的真实模型say调用。玩家B通过UMG加入；取消输入未产生发言。`python -B scripts/npc_dialogue/run.py check --run dual-02` 与 `functional-verdict.json` 只证明这些已经完成的行为。
- 真实内容：松岚选择“先做观察和记录，暂不承担修复”，并调用World核对木方块；它明确损坏与修复历史来自LifeBuilder讲述、自己未亲历。LifeBuilder在最后对玩家A的回答中保留对过去破坏的谨慎，明确不把“青石约定”提议当作已达成承诺。这证明本次短场景有独立立场和来源区分，不能推广为长期永不受诱导或人格永远一致。
- `dual-02` 完整回放未通过：350000决策软门槛触发后停止，31次请求已全部结束（两NPC分别15/16次），实际371662token；尾部300秒Status步骤未完成。`errors.json` 和两端 `interrupted` 保留，不能把 `functional-verdict.accepted=true` 写成整轮通过。
- 初次画面底左聊天遮住身体/建造HUD；客户端bb2c4403将阅读区移右上、输入区在其左侧展开。`ui-01` 使用该资产与原DLL，不启用任何LLM/Life后台：准星O选择实际NPC、当前目标按钮、UMG中文发送、取消、CLI Status全部通过；客户端正常回放退出0，约4分44秒。运行960×720画面 `Captures/Dialogue/20261011/live-ui-01.png` 已查看，阅读区与身体/建造区域分开、文本可读；不代表所有分辨率/文字缩放验收。
- 系统微软拼音通过原生按键验证：出现 `ni` 候选窗口，第一次Enter只结束组字并保留输入面板，日志请求数仍1；随后空格选“你”、Enter发送，权威回执为ok。`ui-01/ime-first-enter.json`、`ime-verdict.json`及客户端 `ime-candidates.png`、`ime-enter-keeps-composer.png`、`ime-chinese-committed.png`留证。不是用 `@type` 冒充系统IME；输入区域切换依据 [WM_INPUTLANGCHANGEREQUEST](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-inputlangchangerequest)，只改变测试窗口当前输入布局。

### 预算与当前可运行状态

截至 `paid-quiesce/`，历史及失败轮1264841 + 本轮决策371662 + 两bank新增记忆处理374444 = **2010947 token**，超用户2000000上限 **10947**。决策软门槛漏计同时发生的retain/reflect/consolidation以及在途调用，预留不足；这是执行预算控制失败，不能以“都在途”免计。已通知用户。

两NPC现均为settler且**移除life参数**，因此决策与记忆后台均关闭；两个 `Life.observe` 为 `life_not_running`，Hindsight待操作/待巩固均0。保留人物、World和所有存档，不清空用量。费用账本为 `.demo/observe/npc-dialogue-20261011/budget-ledger.json`；live入口新增耗尽账本在任何运行准备之前拒绝的反例，最终10项判定器测试通过。这个入口检查不等于已实现逐请求的硬token上限，未获新预算且未收口总费用预算控制前不再启动付费实验。

尚未完整验收：所有尾部对话封存到Hindsight后的Life恢复/决策回忆、全分辨率/缩放UI及打包客户端；连续自主生活、自给自足与长期人格模型仍属下一阶段。尾部持久性与现存记忆的无付费只读结果另记，不通过跳过尾部刷新把记忆全链路标绿。

### 无付费存档与记忆检查

`memory-readonly-01` 经正常正式容器冷重启，DataService中两NPC的完整Life存储行逐项相等；Life始终关闭。各bank恰好一次生产 `Hindsight.recall`，使用已查证的本地ONNX/flashrank路径；所有scope用量前后完全相等，新增付费0。实际fact引用的文档保留双方首轮两句的完整身份、时间、原话和本人/听见视角，来源链可追溯。两NPC各4条尾部仍在SQL持久pending，未调用retain/refresh。

语义复核没有通过完整预选两句召回门槛：返回事实更偏向后续“先观察、暂不修复”的内容，自我介绍、询问和条件未完整保留；不能因命中了包含首句的长文档就声称首句被准确召回。部分摘要把意愿简成“负责”，甚至把讨论写为“约定”，不能据此创建真实承诺或修改World。另一个实证缺口是：英文经历包装中的中文原话使本轮抽取事实仍为中文，与flashrank英文模型的既定使用条件不符；不能声称英文记忆约束已满足。后续记忆增量须保持中文原话可追溯，同时验证英文提取与提议/承诺归因，不能靠再次查询挑结果修饰本轮失败。

证据 `memory-readonly-01/verdict.json`、`semantic-review.json` 明确 `scope=memory_readonly_partial`、`accepted=false`、`paid_budget_passed=false`；存储/重启/已有来源通过与完整记忆语义未通过分别保留。这些不替代启用Life后由NPC决策重新使用记忆的完整恢复链路。
