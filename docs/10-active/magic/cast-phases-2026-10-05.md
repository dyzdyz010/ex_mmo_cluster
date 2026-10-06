# 施法分段

分类：Global system 实施记录。批准设计与共同测试计划见 Voxim `Docs/Gameplay/CastActions.md`、`Docs/Magic/CastPhases-plan.md`。

目录 v4 增加最终定形到出手帧的 `release_lead_s`；Cost 将该时长及最终结构维护费纳入同一次报价。Player 使用完整前摇授权，World 保持一次支付与现有取消语义。客户端同目录摘要读取时长，PropertyBatch 步骤格式和 Hello35 不变。

验证：手算零距离 1000 W × 0.25 s = 250 J；原有 Magic Cost/World/取消测试；双端正式输入核对出手帧与事务。性能与分发不在本次范围。

## 触散与驻留（2026-10-05）

Global system：新增终结符 `act.break_on_hit`（〈触散〉，act/semblance，无槽，权重 1，姿态 `[45,90,-90,135,-90,90]`）。仅 `form.semblance + act.throw + act.break_on_hit` 合法；原来的两步投掷继续驻留。触散物理支出为 0，正常计结构、构型损耗与前摇。UE 发布目录 `badc8a074db08d5abcc425178aebebfd36486305329c210031f49cb22ea7bd76` 同时保留 `hot_throw` 并加入三步 `fireball`。

World 在运行记录上携带可选 `break_on_hit: true`，沿既有模拟飞行端点调用 `Thermal.release_semblance`，一次移除并释放显热、动能和未用发光预算。零飞行命中先广播有落点的创建记录，第一热步在推进任何模拟时间前散解。到期与驱散保持原语义；旧记录未带该键时驻留。协议 Hello36：拟态记录 shape 后增加 `break_on_hit:u8`（只能 0/1），每条 135 B；手写冻结样本验证编码、解码、删除补零和旧版本拒绝，客户端必须使用同版本。

设计对照：[Epic UProjectileMovementComponent](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UProjectileMovementComponent) 的停止事件将碰撞停止与后续效果分离。本项目采用同样的职责边界，但碰撞与能量权威仍在 World；UE 只消费轨迹和触散标记。没有通用触发器框架，没有身体碰撞冲量或击退；动能沿已有规则转为热量。轨迹仍在施放时按当时世界预解，后续几何变化不重算。

Test-only：手写目录 `19c513f9…` 扩展既有规则夹具；`badc8a07…` 是 UE 发布原字节。`magic_semblance_test.exs` 验证合法形态、纯值命中端点与 53485 J 手算守恒，`magic_semblance_world_test.exs` 经正常施法入口验证创建/删除事务、叶获热、光账、一次释放及立即命中。运行器：`../Voxim/Saved/CastShowcase/mix-dual.sh voxel_region test --no-start test/magic_semblance_test.exs test/magic_semblance_world_test.exs`；协议为同入口 `mmo_contracts test --no-start`。红绿原始输出在 `../Voxim/Saved/CastShowcase/impact-*.log`。这些模块场景不替代真实双客户端、画面或分发验收。

碰撞结束观察修正：固定 0.5 s 模拟提交可能早于客户端墙钟轨迹终点；创建与删除也可能在同一显示帧被合并，因此普通 nil 删除不足以表达碰撞。Hello36 尚未分发，沿用 135 B 行，将 live 扩展为 `0=普通删除、1=存活、2=碰撞结束完整快照`。碰撞最终记录只暂存于本次 `thermal_run.impacts`，提交时覆盖对应 nil；不进入 `thermal.semblances`，不参与能量计算，也不在重启后恢复为存活对象。客户端消费明确 kind2 事件，直接使用确认落点，不从消失或本地 flight_s 时钟推断碰撞。kind2 必须带 break_on_hit=true，完整快照不得包含事件；寿命到期与驱散仍为普通删除。回归覆盖正常及立即命中、一次事件、无创建前态的自足结束快照、空间投影、重启不复活、过期/驱散原因和冻结线上字节；红绿日志为 `impact-end-*.log`。

Replica 物化边界：kind2 和 nil 都从副本存活表删除；原始 kind2 delta 仍正常转发并保留于有界事务历史，用于已有订阅及前缀追赶，后来订阅的完整快照不得带结束事件。真实 World→Replica→订阅测试已先复现旧快照错误保留 kind2，再验证转发、历史和空存活快照；日志为 `impact-replica-*.log`。

## 飞行期间命中人物（2026-10-05，已实现，真实双端待验收）

批准范围是触散球命中当前正常移动的玩家。World 保有拟态及能量真值，Scene/Player 保有当前胶囊、会话、生命代次与完整身体。新触散球按 World 定时器推进实际经过的短飞行段；同一轮只有一个异步人物采样，不重叠结算。目标不在施放时锁定。当前段首先受 canonical 地形限制，再从当前 Scene 的合法人物胶囊中取首个球扫掠命中，排除施法者，沿工具的显式战斗域规则。未带新来源标记的已保存拟态和驻留投掷继续原热流程。

依据：[Rapier shape casting](https://rapier.rs/docs/user_guides/c/scene_queries_shape_casting/) 将形状扫掠的首次接触参数作为结果，并明确起始重叠语义；这里复用既有解析胶囊射线，将半径与半高增加球半径，避免新增物理引擎。只对当前采样姿态做短段扫掠，不宣称连续移动目标 CCD 或延迟补偿。[OTP gen_server](https://www.erlang.org/docs/27/system/gen_server_concepts.html) 的同步调用等待回复；World 与 Scene 之间使用异步查询工作，避免 Scene 正在等待 World 时形成环形等待。

命中剩余显热、未用辉光及动能统一转入现有 Body 的局部组织 `tissue_j`。动能沿完全非弹性转热，无独立机械伤或击退，不创造固定火球伤害或第二套 HP。World 转给身体后不得同时沉积到地块或环境。Body 仍按既有 1 Hz 热剂量与急性组织进展推导烧伤和生命；这不模拟组织汽化、爆炸范围或按头腿区分的热组织块。

必要持久边界：World 先冻结命中目标/生命/会话与待交付能量，再由当前 Player 接纳并将去重收据与待吸收热同笔存档；World 收到接纳结果后最终移除，广播既有 kind2 及双方相同的 ProjectileHit。中断恢复重新交付同一不可变收据，不能重新选中另一个目标。旧生命/旧 owner 未接纳时释放到环境，不能转给新生命。Hello37，Session kind14，108 B payload：identity、world_seq u64、projectile_seq u64、projectile_n u32、source_id/source_life/target_id/target_life 各 u64、q_j f64、position 三个 canonical f64；无部位字节。身体状态继续使用 BodyState。

最小证伪：手算球/胶囊首次接触、移动后擦过；当前 owner/生命拒旧、持久去重和焦耳守恒；真实 World 的地形优先、当前人物进入/离开轨迹、创建至命中的时钟、一次 kind2 与双方同一收据。日志统一 `../Voxim/Saved/CastShowcase/combat-*.log`。真实双客户端由 Voxim 正式组合根继续完成，模块测试不作为实跑结论。

实际时钟与显示：每次采样覆盖从上次年龄到实际墙钟年龄的整个区间，以最多 50 ms 的重力弦段求交，不截掉 RPC/提交耗时。实时球初始 `flight_s=lifetime_s`、`rest=寿命末弹道位置`、`contact=nil`；施放时原地形 trace 仅用于已有范围与地块权限检查，不把未来地形预览当 confirmed 碰撞。眼到手被挡住时初始球心置于原面外，防止生成点越墙。当前短段地形仍是原有中心射线，人物为球半径膨胀胶囊；这不是完整球与体素形状扫掠。碰撞冻结后先广播落点，确认身体接纳后再发 kind2，客户端触散音画只消费 kind2。

恢复与交付：`impact_delivery` 是拟态内不可再消耗的冻结交付记录；期间不继续冷却、接触换热或允许驱散。目标暂时离线/移交中时保持原记录等待，不把“未答复”当作未入账。`WorldServer.Movement.character_owner/1` 经已配置 Scene 的成员查当前最高会话 owner，不另存角色路由真值。Player 先查持久收据，再判新接纳的 life/session/战斗域；因此承伤后重登或跨 Scene 移交仍返回旧回执而不再吸热，未接纳的旧身份明确拒绝。身体存档 v2 追加收据表，显式读取既有 v1；完整身体仍由同一 owner 存档。已接纳的 q 同时计入 World `projectile_body_j`（分项）和 `body_exchange_j`（身体总流入），只在拟态 `semblance_released_j` 出账一次；分项不能再叠加为一份额外能量。拒绝项为 `projectile_rejected_j`。

已观察验证（2026-10-05）：原始红灯 `combat-body-red.log`（缺少扫掠/接纳）与 `combat-wire-red.log`（Hello36）；首次 World 回归发现 nullable 对象误用严格 `not`，保留于 `combat-world-first.log`，修复后 `combat-world-green.log`。正式 Mix 图、隔离 DB：`scene_server` 的 ToolHit/ToolAction/Snapshot 11 项通过；`world_server` 的 `p0_body_world_test.exs` 3 项通过，实际 Native 移动后采到目标新位置和非零速度、双方回执相同、PG 身体存档重登去重、真实跨 Scene 移交后重投去重；`voxel_region` 的 magic_semblance/magic_semblance_world/magic_cost/magic_world/world 61 项通过；`mmo_contracts test --no-start` 136 项通过。后补 World 冻结交付不能驱散、重启恢复同一目标/金额，定向 3 项通过（`combat-world-persistence.log`）。World 测试仅替换人物查询和时钟，真实 World/NIF/日志未替换；真实 Player 测试用纯弹道输入验证组合边界，不冒称正式施法双客户端已验收。

正式镜像 `voxim-server:20261005-combat-projectile`，image id `sha256:5e23de6321af5edcc8fa18e6eb5ef5a566fc036a1b94e7827f60299cdb57e30a`，构建 exit0，日志 `combat-server-build.log`；Hello37，UE 目录 `71ca543b42db5ca5b1b8fea62771aa0c256399b2fa00c0525eccb4d9953860a7`。没有修改魔法 Cost 或目录参数。实际正式 Cost 对比由 `combat_speed_quote.exs` 执行：fireball 前摇 2.9759839847→2.0762897908 s，报价 445361.3299→438968.3333 J，日志 `combat-speed-quote.log`。镜像已交 Voxim 主任务开始真实双客户端闭环；本记录不把构建/模块绿灯写成双端或分发验收。
