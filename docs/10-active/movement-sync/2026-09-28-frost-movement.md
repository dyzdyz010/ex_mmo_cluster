# 脚部冻伤影响走跑：实施计划

分类：Global system 的实现契约；Demo、作者样本与验证属于 Test-only。
2026-09-28，用户授权先接通脚部冻伤 → 走跑减速 → 自然修复恢复。
客户端基线 f68ce06；服务端基线 56ff00d8。执行采用 writing-plans / executing-plans / TDD；遵守两仓 AGENTS 与 Voxim Docs/Testing.md，不增加逐阶段审批。

## 契约与边界

- Body 是唯一身体 owner，`movement_factor/1` 根据脚部冻伤推导：浅伤初始 0.85，深伤 0.65；`1 − (1 − initial) × max(0, 1 − frost_heal / 0.5)`。50% 修复恢复速度，剩余组织修复仍正常付账。无伤为 1，不额外处罚复活虚弱、烧伤或施法恍惚。
- Player 以当前已发布 tick + 1 为新系数的生效时刻。移动积压不能把新身体状态回填进已发布历史；同一生效 tick 的更新以可靠 FIFO 最后一个为准。
- 每个固定步只用该 tick 的系数乘基础 Profile.speed。输入力度不改、加速度/跳跃不改，走/跑均生效；不接通用 Buff 框架，不改共享 Rust 内核。
- Movement 新增 `SpeedScale`（domain 2 / kind 4），体为 identity 三个 u64、apply_tick u64、factor f64，大端共 40 字节；factor 合法范围 (0,1]、tick>0。Hello 升 32，两端一起更新。
- 新消息走既有 voxel 可靠时间线流（purpose 2），与 TimelineFence 同流保序；类型归 Movement，Gate 按类型编码，不把身体公式放进 Gate。ACK 仍等待现有 fence，因此不需要再增加 revision 或第二个 fence。
- Scene 移交的 `Session.Transfer` 也走 purpose 2：Gate 完成 seal 后把 Transfer 排进自身 mailbox，使源 Player 在 seal 回复前发出的系数与最终 Fence 先进入可靠 FIFO。仅等待 cut_tick 无法证明源的未来变化点已到达；Control/voxel 跨流先到曾会丢掉最后一条系数。
- 客户端只保存权威变化点；迟到更新从 apply_tick−1 重放，ACK 退休时保留锚点对应系数及未来变化。旧会话拒绝，Begin/End 清空，Scene 移交延续已有时间线和系数；源 cut 携带尚未消费的变化点。
- 身体 UI 保留既有伤病/愈合展示；日志新增 movement_factor、apply_tick 与实际模拟速度。首次 Demo 不依赖新的 UMG 功能。
- 不覆盖主动治疗、冲刺体力、身体持久化、浸没简化、Qinglan 分发或新的完整弱网/性能验收。

## 依据与取舍

现有 `Player`、`MmoPrediction`、CollisionApplied/TimelineFence、Relocate 已提供按 tick 回放与退休，复用其生命周期。
[Epic Networked Movement](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-networked-movement-in-the-character-movement-component-for-unreal-engine) 说明确认后用保存的移动重放；这里只采用历史输入/参数一致的原则，不引入 UE CharacterMovement 为第二物理 owner。
[RFC 9000 §2](https://www.rfc-editor.org/rfc/rfc9000.html#section-2) 只承诺单个流内字节有序，不保证跨流次序，所以速度变化必须和已有 fence 共用可靠时间线流。

## 可运行增量与验证

- [x] Body 纯推导与资源不足/加重/复活手算测试；正常 Mix 入口先红后绿。
- [x] 冻结 wire 样本、Gate 路由与 Hello32；Player 时间线与客户端回放接通。已验证到达前后、多个变化、ACK等待fence、退休、旧会话与移交；既有复活回归通过。
- [x] 正常 UE 构建与相关 Automation、正式 Mix 测试。纯 Player 回调单测组合真实 Repair/InputSlots/CollisionUpdates/Native，证明 5.2→8 m/s，不将其冒称在线 World 集成。
- [x] 独立部署匹配的新服务端；通过已有有限作者冰样本与真实采/放/移动产生冻伤。`Voxim/Saved/FrostMovement/live-04` 实跑 20 项通过：A 四阶段走跑、B 同实体旁观、采放事务、伤情/修复/营养账及 ACK。截图已实际检查；不声明分发或性能验收。

世界与测试前提：独立角色、数据库/overlay、端口与输出目录；复用不可变基底。只通过既有作者/实验 API 一次安装并记账样本，之后走正常玩法。测试可构造纯函数输入，但不能在线回填温度、营养、伤口或移动结果。

## 执行记录

- 走跑基础已完成；本次从冻伤消费者接动态权威速度。
- 现有 −25°C 冰面隔着冬靴不会冻伤，不能当作伤情夹具；正在核对由作者低温区产生有限冰样本、经玩家搬到暖区接触的合法路径。
- `Voxim/Saved/FrostMovement/`：Body RED 6 失败、Player RED 4 失败；对应实现后 Body/Player及相关回归 36 项通过，wire 7 项通过。Gate 源尾次序回归先红后绿，`--only m4a_transfer` 实际执行 11 项通过、50 项排除。
- UE 正式构建 `build-03.log` 成功；`unit-01` 44 项通过，新增组合交接回归 `transfer-red` 按预期失败后 `transfer-green` 9 项通过。二者覆盖范围有交集，不相加声称独立数量。
- 整 Body 目录未完成：既有 `repair_test.exs` 在 OTP 27 触发 `beam_asm` 内部错误（长测试名对应生成 atom），保留 `scene-green-regression.log`；未改测试规则或冒称通过。
- Hello32 受影响 wire 扩大选择共 34 项通过（`wire-version-green.log`）。
- 真实场景 `live-04`：一次记账 50 K / 1 m³ 冰，经正常采放和移动形成浅伤、深伤、50% 修复恢复全速及最终完全愈合；844 条身体样本，营养 100→78.696144 g，共同测量窗口最大 ACK 误差 0 m。详细命令、截图和前序失败在 `../Voxim/Docs/Gameplay/FrostMovement.md`。
- 100 K 首轮场景证明浅伤减速和恢复，但修复产热/血管舒张抑制继续加重，深伤等待超时；未削弱阈值。离线真实 Body/Repair + 解析接触模型选择 50 K，55/60 K 升温敏感性也能达到深伤，再用新隔离实例实跑证明。这个交互保留为后续身体数值评估依据。
