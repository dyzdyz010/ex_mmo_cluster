# 通用大脑、技能与持久记忆（2026-09-22）

分类：全局系统功能的实现与验收记录；场景、夹具和日志为 Test-only。

## 契约

一个 `Brain.Llm` 保留全部原子动词，额外工具由 `profile.skills` 提供。长任务在独立 worker 内运行，主模型只收到一次最终 Outcome，包含原调用；Body 的移动、事务、会话和资源裁决保持原入口。

`Skills.Wilderness` 直接复用 Builder 的纯状态机，终态再次读取 World。同目标可恢复存下的蓝图；蓝图不是进度真值。Builder 原入口暂留作行为对照，规划提示仅描述编辑语义，不再规定小屋的墙、屋顶、门窗风格。

Jev 的英文活动列表、判据、优先级由 profile 提供，模块不认识建造。父大脑独立询问技能是否继续；中断先等 worker 退出，再发 Body.stop，停止被拒或被替代会明确报告 stop_failed。技能结束不撤销已提交的世界事务。

remember / recall 直接读写 npc_memories；每次询问从数据库读取最近五条经历，不维护进程内便签。数据库失败成为明确结果。look 保留细化构件占用；没有 placed_by 表示无溯源记录，不能据此断言一定是天然地形。

## 当前验证

日志目录：`../Voxim/Saved/Gameplay/prefab-designer-20260922/`。

- 算法、记忆数据库、技能调度、Body：首轮联合 49 passed / 2 excluded，`npc-skills-green-attempt1.log`。
- 最终同组回归 55 passed / 2 excluded，`d4-final-gate.log`；单独提交第 4 步的 build/wilderness 版本后，暂存源码经正式 Mix 编译与相关 25 项测试通过，`d4-staged-green.log`。D2 的 design 接线另行提交。
- look 漏报细化占用：手写 material=0、refined=true、一个木 micro 的 World 投影，改前失败保存在 `d4-refined-look-red.log`。
- 真实 World：旧 Builder 两项、新通用脑荒野技能两项，共 4 passed / 16 excluded，`d4-wilderness-world.log`。48 格为 32 石、16 木；供给 40 石、20 木，完成余额为 8×512、4×512。重启后不重问规划者，现查世界续作；旧 worker 的 DOWN(:shutdown) 已断言。
- 中断先后与 stop 被替代：手排最后一条移动命令，改前 2 失败，改后相关 LLM/技能 20 passed，`npc-skill-cancel-{red,green}.log`。未知计量另有红→绿回归，最终技能 6 passed，`npc-skill-unknown-metrics-{red,green}.log`；子任务计量缺失时为 nil，已知父 Jev 请求数独立保留。
- 定义 ID：手写 32 个 0x2a，改前误当 32 个星号字符串，改后始终编码为 64 位十六进制，`d4-definition-id-{red,green}.log`。
- 真实 Jev：`mix.bat test --no-start test/gate_server/npc_jev_test.exs --include live_jev`，6 passed，`d4-live-jev.log`。共 40 次请求；35 个手工标签中 34 自动且零错、1 个低置信度升级，另 5 个情境均符合独立期望（含 harm 拦截）。

## 独立 Demo 实跑

镜像 `voxim-gameplay:prefab-d4-20260922`，容器 `voxim-prefab-designer-test`，数据库和端口沿独立旧 Demo；共享森林 Demo 未动。源码清单在 `d4-image/source-manifest.json`。该镜像同时包含尚在验收中的 D2 模块；本次 profile 仅开放 build。

真实 gpt-5.6-terra / high 从一句目标先 look，再调用 build；约 12 秒完成。放置事务 428601，正式拆除事务 428606。World 只读核对一格石宏格与一个木 micro、NPC placed_by 与部件归属；本 Demo 的库存精度是每宏格 2,097,152 单位，木 micro 手算为 4,096 单位，实际扣账一致。拆除后探测格和余额恢复，NPC 恢复巡逻。`npc_skill_outcome` 确认父脑收到最终完成结果，技能内部模型/Jev请求均为 0；主脑有 look、build 两个实际决策。

首次尝试因遗漏现有 Demo 的 cacertfile 配置，在发送 HTTP 前失败；恢复 NPC 后按 `Docs/Gameplay/server.py` 的既有流程使用 `/demo/npc-ca.pem`，保留 TLS 校验。原失败保存在 `d4-demo-ca-failure.txt` 和完整服务端日志。通过证据为 `d4-demo-attempt2.log`、`d4-demo-result.json`、`d4-demo-server-final.log`。

本增量已实现、已在真实 World 与独立 Demo 实跑。D2 三项目标、通用性和采集技能的验收另计；不能由这里的 build 结果代替。
