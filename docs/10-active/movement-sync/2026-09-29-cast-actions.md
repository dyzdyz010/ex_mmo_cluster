# 施法前摇动作与移动约束

分类：Global system 契约；回放、作者样本、录屏和本文证据为 Test-only。

用户批准前摇仅慢走、可瞄准，工具互斥，M 主动取消，结束恢复此前走跑选择；冻伤独立叠加。本轮沿既有释放时支付口径，未授权取消不扣费。不接 PvP、促愈、持久化战斗动作恢复或通用技能框架。

Player 是单角色前摇与释放授权 owner，以完整会话 identity + client_intent_seq 绑定动作。Gate 从同一编辑 worker 依序向它发消息；World 异步准备与结算，不在释放时同步回调 Player。准备／前摇中 tool_context 返回 casting；取消／死亡／移交先于授权则无支付，授权先发生则后来的取消不能撤回独立作用。授权冻结当前位置、最新方向和 Body 相干度；World 复核领域目标、权限并一次支付，caster 回执使用同一相干度快照。准备记录的进程监视在取消／授权时退休，角色离线关闭未授权施法。

Hello34 的 Movement.SpeedScale 体尾追加 input_limit:f64（48 B），范围 (0,1]。前摇0.35，常态1；输入向量限幅，限制期 jump=0，身体 factor 仍只乘 profile.speed。共享既有 apply_tick、voxel可靠时间线、Fence、ACK重放、Scene cut 与历史退休。SpellIntent action2/3 为取消／瞄准，引用原动作序号，不能改程序和目标身份。

依据：复用 [冻伤移动的已有取舍](2026-09-28-frost-movement.md) 与 [客户端动作设计](../../../../Voxim/Docs/Combat-Action-Design.md)。[RFC9000 §2](https://www.rfc-editor.org/rfc/rfc9000.html#section-2) 的单流有序性质决定约束必须与Fence同流；现有 Erlang 同sender消息顺序承载取消／授权线性化。无需第二世界真值、通用状态机或新增存储服务。

验证与真实场景详情统一维护在 [客户端执行记录](../../../../Voxim/Docs/Gameplay/CastActions.md)。本轮局部回归涵盖角色回调、World支付与目标复核、协议冻结字节和UE预测；真实双客户端经公共输入建立充电器、实际取能和施法。尚不代表Qinglan分发或性能验收。

验证完成：相关 World 24、Scene 21、Contracts 34 项通过；Native 组合测试所在 frost 文件 5 项通过（范围重叠）。真实双客户端 video02 核对取消零支付、释放一次支付、双方相同动作与投射物，以及前摇限速／释放恢复。准确日志、版本和未覆盖范围见 Voxim `Docs/Gameplay/CastActions.md`。不是完整 A1 或分发验收。
