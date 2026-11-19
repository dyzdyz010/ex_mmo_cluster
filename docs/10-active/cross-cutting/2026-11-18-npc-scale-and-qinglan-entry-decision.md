# NPC 扩到 5 个以上与进青岚的最低标准（2026-11-18）

分类：薄片四“多 NPC”这一层与生产化入口的决策稿（只定目标、规模、预算与测试矩阵，不调取值）。状态：**用户已定（§7），实施中**。
前提与进度见 [`2026-11-11-npc-coordination.md`](2026-11-11-npc-coordination.md)；总纲见
[`2026-11-12-npc-architecture-overview.md`](2026-11-12-npc-architecture-overview.md)。

## 1. 目标

两件事合在一份稿里，因为它们要回答同一组问题：放几个、占多少内存与 CPU、花多少钱、怎样部署。

1. **扩到 5 个以上 NPC**：证明 N 个人格不同的居民同场时，每人的控制链照常闭环、用量全部配对、交互请求不被后台请求拖慢，
   并量出 N 与资源、请求速率、token 的关系。
2. **定进青岚的最低标准**：青岚是唯一分发入口（Voxim `AGENTS.md`“分发集成、版本与打包”），进去之前要满足的条目写成清单，
   之后按清单逐项做，而不是“功能完善了再说”。

不做：取值调整（守屋偏多、计划拉动、尾延迟、措辞）、NPC 之间直呼、情绪的 Jev 评价、`Brain.Llm` 收编——都按 2026-11-16 用户定的“后期”。

## 2. 现状事实（各附证据）

| 事实 | 读数 | 来源 |
|---|---|---|
| 生产机 | 2 核、总内存 7392 MiB、无 swap；青岚 app `mem_limit` 4000 MiB（手册建议 4600）、`cpus` 1.8 | 主检出 `.demo/observe/qinglan-deploy-20261029/RUNBOOK.md` §2.3、§4（2026-10-29 只读核对） |
| World 内存 | 如园迁移峰值 3848 MiB；事务与检查期 ≤ 2250 MiB；冷重启峰值 2105 MiB | 同上 §2.4 |
| 生产内存兜底 | 超过 3400 MiB 告警，超过 3900 MiB 持续 180 s 受控重启 | `deploy/README.md`“青岚内存兜底” |
| Hindsight | 本机容器常驻约 1019 MiB；嵌入（ONNX `bge-small-en-v1.5`）与重排（flashrank）都在 CPU 上算；retain 与巩固自己调 DeepSeek | `docker stats` / `docker inspect npc-s1g-hindsight-20261118`（2026-11-18） |
| Hindsight 自己的模型用量 | **不在** `npc_model_request` 里（它直连 DeepSeek，不经产品的出站车道） | 同上环境变量；`ModelUsage` 只记产品发起的请求 |
| 四人请求速率 | `slice4-04c` 约 59 s 窗口：选择 31、日计划 4、反思 6、说话 4，合计 45；平均每人约 7.6 s 一次选择——因为场景里活动很短，不代表生产节奏 | `.demo/observe/npc-slice4-20261118/runs/slice4-04c/verdict.json` |
| 单次选择的输入量 | `slice4-03` 36 次选择合计约 4.05 万输入 / 0.18 万输出 token（约 1.1k 入 / 次） | 统筹页“薄片四第三轮” |
| 生产 NPC | `enabled=0`；部署环境与 `.env.example` 都没有 NPC 变量；本分支未合 master（PR #11 draft） | `deploy/README.md`“NPC 常驻应用”；统筹页 |

两条结构性的推论：

- **请求速率由活动时长决定**：选择在活动结束时发生，所以“每人每分钟几次选择”取决于活动长短，而不是 NPC 数。
  扩人数的测量必须用接近生产节奏的活动时长，否则读数没有外推意义。
- **Hindsight 是内存与 CPU 的最大未知数**：生产机 2 核、World 已占大半内存，同机再放一个约 1 GiB、在 CPU 上做嵌入的服务，
  是否放得下要实测，不能推断。

## 3. 依据

- Park et al., *Generative Agents*（arXiv:2304.03442，§8.2，2026-11-18 核对 HTML 版原文）：“The present study required substantial
  time and resources to simulate 25 agents for two days, costing thousands of dollars in token credits and taking multiple days to complete.”
  ——同类架构的成本随人数与模拟时长线性增长，是实打实的门槛。本稿据此把“每 NPC 每小时 token”列为进青岚前必须量出的数。
- Google SRE Book，*Handling Overload*（sre.google，2026-11-18 核对）：服务按客户定额（“define per-customer quotas”），
  过载时“accept only the requests that it can process and reject the rest gracefully”，并按重要性先拒低优先级请求。
  本仓已有的对应物是 Finch 两条车道（交互优先、后台排后）。本稿**暂不**在产品里加额度：没有失败证据前不预建兜底（AGENTS §2.2.7）；
  先量（§5 M-4），若量出的成本或速率超过 §6 D-3 定的预算，再按这条依据加“每 NPC / 全局”的额度，届时另写稿。
- 生产限额模拟沿用青岚手册 §2.6 的做法：本机 `docker run --memory 4600m --memory-swap 4600m --cpus 1.8`、`ERL_FLAGS=+S 2:2`。

## 4. 进青岚的最低标准（清单）

```mermaid
flowchart LR
  A[功能层验收<br/>说话 ✔ · N 人同场] --> B[资源与成本实测<br/>生产限额下]
  B --> C[合并主线<br/>CI 全绿]
  C --> D[部署配置<br/>变量 · Hindsight · 凭据]
  D --> E[青岚放置<br/>出生点 · 去处 · 对话 UI]
  E --> F[分发流程<br/>冻结版本 · 镜像 · 打包冒烟]
```

| # | 条目 | 现状 |
|---|---|---|
| E1 | 说话双端实机复验 | **已过**（`lane-01`，2026-11-18） |
| E2 | N 人同场（N = §6 D-1 定的首批人数 + 余量）真实模型实跑，五题成立 | 4 人已过；本稿 M-1 / M-2 |
| E3 | 生产限额下的内存与 CPU：World + N 个 NPC + Hindsight 峰值低于告警线 3400 MiB（或 Hindsight 另放，见 D-2） | **3 人同机已过**（`limits3-03`，带 M-3c 的 2 核配置）：release 峰值 1854 MiB（启动加载世界），窗口内两边同一时刻合计最大 2200 MiB，tick 不掉速，召回失败 0；6 人同机不过（`limits6-01`，召回失败 11）。D-2 定同机、首批限 3 人（§7） |
| E4 | 每 NPC 每小时的 token 与请求次数（含 Hindsight 自己的模型用量），按生产节奏外推成本，在 D-3 的预算内 | **读数已有**（`scale3-direct-02` 截断于 37.4 min，用户定采用）：每 NPC 每小时约 266 万 token、约 $0.71（高峰价）；3 人每天最坏约 $51，在 D-3 的 $50 档附近，进青岚前须由产品侧额度兜住，见 §7 |
| E5 | 生产网络路径（HTTP/2 直连 DeepSeek）下 N 人同场无排队失败、无取消残留 | 未测（实跑都经本机明文代理，走 HTTP/1）；M-1 改一轮直连 |
| E6 | 分支合并 master、CI 全绿 | PR #11 draft，181 提交 |
| E7 | 部署：NPC 变量进 `.env` 与 `.env.example`；Hindsight 的镜像、卷、备份与恢复写进 runbook；凭据只进部署环境 | 未做。**同机部署时 Hindsight 必带 M-3c 的 2 核配置**：ONNX 线程补丁（或升级到含上游 b18f425 的版本后改设 `OMP_NUM_THREADS=2`）、`OMP_NUM_THREADS=2`、`HINDSIGHT_API_WORKER_MAX_SLOTS=2`、`HINDSIGHT_API_WORKER_CONSOLIDATION_RESERVED_SLOTS=1`、两项分批 8；取值与依据见 M-3 驱动 README“M-3c”一节（`.demo/observe/npc-limits-20261118/`，Test-only），写 runbook 时搬入部署配置 |
| E8 | 青岚放置：首批居民的出生点、去处与活动用青岚实际地形（离线几何先验）；客户端对话界面在青岚关卡可用 | 未做；对话 UI 只在测试地图实跑过 |
| E9 | 分发：冻结客户端 / 服务端 / 协议版本，镜像推送后本地同镜像 + 新打包客户端冒烟（含 NPC 说话主链路） | 按 Voxim 分发规则，未做 |

## 5. 测试矩阵（本层只验链路与量读数；阈值只在测试侧）

所有实跑：独占 World 与 PostgreSQL、0 个 UE、1 个 QUIC listener；运行前后记 UDP 基线与 Tcpip 4266，增长即停；首个失败阶段即停；
真实模型只经本机计数代理（M-1 第二轮除外），代理对外在途上限 8，按下表的请求上限拒绝超额请求。

| # | 场景 | 规模与上限 | 判定（是非题） | 量的读数 |
|---|---|---|---|---|
| M-1 | 6 人同场，四张已有人格卡 + 两张新卡；**活动时长按生产节奏**（每项去处停留 ≥ 60 s） | 窗口 10 min；选择 ≤ 120、日计划 ≤ 6、反思 ≤ 24、说话 ≤ 12（每类约为预计的 2 倍） | 每人选择与权威 travel、活动经历齐全；用量全部配对；交互车道无 `pool_timeout`；召回失败 0 | 选择中位 / p90 / 最长、`queue_ms`、每人每分钟请求数与 token |
| M-1b | 同 M-1，模型直连 DeepSeek（HTTP/2，不经代理；计数改读 `npc_model_request`） | 同上（由驱动在超额时停服） | 同上；`queue_ms` 为 null 不算缺失 | HTTP/2 下的同组读数（对应 E5） |
| M-2 | 8 人同场 | 窗口 10 min，上限按人数线性放大 | 同 M-1 | 看读数随人数的走向（线性 / 超线性） |
| M-3 | 生产限额模拟：release 与 Hindsight 各在 `docker run` 限额内（release `--memory 4600m --cpus 1.8`、`+S 2:2`；Hindsight 另给限额），N = M-1 / M-2 的人数，不连客户端 | 窗口 10 min | 无 OOM、无受控重启线以上的持续占用；Scene tick 速率不降 | 两个容器的内存峰值与 CPU 占用曲线 |
| M-4 | 长稳成本：3 人、生产节奏、真实模型 | 1 小时；token 硬上限由 D-3 定（到上限即停） | 用量全部配对；Hindsight 的 `llm-requests` 读回自己的模型用量 | 每 NPC 每小时 token（产品 + Hindsight）与请求次数，换算成本 |

实施前置（Test-only，不进仓库）：`npc-multi-20261118` 驱动里失效的 httpc 代码先按 `npc-slice4-20261118` 的改法修
（采样读两条车道的 Finch 实例；BEAM 离线探针核对生成 RPC 里的远程调用都存在）；M-1 优先从 `slice4` 驱动扩展，两个驱动共用的
远程调用核对脚本这次合成一份（`npc-gather-reply-20261117/verify-beam.exs` 注释里已记）。

## 6. 要用户定的

1. **D-1 首批规模**：本层实测 6 人与 8 人（建议）；进青岚的首批人数等 M-3 / M-4 读数出来再定（建议先按 3–5 人准备放置）。
2. **D-2 Hindsight 放哪**：(a) 与 voxim_server 同在生产机（省事，但 2 核 / 7.2 GiB 很紧，M-3 决定成不成）；
   (b) 另一台机器或云上实例（隔离好，多一份运维与网络延迟）；建议先做 M-3，读数出来后再选。
3. **D-3 成本预算**：M-4 的 token 硬上限（建议本轮 3 人 1 小时不超过 200 万 token，按 `slice4-03` 每次选择约 1.1k 入外推留了余量），
   以及进青岚后每天可接受的模型花费上限（需要你给数，D-3 之后才谈得上是否在产品里加额度，见 §3）。
4. **D-4 生产网络**：M-1b 是否直连 DeepSeek 跑一轮（建议是：生产就是这条路，现在完全没覆盖）。

## 7. 进度

- 2026-11-18（第十八个统筹会话）：本稿写成；`lane-01` 已通过（E1）。等 §6 的答复后按 §5 先修驱动、再离线、再实跑。
- 2026-11-18：用户答复“可以，按你计划推进”，即 §6 全部按建议：D-1 本层实测 6 人与 8 人，首批人数待 M-3 / M-4 读数；D-2 先做 M-3 再选；D-3 M-4 硬上限 200 万 token（**进青岚后每天的花费上限用户尚未给数**，进青岚前必须定）；D-4 M-1b 直连 DeepSeek 跑一轮。
- 2026-11-18：M-1 / M-2 驱动（`.demo/observe/npc-scale-20261118/`）按评审修订，仍未实跑。偏离 §5 的“代理对外在途上限 8”：
  改为按产品车道分两个 8（交互 = 选择、说话；后台 = 日计划、反思），原因是共用一个 8 时开局日计划会占满名额、把选择堵在代理里，
  读数量到的是代理自身的排队；新上界为合计 16 条对外 TCP（HTTPS，非 UDP）。另：代理给 Hindsight 单开监听口（不与模型共一个
  Finch HTTP/1 池），召回失败改为源码推出的封闭集合，判定按整窗 600 s 截断。
- 2026-11-18：偏离 §5 表里 M-1 的请求上限：放宽到每人日计划 4、反思 6、说话 3（`npc-scale-20261118/scale_settings.py` 的
  `BASE_CAPS`，M-1 合计选择 120、日计划 24、反思 36、说话 18；M-2 按人数线性放大），原因是 10 min 内日计划可能每人 1–4 次，
  原上限会把读数截成上限值。另：本场景排空与代理关闭等待都放宽到 65 s（长于产品写作超时 60 s），判定与资源核对分开落盘。
- 2026-11-18：D-3 的“每天花费上限”用户答复：没有准数，要本机实跑量出来再定。做法：M-1 / M-2 给每人每分钟请求与 token 的粗读数，
  M-4（3 人 1 小时、生产节奏、含 Hindsight 自己的模型用量）给每 NPC 每小时 token；统筹会话按当时 DeepSeek 官方价目（核原文）折成每 NPC 每天的费用，
  按 3 人 / 5 人给几档上限选项，用户选定后再按 §3 决定产品里是否加额度。
- 2026-11-18：M-1b 驱动离线部分完成（`scale.py live --direct`），未实跑。key 只经 `native start` 那一次的子进程环境 + `WSLENV`
  进 WSL，WSL 侧只按 4 个变量的白名单并入常驻 release 的进程环境（`ERL_CRASH_DUMP_BYTES=0`）；代理的模型路由在直连模式回 410；
  请求上限改由驱动读 `release.log` 计数、超出即停服并标截断；`queue_ms` 非 null 判结构失败（没走 HTTP/2）；收尾扫描运行目录
  与 stdout 日志里的 key 原串，命中即替换并判失败。边界见驱动 README 的“M-1b”一节。
- 2026-11-18：M-1（`scale6-02`）、M-1b（`scale6-direct-01`，E5 的 HTTP/2 直连）、M-2（`scale8-02`）实跑通过，六题全部成立；原始失败 `scale6-01`（测试代理复用
  Hindsight 已关的空闲连接）与 `scale8-01`（环境：端口未释放）保留。读数与证据见统筹页“扩到 6 人：M-1”一节。E2 的 6 / 8 人部分已过；E5 已过 6 人一轮。
- 2026-11-18：M-4 的 token 硬上限两次上调：驱动评审量出 Hindsight 自己的模型用量约为产品侧 20 倍（M-1b：产品 15.5 万、Hindsight 314 万），
  200 万会在第 15–20 分钟触发；用户先定 1100 万，又因停服后 Hindsight 尾巴预留 310 万会把窗口截在约 48 min，定为 **1300 万**（停服阈值 990 万）。
- 2026-11-18：M-4 实跑两次均未跑满。`scale3-direct-01`：Orca 重启杀掉驱动（release 刚起、未登记），统筹会话手动清理并补做泄漏扫描 0 命中，记环境故障
  （`interrupted.json`）。`scale3-direct-02`：第 37.4 分钟驱动 UDP 守护的采样命令一次超时（`abort`：“不能继续读取 UDP 采样 TimeoutExpired”），
  守护按 fail-closed 停服；UDP 总量全程 83–90、4266 未变，release 停、私有库删、Hindsight 后台已排空（settle 0.1 s），泄漏扫描 826 文件 0 命中。
  无判定（缺 `window.json`），**不算 M-4 验收**。用户 2026-11-18 定：采用这 37.4 分钟读数定成本，不再重跑。
- **M-4 读数**（3 人、37.4 min、直连 deepseek-flash，均为产品与 Hindsight 各自回执）：产品 139 次请求（选择 100、说话 18、反思 18、日计划 3），
  入 61.6 万（缓存命中 0.8 万）/ 出 2.8 万；Hindsight 445 次调用，入 377 万（缓存命中 232 万）/ 出 24.8 万 / 思考 31.1 万。走向：前 10 min 产品与日计划为主，
  首次 retain 后认识刷新开始，10–37 min 斜率与整段一致（每 NPC 每小时约 262–266 万 token）。合计每 NPC 每小时约 266 万 token，**Hindsight 占花费 84%**。
- **折算**（DeepSeek 官方价目 `api-docs.deepseek.com/quick_start/pricing`，2026-11-18 核对：deepseek-flash 每百万 token 高峰入缓存命中 $0.006 / 未命中 $0.3 / 出 $1.2，
  非高峰半价；高峰为工作日 UTC 01–04、06–10 点；思考是否按输出计页面未写，本折算按输出计，偏保守）：每 NPC 每小时约 $0.71（高峰），
  每 NPC 每天：全高峰 $17.2、全非高峰 $8.6、按高峰时段占比加权 $10.4。
- **D-3 定**（用户 2026-11-18）：进青岚首批 3 人，每天模型花费上限 **$50**（约等于 3 人全高峰价的最坏情况 $51）。按 §3 依据，进青岚前要在产品里加额度
  （超出即拒后台请求）——另写稿；Hindsight 的花费不经产品出站车道，额度要连它一起覆盖，是该稿的主要问题。
- 残余：驱动 UDP 守护单次采样超时即停服（保守，正确方向），长窗口下误停概率不低；下次长跑前改成“连续两次读不到才停”（仍有界）。
- 2026-11-18（第二十个统筹会话）：守护已改为连续 2 次读不到才停、PowerShell 采样超时 20 s，其余阈值不变（统筹页“第二十个统筹会话的进展”）。产品侧额度另写稿：[`2026-11-18-npc-spend-budget-decision.md`](2026-11-18-npc-spend-budget-decision.md)（待用户定）。
- 2026-11-18（第二十个统筹会话）：M-3 驱动 `.demo/observe/npc-limits-20261118/` 实跑。偏离 §5 两处（理由见驱动 README）：原生 WSL release 套用户级 systemd scope（`MemoryMax=4600M`、无 swap）+ 钉 2 颗 vCPU，而非生产镜像 `docker run`；cpu 配额 1.8 设不了（无 root），改钉 SMT 兄弟 30,31，私有 Hindsight 与私有 PostgreSQL 同钉。`limits3-01` 准备阶段失败（烘焙拷贝超时，驱动缺陷，改为跨轮不可变缓存）；**`limits3-02`（3 人，2026-11-18，release `89b74a37`）：L1–L3 过、L4 不过 → 整体不通过（行为失败，保留原判，不重跑）**。L1 无 OOM（release 与私有 Hindsight 的 oom_kill 都是 0）；L2 release 峰值 2070 MiB（出在启动加载世界，窗口内 current ≤ 392 MiB、anon ≤ 304 MiB），低于告警线 3400；L3 tick 全窗 59.999 Hz、各段 ≥ 59.99；release CPU 中位 0.18 核。**L4 的 Q4 不过**：窗口内 11 次选择因召回超时失败（`{:mind_unavailable, :timeout}`，产品召回上限 10 s），另 3 条观察召回超时，全部落在第 493–603 s；同一段私有 Hindsight 吃满两颗核（1.8 核）、内存顶到 2048 MiB 限额（`memory.events max` +2468 次回收，anon 峰值 1540 MiB），召回的嵌入与重排要在 Hindsight 里用 CPU，排不上队。不限额对照 M-1b 召回失败 0。结论：**release 本身在生产限额内宽裕；Hindsight 与 release 同挤 2 核时，它的后台工作（巩固 / 刷新）会饿死交互召回**——指向 D-2 选 (b) Hindsight 另放，或给 Hindsight 的后台工作与交互召回做 CPU 隔离。读数：选择延迟中位 1396 ms（召回成功的那些召回中位 808 ms，不限额 150 ms）；花费 42 万 token（产品 5.9 万 + Hindsight 36.1 万），约 $0.15。资源：UDP 87 → 93，4266 记录号 127958 未变，私有库 / 容器 / 卷 / scope / ext4 目录全部回收，泄漏扫描 830 文件 0 命中。证据 `.demo/observe/npc-limits-20261118/runs/limits3-02/`（`verdict.json`、`resources.json`、`limits.jsonl`、`release.log`）。6 人一轮未跑：同一配置下必然同样失败，读数价值低于花费；改为请用户先定 D-2，再按选定的放置方式跑 N = 3 / 6。烘焙缓存 `/home/dyz/npc-baked-cache/4ecf1f7864707144`（3.2 GiB，跨轮不可变，内容版本换了才删）建一次 441 s。
- 2026-11-19（第二十一个统筹会话）：**M-3c 同机 2 核配置**。查证（Hindsight 0.10.3 容器源码、上游 issue #5725 与修复 commit b18f425、ORT 线程文档）：
  0.10.3 的 ONNX 会话（嵌入、flashrank）不设线程数，按宿主物理核数开且自旋，没有环境变量能改（`OMP_NUM_THREADS` 对 ORT 无效）；召回与后台任务同进程同事件循环、无优先级。
  驱动给私有 Hindsight 加：移植 b18f425 语义的 `sitecustomize` 补丁（intra = `OMP_NUM_THREADS` = 2、inter 1、关自旋）、worker 名额 10 → 2（巩固保底 1）、嵌入与重排分批 32 → 8
  （2 / 1 / 8 为原创初值）；独立评审后补了后台积压读数。实跑（release `00670b93`）：**`limits3-03`（3 人）通过**——召回失败 0、召回中位 151 ms / 最长 5.6 s、Hindsight CPU 平均 0.19 核 / 最高 1.14、
  内存峰值 1838 MiB、积压能排空；**`limits6-01`（6 人）不通过**——召回失败 11：首次建库时 6 人 24 个建模操作挤在 2 个名额里，5 人首次选择 `life_initialization_timeout`（只在首次建库发生）；
  认识刷新期间召回超时 6 次，窗口末刷新积压仍在涨（最老 253 s）。原判保留、不重跑。明细与证据：驱动 README“M-3c 实跑结果”、`runs/limits3-03/`、`runs/limits6-01/`。
- **D-2 定**（用户 2026-11-19）：**Hindsight 与 voxim_server 同机部署，首批限 3 人**；部署时带 M-3c 配置（E7）。扩到 3 人以上前须先另放 Hindsight 或重新实测。
