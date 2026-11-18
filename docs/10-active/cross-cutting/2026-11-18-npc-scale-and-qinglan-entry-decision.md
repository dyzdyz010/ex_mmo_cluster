# NPC 扩到 5 个以上与进青岚的最低标准（2026-11-18）

分类：薄片四“多 NPC”这一层与生产化入口的决策稿（只定目标、规模、预算与测试矩阵，不调取值）。状态：**待用户定（§6）**。
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
| E3 | 生产限额下的内存与 CPU：World + N 个 NPC + Hindsight 峰值低于告警线 3400 MiB（或 Hindsight 另放，见 D-2） | 未测；M-3 |
| E4 | 每 NPC 每小时的 token 与请求次数（含 Hindsight 自己的模型用量），按生产节奏外推成本，在 D-3 的预算内 | 未测；M-4 |
| E5 | 生产网络路径（HTTP/2 直连 DeepSeek）下 N 人同场无排队失败、无取消残留 | 未测（实跑都经本机明文代理，走 HTTP/1）；M-1 改一轮直连 |
| E6 | 分支合并 master、CI 全绿 | PR #11 draft，181 提交 |
| E7 | 部署：NPC 变量进 `.env` 与 `.env.example`；Hindsight 的镜像、卷、备份与恢复写进 runbook；凭据只进部署环境 | 未做 |
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
