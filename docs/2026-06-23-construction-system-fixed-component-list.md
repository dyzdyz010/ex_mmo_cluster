# 建设系统 · 固定材质 + 构件清单(决策稿)

- 日期:2026-06-23
- 状态:**待用户确认清单**(用户硬 gate:先定固定清单、只做清单内、不发散)
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

### ④ 特殊功能元件(半导体 / 逻辑)—— 多为 [新],**需拍板深度**(见 §3 Q1)
- 最小集(**纯数据 + 反应规则,零 kernel 改**):`resistor 电阻`(被动分压、不作动) · `comparator 比较器/阈值门`(电位≥阈值→输出 tag,可组 AND/OR) · `switch 开关`(把现有 lever 接入电路:拨动→通/断回路)。
- 进阶(**需 kernel 改**):`diode 二极管`(单向导通) · `transistor 三极管/逻辑门`(电流控开关)。

### ⑤ 管线(pipes)—— **无流体系统**,需拍板(见 §3 Q2)
v1 提案:**不做流体管线**(fluid/flow 系统是大工程);若要"管线"先只做**装饰管道块**(无传输)或推后。

## 3. 待用户拍板的范围岔路

- **Q1 半导体/逻辑深度**:最小集(电阻+比较器+开关,零 kernel) / +二极管(单向,需 kernel) / +三极管逻辑门(最强最难) / v1 先不做半导体。
- **Q2 管线/流体**:v1 不做(推后) / 只做装饰管道块 / 做流体系统(大)。
- (材质方块/导线/光件 = 已存在,默认纳入,不必逐项确认。)

## 4. 逐 step 计划(确认清单后细化)

1. **step1**:决策稿(本文件)+ 用户确认清单。
2. **建造接线**(核心):客户端 VoxelEditIntent/PrefabPlaceIntent 编码 + 发送;live 场景解禁;server-authoritative round-trip;wire parity 测 + 发送路径测。
3. **palette**:hotbar/调色板纳入确认清单的材质 + 构件(现 hotbar 硬编 7 项 → 扩到清单)。
4. **新构件**:按确认的半导体深度 + 管线决定实现(优先零-kernel 的 电阻/比较器/开关)。
5. 每 step commit、测试;客户端改动补自动化测试(用户无法自跑)。

## 5. 不发散纪律

只做本清单内构件;新涌现系统(流体/磁等)、采集/资源经济、装备/合成、深半导体(若未选)一律不在本轮。清单冻结后如需加项,先回本稿改清单再做。
