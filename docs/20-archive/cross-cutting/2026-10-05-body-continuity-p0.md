---
status: archived
---

# 身体连续性 P0

分类：全局系统功能；测试与实验夹具为 Test-only。

契约：Player 仍是唯一身体 owner。跨 Scene、重登和服务重启保留完整身体与已吸收食物游标；World 已提交的扣料必须恰好吸收一次。用户确认离线冻结：不按离线墙钟补算伤病、营养、体温和复活。重登入场沿原出生规则，不保存移动位置或旧模拟 tick。死亡身体在重新在线后的下一次既有 1 Hz 身体推进复活，弱化/恍惚剩余秒数属于 Body。

## 最短实现

1. 食物收据与扣料同笔进入现有 OverlayLog，以 content_version、cid、seq 定位；canonical snapshot/delta 携带内部收据，客户端 wire 不变。本增量保留收据历史，不另造投递平台或回收协议。
2. Player 消费本角色收据，身体和按世界区分的消费游标同笔保存。DataService 只存版本化不可变身体字节，存档以 cid 为键，session_epoch 拒绝旧 owner 写入。prepared 目标不持有写权。
3. seal/正常退出异步请求 World 停止旧 PID 接触，收到同一发送者的 fence 后保存待吸收热量并交出身体。新 owner 激活时立即注册当前接触；禁止 Player 同步调用 World（World 已有反向 tool_context 调用）。
4. 每次可观察身体变化先保存再发布/回复。异常冷重启读取最近已提交身体；已扣料未处理的收据从 World 快照继续消费。

## 依据与边界

- [Erlang OTP27 信号顺序](https://www.erlang.org/docs/27/system/ref_man_processes.html#signals)：只保证同发送者到同接收者的顺序，因此使用 World 发出的 detach fence，不依赖来自 Gate 的 seal 与热消息顺序。
- [PostgreSQL16 INSERT](https://www.postgresql.org/docs/16/sql-insert.html#SQL-ON-CONFLICT)：用原子 UPSERT 获取角色存档写权，再以相同 epoch 条件更新，阻止移交/重连旧会话覆盖新身体。
- 正常 Mix/Rust 构建图，独立 PostgreSQL 与可写世界目录。存档不复用旧 HP/SP/MP；没有第二世界真值、自动重试或新玩法数值。
- 不承诺跨数据库与热内核的分布式原子提交；本项验证待处理热在正常退出和移交切点不丢失。食物提交与身体吸收之间的崩溃恢复单独覆盖。

## 验证

- 纯数据：完整 Body/待吸收热/生命代次/分世界游标编码；不恢复会话位置与 tick；未知版本显式失败。
- 数据库：首次角色、重载、旧 owner 拒写、独立角色、Repo 重启读回。
- 模块接缝：真实 World 扣料收据重放与 checkpoint；Player 在 fence 前收热、完整 cut；Scene 重连和两个 Scene 的单一 owner；重复/跨世界收据不重吃。
- 真实入口：独立服务与双客户端正常攻击、采食、重连、冷重启；正常移动跨 Scene。纯模块测试不得冒充这些场景完成。

2026-10-05：以上全局系统功能已实现，相关自动化回归通过，真实双客户端已验证正常准星攻击、同角色重登、同一服务容器冷重启、正常背包进食与步行跨 Scene。P0 按本页边界收口。

### 自动化结果

均沿正式 Mix／Rust 构建图运行，`MIX_ENV=test`、`--no-start --seed 0`，使用独立 PostgreSQL；Gate 原有 `live_llm`／`npc_scale` 标签保持默认排除，未计为通过。

下表服务端 `.demo/` 日志保留在本轮实现工作树 `ex_mmo_cluster-p0/`，客户端日志在兄弟目录 `Voxim/`；集成后不复制整套原始证据。

| 范围 | 观察结果 | 原始日志 |
| --- | --- | --- |
| DataService `body_store_test.exs` | 5 项通过；真实 PostgreSQL 与 Repo 重启 | 本轮工具终端保留改前 5 项失败、改后 5 项通过及退出码 0；未另存日志文件 |
| Scene `body/snapshot_test.exs`、`movement/` 与 `prefab_designer_test.exs` | 首轮 137 项中 19 项失败：12 项缺现有 fixture 环境变量，7 项未消费新增的入场 BodyState。补齐环境及显式检查入场状态后定向复跑；最后碰撞时间线 8 项通过 | `Voxim/Saved/P0Body/Environment/scene-regression.log`、`scene-regression-2.log`、`scene-collision-final.log` |
| Scene `movement/p0_body_lifecycle_test.exs` | 5 项通过；伤害落盘后 kill、重登、食物去重、两个 stop／Gate DOWN 共用热 fence、跨世界游标 | 本轮工具终端保留 5 项通过及退出码 0；未另存扩展后日志文件 |
| Scene `movement/voxim_player_test.exs` | 8 项通过；独立反例先证实首次 anchor 前处理尾部收据会漏掉 1000 J，修复后完整吸收 3000 J | `.demo/observe/p0-review-20261005/body-anchor-{red,green}.log` |
| World 扣料／接触热／日志恢复 | 相关 92 项通过；另以反例证实死亡 PID 原先继续换热，修复后接触热文件 10 项通过 | `.demo/observe/p0-world-red-20261005/wsl-regression-2.log`、`wsl-dead-contact-{red,green}.log` |
| World `movement/p0_body_world_test.exs`、`voxim_transfer_test.exs` | 各 2 项通过；真实 World＋两个 Scene＋Native＋PostgreSQL，包含已扣料、尚未吸收时 kill 与快照恢复 | 同目录 `wsl-integration-final.log`、`wsl-transfer-regression.log` |
| Gate `npc_body_test.exs`、`npc_body_world_test.exs`、`npc_skill_design_test.exs` | 实际执行 37 项通过，原有 7 项排除 | 同目录 `wsl-gate-npc-final.log` |

复现：在对应 `apps/<app>` 目录执行 `mix test --no-start <上表测试文件> --seed 0`。已有场景 fixture 环境按 `Voxim/Docs/Testing.md` 配置；本机调用为 `wsl -d Ubuntu-22.04 --exec /bin/bash <Voxim>/Saved/P0Body/Environment/mix.sh <app> test --no-start <测试文件> --seed 0`，隔离缓存与数据库参数保存在该脚本。旧失败日志保留，不以重跑覆盖。

### 真实客户端结果

`Voxim/Saved/P0Body/final01/verification.json` 记录新角色 A `29746008065` 与 B `30614228995`：A 经准星／正常输入命中 B 躯干，双方回执与 authority 同一笔命中逐字段一致，生命 80／可恢复 20。B 重登后保持外伤和生命代次；同一容器真实 stop/start 前后，两人的完整身体存档逐字节不变，冷启动后新会话继续恢复。`offline-freeze.json`、`restart.json` 分别记录完整字段与真实进程重启。画面已检查，截图位于 `Voxim/Captures/P0Body/20261005/final01/`。

该场景使用本地独立服务镜像 `sha256:52a48a051ae08ebba56acda9967dbdd649b2c9e083c98d1223eab24d1d052059`，对应身体持久化、收据与热 fence 实现；随后新增的非 streaming 首 anchor 修复由上述红绿回归及更新镜像的跨 Scene 场景单独验证。没有使用共享 D3 服务或其数据库。

最新镜像 `sha256:657fa219fc564ba5cd6900774514111368fabf1ffa70ae6a7c6c4da74e59120a` 的 `Voxim/Saved/P0Body/food01/`：A `830174400513` 正常准星采集自然蒲公英，B `830828711939` 观察同一笔移除；A 在背包右键吃一株，仅有一次 `body_food`（seq 47、75362.4 J），再从 X=69.5 m 实际步行到 72.5 m，Scene 1→2 commit 的 `logical_delta=0`，两侧食物游标均为 47、生命代次均为 40。A 正常摆木／点火产生非零接触热，最终 World 与 Player 累计热账约 3596.19400568 J、差约 5×10⁻⁹ J。两客户端回放成功、退出码 0，进食与过界截图已实际检查，保存在 `Voxim/Captures/P0Body/20261005/food01/`。

保留该场景的首次判定失败：临时判定把相隔数秒且持续受热的组织温度差要求为 <1 K，此阈值没有契约依据；实际 322.862→323.917 K。显式撤销这条错误期望，按既有 World／Player 换热账和完整移交事件核对连续性，不修改产品数值，也不将“温升为正”单独当作通过证据。

正式离线判定 `python Docs/Gameplay/body_transfer_check.py Saved/P0Body/food01` 通过，结果为 `verification-recheck.json`；删去唯一吸收事件或唯一目标 Scene 恢复事件的两个反例均被拒绝。退出后完整存档与 World 热账均精确为 3596.194005678046 J；真实场景没有逐字节采集 transfer cut 的 pending heat，该精确语义由真实 World／Scene 集成回归证明。复现入口为 Voxim `Docs/Gameplay/body_continuity.py`、`body_transfer.py`，独立测试服务沿正式 Dockerfile 构建。

未扩大为弱网／容量 benchmark 或 Qinglan 打包分发验收；食物收据历史回收也不属于本次 P0。
