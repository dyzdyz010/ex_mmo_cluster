# S3 设计:actuator 正交化(2026-06-16)

正交架构(`2026-06-16-orthogonal-systems-architecture.md`)第三刀。把 R9b 的门从「per-device
规则 + 硬编码碰撞分支」收敛成**可组合元件**:设备 = 材料属性 + actuator 声明 + tag→物理绑定(数据),
不再每加一个设备写一对规则 + 改一处碰撞代码。

## 1. 现状(要收敛的 coded 行为)

- **door_open / door_close**:2 条 per-device `tag_reaction` 规则(material: :door,require [:powered]
  forbid [:open] → add :open;require [:open] forbid [:powered] → remove :open)。每加一个设备
  (piston/gate/lift)= 再写一对。
- **`:open` → 可通行**:**硬编码**在 `ChunkProcess.collision_query_hit`(`open_passable?` 检查 `:open`
  tag id)。每加一个「可通行态」= 改一处碰撞分支。

## 2. 设计(两个正交的声明层)

### Part A:声明式 tag → 物理属性 绑定(passability)
- 新模块 `SceneServer.Voxel.TagPhysics`:声明哪些 tag 蕴含哪些物理属性。S3 只需 **passability**:
  `passable_tag_names/0 → ["open"]`(append-only),`passable?(storage, tag_set_ref)` 查 cell 是否带
  任一「可通行」tag。
- `collision_query_hit` 改为调 `TagPhysics.passable?`(去掉硬编码 `:open` 分支)。**任何**未来「可通行
  态」(碎墙、开启的闸门)只需把其 tag 加进 `passable_tag_names`,不改碰撞代码。
- (未来可扩展同表加 transparent→透光、porous→流体可渗 等,本步只做 passable。)

### Part B:通用 actuator(机械响应)元件
- 新模块 `SceneServer.Voxel.Reaction.Actuator` + `Actuators`:声明式执行器规格,而非每设备手写 2 规则。
  一条 `Actuator` 规格:
  ```elixir
  %Actuator{material: :door, trigger_tag: :powered, active_tag: :open}
  ```
  语义:材料 == material 的 cell,**有 trigger_tag → 置 active_tag;无 trigger_tag → 去 active_tag**
  (powered↔open 状态机)。
- `Actuators.to_rules/0` 把每条规格**展开成两条既有 `tag_reaction` Rule**(activate:material+require
  [trigger] forbid [active] → add active;deactivate:material+require [active] forbid [trigger] →
  remove active)。**Engine 不变**——仍消费 Rule;actuator 只是更紧凑的声明层。
- `Rules.all/0` = 基础物理规则(相变/燃烧)++ `Actuators.to_rules()`。门的 2 条规则**从 1 条 Actuator
  规格生成**;删 rules.ex 里手写的 door_open/door_close。
- 新设备 = **加一条 Actuator 规格**(+ 若有新可通行态,加一个 passable tag)。piston/gate/lift 都是
  `%Actuator{material: X, trigger_tag: :powered, active_tag: :extended/:raised/...}`。

### 组合涌现(正交)
通电门 = `door` 材料(:load,S2 属性派生)+ `Actuator{:door,:powered,:open}`(机械响应)+
`TagPhysics :open→passable`(碰撞绑定)。三个独立声明层组合出「接通电路 → 门开 → 可穿行」,
**全是数据,无 per-device 代码**。circuit→:powered(R7)→ actuator 置 :open → 碰撞读 passable。

## 3. 迁移

- rules.ex:删 @door_open/@door_close 手写规则;`Rules.all` 末尾 `++ Actuators.to_rules()`。
- 新 `Actuators`:`@all [%Actuator{material: :door, trigger_tag: :powered, active_tag: :open}]`。
- chunk_process.ex:`open_passable?` → `TagPhysics.passable?`(读「可通行 tag 集」而非硬编码 :open)。
- 测试:door e2e 不变照过(通电→开→可穿,断电→关→阻挡);加 Actuator 单测(规格展开成正确 2 规则)
  + TagPhysics 单测(passable tag 判定)+ 一个**第二设备**测(如 piston:加 1 条 Actuator 规格即得
  powered↔extended,无新规则/碰撞代码)证可扩展。scene 全量 0 净回归。

## 4. 不影响 / 范围

- 不改 Engine、SystemActor、circuit/I²R(S1/S2)。
- trigger 暂仅支持 tag(:powered);阈值触发(温度等)作后续。
- active_tag→物理绑定本步只做 passability;transparent/porous 等同表后续接。
