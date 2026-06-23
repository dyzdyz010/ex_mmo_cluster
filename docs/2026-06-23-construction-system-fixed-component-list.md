# 建设系统 · 固定材质 + 构件清单(决策稿)

- 日期:2026-06-23
- 状态:**清单已确认(2026-06-23)**——半导体做满深度(电阻→比较器/逻辑→开关→二极管→三极管/逻辑门);管线=**电气导管/电网**(已存在、纳入),流体管线推后。下接 §4 逐 step 实现。
- 关联:[[gameplay-roadmap-and-construction-scope]](建设系统硬范围纪律 + 2026-06-23 重定向:跳采集/无限资源、先立建造系统)、`docs/2026-06-15-bevy-client-mainline-architecture.md`、[[client-implementation-directive]]、[[morphology-surface-element-track]]。
- 触发:用户「采集先不管、先无限资源、把建造系统立起来」。

## 0. recon 结论(5-agent,现状)

- **服务端建造三原语全通**:① 占位宏格/微格(NormalBlock / RefinedCell)② 贴面物体(SurfaceElement,0x08)③ 贴面贴画(= 贴面物体零体积同一套)。**prefab v2**(BlueprintCatalog + PrefabRaster,0x67)含 wire/junction/power/load 预制,多 chunk 事务化放置已测。
- **功能构件 + 涌现全在**:power_block(源)/iron(导线)/electric_load(I²R 加热)/door(通电→:open 作动)/photo_sensor(光→:illuminated→可通行、强光→热)/glowstone(冷光)/ember·torch(光+热,贴面火把)/sprout(生长)/lever(贴面开关,纯机械态)。电/光/热/化学/力学涌现都真跑。
- **半导体/逻辑:不存在**。系统纯组合逻辑(闭环→:powered、光≥阈→:illuminated,皆瞬时),无二极管/三极管/电阻/电容/比较器/锁存。
- **流体/管线:不存在**。water/steam 是静止非结构块,无 flow/pressure kernel。
- **关键缺口(客户端)**:bevy 客户端 build UX(放/拆 F/G·RMB/LMB、hotbar 1-7、raycast、预览、prefab 放置、贴面渲染)**已存在但仅离线本地**:`offline_voxel_showcase_active = !scene_joined`;**live 场景全禁用**;且客户端**不会发 VoxelEditIntent**(0x70 服务端有、客户端只发 ChunkSubscribe/Unsubscribe)。体素 op 单向 server→client。

## 1. 「把建造系统立起来」的真正主体 = 建造接线

服务端构件 + 原语齐备,客户端 UX 齐备,**就差把两端接起来**。核心工作:
- 客户端发 **VoxelEditIntent(0x70)** 放/拆单块 + **PrefabPlaceIntent(0x67)** 放预制(+ 后续贴面元件放置)。
- live 场景**解禁建造**;本地 VoxelWorld 直改 → 改为**网络发送 → 服务端权威应用 → ChunkDelta 回 → 客户端渲染权威**(server-authoritative,非本地)。
- **无限资源**(无成本、无背包,采集推后)。
- 验收:用户无法自跑 GUI → 靠**自动化测试**(wire round-trip parity + 客户端发送路径单测 + 可能的 headless e2e)+ 若可行的 Layer-3。

## 2. 固定清单(v1 提案,待确认)

按用户分类。**[有]=已存在直接用;[新]=需新增**。

### ① 材质方块(占位宏/微格,结构承重,纯建造)—— 全 [有]
`stone 石` · `dirt 土` · `wood 木`(可燃) · `iron 铁`(兼电导体) · `ice 冰`(相变) · `obsidian 黑曜`(半透,玻璃感) · `glowstone 荧光石`(发光块)。

### ② 导线 / 电路件(导电,经电路涌现工作)—— 全 [有]
`power_block 电源块`(emf 120V) · `iron 导线`(电导体;或 prefab 2×2 wire / junction) · `electric_load 加热负载`(I²R 发热) · `door 电控门`(通电→:open 作动器)。

### ③ 光 / 光敏件 —— 全 [有]
`glowstone 冷光块` · `torch 火把`(贴面,光+热) · `photo_sensor 光敏元件`(光→点亮/可通行、强光→热)。

### ④ 特殊功能元件(半导体 / 逻辑)—— [新],**做满深度**(用户已选「+三极管/逻辑门」)
分难度梯队、由易到难逐 step 落:
- 梯队 a(**纯数据 + 反应规则,零 kernel 改**):`resistor 电阻`(被动分压、不作动不发热门控) · `comparator 比较器/阈值门`(电位≥阈值→输出 tag;可组 AND/OR) · `switch 开关`(现有 lever 接入电路:拨动→通/断回路)。
- 梯队 b(**需 kernel 改**):`diode 二极管`(单向导通——ParticipantProjection/电路 kernel 方向性) · `transistor 三极管/逻辑门`(电流/电位控开关——多端接触 + 决策门控)。
- 半导体属性 append-only(可能新增 directionality / control-terminal / 阈值 等属性,catalog bump);只经 truth/field 耦合、属性派生激活、无 id 白名单(同既有正交系统纪律)。

### ⑤ 管线 / 电网(conduits)—— 电气导管 [有] 纳入;流体管线推后
**用户澄清:管线≠流体**。电气导管/电网 = `iron 导线` + prefab `wire/junction` + `power/load terminal`(已存在,纳入)。可选增 `cable/绝缘电缆`(更清晰布线)或**贴面导线**(沿面走线,需新 surface 类型 + 借导电材料)留增量。**流体/压力管线**(水/液体流动)= 独立大系统,**推后**(本轮不做)。

## 3. 已确认范围(2026-06-23)

- **半导体**:做满(电阻+比较器+开关 零kernel → 二极管 → 三极管/逻辑门,逐梯队)。
- **管线**:电气导管纳入(已存在);流体管线推后。
- 材质方块/光件 = 已存在,默认纳入。

## 4. 逐 step / phase 计划(已确认,下接实现)

- **step1** ✅:决策稿 + 用户确认清单(半导体满深度、管线=电气导管、流体推后)。
- **Phase C1 · 建造接线(核心「立起来」)**:客户端 `VoxelEditIntent`(0x70)放/拆 + `PrefabPlaceIntent`(0x67)编码 + 发送;live 场景解禁建造;本地直改 → **server-authoritative round-trip**(发 intent → 服务端应用 → ChunkDelta 回 → 渲染权威);无限资源。wire parity + 发送路径单测(+ 可行的 headless e2e)。
- **Phase C2 · palette**:hotbar/调色板从硬编 7 项扩到确认清单的材质 + 构件(理想由服务端 catalog 驱动)。
- **Phase C3 · 半导体梯队 a**(零 kernel):电阻 + 比较器/阈值门 + 开关(lever 接电路)。服务端材料/属性/反应规则 + 电路 e2e 测。
- **Phase C4 · 半导体梯队 b**(需 kernel):二极管(方向导通)→ 三极管/逻辑门(多端控)。电路 kernel + ParticipantProjection 改 + e2e。
- **Phase C5 · 客户端构件放置 + 视觉**:贴面元件/功能构件放置 UI;Layer-3 像素证(用户无法自跑)。

每 step commit(co-author `Claude Opus 4.8 (1M context)`)、测试;客户端改动必补自动化测试。

## 4b. 实现现状(as-built,2026-06-23)

逐 step commit(co-author `Claude Opus 4.8 (1M context)`),全测试绿:

- **C1 建造接线 ✅**(d2d0eec…3357208,4 子步):客户端 `VoxelEditIntent`(0x70)编码(91 字节
  镜像服务端)+ 修正 action(place=0/break=1)+ `macro_edit` 构造 + `NetworkCommand::EditVoxel`
  → runtime 译 0x70(seq 单调防重放)+ live 场景解禁建造(`live_pick` 纯 DDA 对权威 chunk
  拾取 + bridge 发 intent,**server-authoritative 无本地直改**)。服务端本就完整(gate 0x70→
  apply_intent→truth→ChunkDelta)。测试:edit_intent 4 + runtime 2 + live_pick 6。
- **C2 palette ✅**(55647f4):`BuildPalette`(服务端 material_id 直载,解耦 4-材质枚举)覆盖
  确认清单 block 形态;数字键/滚轮选;放置发选中 id。
- **C3 resistor ✅**(7a68c60):被动电阻(id20,导电 1.5 → 抬 R_effective 降电流;非 :load
  不发热/不 powered)。电路 e2e 2。
- **C4a comparator ✅**(3accce8):阈值逻辑门(id21 + 属性 logic_threshold id24,catalog v12)。
  CircuitCurrentKernel 比较节点电位 ≥ 阈 → :signal_high(模拟→数字)。电路 e2e 3。

**回归**:scene_server voxel 426/0、bevy lib 313/0、全二进制 warning-clean。

## 4c. C4b/C5 待续(honest 现状)

- **C4b 二极管 + 三极管(深半导体)**:需电路图**方向性**(diode 单向)+ **per-cell 朝向**
  (放置时存 state_flags/tag)+ **多端接触控制**(transistor 集/基/射)——触及
  `ParticipantProjection` 面连通(现无向)+ `CircuitComponentAnalysis`(现无向图)的有向化
  重构 + kernel 决策门控。是一致的电路图设计工作,需专门 design + 充分电路 e2e 验证,不宜在
  长会话尾仓促出未验证图算法。已精确定位改动面,留焦点续作。
- **C5 客户端构件放置 + 视觉**:贴面火把/拨杆放置 UI、prefab 网络放置、半导体/逻辑的视觉/
  调试 overlay、Layer-3 像素证。GUI 集成(无头不可验),需实机。

## 5. 不发散纪律

只做本清单内构件;新涌现系统(流体/磁等)、采集/资源经济、装备/合成、深半导体(若未选)一律不在本轮。清单冻结后如需加项,先回本稿改清单再做。
