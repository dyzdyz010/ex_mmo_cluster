# Bevy 客户端架构重整决策稿:域化模块 + 会话层 + 消灭 god-resource

- 日期:2026-06-25
- 状态:**决策稿(实施中)**
- 作者:客户端架构
- 关联:`docs/2026-06-15-bevy-client-mainline-architecture.md`(bevy 转主线)、`clients/bevy_client/src/README.md`
- 触发:用户审查认证管理 → 暴露「无专门认证/会话模块、无令牌生命周期」+ 整体 `WorldState` god-resource 耦合

---

## 1. 现状判断(基于 2 份实读测绘)

客户端 ~3.6 万行、Bevy 0.19、21 个顶层模块,**底子成熟**:严格 Plugin 化(`BevyClientPlugins` 聚合 23 插件)、
统一 `ClientSet` 帧序调度、net 线程边界干净(`ClientRuntime` 状态机与 socket 分离)、voxel 教科书式分层
(core→world/authority→wire→render)、近乎零债务标记、过半文件带测试。**不是失控型混乱。**

但有三处明确的结构债,且都与"模块职责清晰"直接相悖:

1. **`WorldState` god-resource(头号债)**`app/mod.rs:78-119`:30+ 字段把**连接状态 / 本地玩家 / 远端玩家表(3 map)/
   4 条日志队列 / 网络遥测 / voxel-AOI 锚点**全塞一个 Resource;**10 个域插件** `ResMut<WorldState>` 它 →
   最大耦合点 + 并行调度瓶颈(任何两个写它的 system 不能并行)。加新状态最易往这堆。
2. **无认证/会话模块**:认证散在 `auth_client.rs`(HTTP)+ `login.rs`/`main.rs`(发起)+ `net/`(握手);
   `SessionCredentials` 塞在通用 `config.rs`。**令牌不透明、不解析过期、零刷新、断线即线程退出无重连无重认证**
   (用户看到的 "please restart" 即此)。身份对模块"碰巧透明"(net 线程独占 creds + `NetworkCommand` 不带
   token),但**没有可复用的会话/身份 facade**——那一层是空白。
3. **`app/mod.rs` 仍是 781 行事实组合根**:`setup` 巨函数手写整个场景(光照/相机/HUD/准星);
   `InputPlugin`/`ObservePlugin` 是空 stub,输入散落 voxel/skill/movement。重构自承"进行中"。

---

## 2. 重整目标与总纲

**总纲:每个功能域 = 一个模块,各自拥有「state resource(s) + plugin + systems + OnEnter 装配」;消灭跨域
god-resource(`WorldState` 拆解删除);net 是服务器唯一出入口;身份与连接生命周期收口到新 `session` 模块。**

判定一个模块"职责清晰"的硬准则(本稿验收口径):
- **(R1 单一所有权)** 一个状态字段只属于一个域;**任何 Resource 不得聚合 >1 个域的字段**。
- **(R2 域自治)** 域插件拥有自己的 state、systems(挂正确 `ClientSet`)、`OnEnter(AppState::Game)` 装配;
  不在 `app/mod.rs` 里手写。
- **(R3 net 唯一网关)** 一切服务器 I/O 走 `NetworkBridge`;凭据/身份只在 net 线程或 session 层附加,
  业务域零感知。
- **(R4 显式依赖)** 跨域只读用 `Res<OtherDomainState>`,跨域写用 Event/Command,不用共享可变大对象。

---

## 3. 目标模块所有权图(target)

| 模块 | 拥有的 state | 职责 |
|---|---|---|
| **`session/`(新)** | `SessionCredentials`、`ConnectionPhase`(状态机)、`SessionConfig` | 认证流程(吸收 `auth_client`)+ 凭据 + **连接生命周期(连接/握手/进场/断线/重连重认证)**;向 net 提供当前有效身份;唯一"我是谁、连没连上"的真相源 |
| `net/` | `NetTelemetry`(rtt/offset/transport,**从 WorldState 迁入**) | 纯传输:TCP/UDP、bridge、`ClientRuntime` 状态机。**不再拥有 creds**(从 session 取);不再拥有连接"业务态"(交给 session) |
| `world/` | `LocalPlayerState`(cid/pos/vel/hp/alive,**迁入**)、`RemotePlayers`(3 map,**迁入**) | 玩家域运行时:本地 + 远端 actor 状态 |
| `voxel/` | `VoxelAoiState`(subscribed_center/aoi_anchor,**迁入**)+ 既有分层 | 体素世界(已良好分层,仅收回散在 WorldState 的 AOI 字段) |
| `hud/` | `GameLogs`(chat/combat/effect/skill/logs,**迁入**) | HUD + 日志聚合 + 编辑反馈 + 热键栏 |
| `chat/` `skill/` `movement/` `camera/` `presentation/` `effects/` | 各自既有小 state | 域插件,职责不变,改为读各域 Resource 而非 WorldState |
| `input/` | 输入意图 Resource | **填实**(收口 voxel/skill/movement 的原始输入解析),或并入各域并删空 stub |
| `app/` | 仅组合根 | `BevyClientPlugins` 装配 + `ClientSet` 调度;`WorldState` **删除**;`setup` 拆成各域 `OnEnter` |
| `stdio/` `headless/` | — | 自动化入口,读各域 Resource(不再读 WorldState 单点) |
| `config.rs` | `ClientConfig` | 仅环境配置;`SessionCredentials` 迁出到 `session/` |

`WorldState` 的 30+ 字段去向:连接/进场态→`session::ConnectionPhase`;本地玩家→`world::LocalPlayerState`;
远端→`world::RemotePlayers`;日志→`hud::GameLogs`;遥测→`net::NetTelemetry`;voxel-AOI→`voxel::VoxelAoiState`。
**拆完即删 `WorldState`。**

### 3.1 `session/` 模块设计(连接生命周期状态机)

```
ConnectionPhase(单一真相源,替代散落的 status/scene_joined + net 的隐式态):
  Offline → Authenticating(HTTP auto_login) → Connecting(TCP) → Handshaking(AuthRequest)
        → EnteringScene → InScene
  任意失败 → Reconnecting{attempt, backoff}(退避;凭据失效则先重认证)→ 回 Connecting/Authenticating
  连续失败超阈值 → Failed{reason}(此时才提示用户,而非一断就退)
```
- `SessionPlugin` 持 `ConnectionPhase` + `SessionCredentials`;驱动 net 线程的**起/停/重连**,而非 net 线程
  自行 `return` 退出。
- 身份 facade:net 需要凭据时向 session 取(或 session 在重连时把新 creds 注入 net),业务域永远零感知。
- **令牌生命周期**:dev 路径下"重认证"= 重新 `auto_login`(无密码,客户端可自足);若服务端将来下发
  `expires_in`/JWT exp,session 在到期前主动刷新。**真正的 refresh-token 端点属 auth_server 改动**,本稿
  客户端侧先做"断线→退避重连→(凭据失效则)重 auto_login"闭环,消除"please restart"。

---

## 4. 分阶段实施(逐 step commit,不 push,cargo test 绿)

> bevy 客户端测试是 `cargo test --lib`(无 DB,不碰 dev 库)。每阶段保持 lib 测试绿。

- **阶段 1 — `session/` 模块骨架 + 认证收口**:新建 `src/session/`,迁入 `SessionCredentials`(从 config),
  新建 `ConnectionPhase`(吸收 WorldState 的 `status`/`scene_joined`),`auth_client` 折入 `session::auth`。
  `SessionPlugin` 装配;net/login/app/stdio 改用 `ConnectionPhase`。**结构与所有权先到位,行为不变。**
- **阶段 2 — `WorldState` 拆解**:逐域迁出字段 → `net::NetTelemetry` / `world::LocalPlayerState` +
  `RemotePlayers` / `hud::GameLogs` / `voxel::VoxelAoiState`;每迁一组,改其引用方,cargo test 绿,单独 commit。
  全部迁完 **删 `WorldState`**。
- **阶段 3 — `app/mod.rs` 瘦身**:`setup` 巨函数拆成各域 `OnEnter(Game)` 装配系统(scene/光照→presentation 或
  新 `scene/`、相机→camera、HUD/准星→hud);`InputPlugin`/`ObservePlugin` 填实或删除空 stub;`app/` 只剩组合根。
- **阶段 4 — 会话生命周期闭环**:net 线程不再断线即退;`SessionPlugin` 驱动退避重连 + 重认证(重 auto_login);
  令牌过期检测(解 exp / 读 expires_in)。**[服务端 refresh 端点 = auth_server 独立工作,本阶段标接缝]**

**风险**:阶段 2 触及 10 个文件的 `WorldState` 引用,需逐组小步 + 编译/测试守住;阶段 4 改 net 线程生命周期
(当前断线即 `return`),需压重连/重认证的交错。`stdio`/`headless` 读 WorldState 处需同步改到新 Resource。

---

## 5. 实施进度日志

### 2026-06-25 — 阶段 1 完成
- 1a:新建 `src/session/`,`SessionCredentials` 从 `config` 迁入(含 token 脱敏 Debug + 测试),
  `auth_client::auto_login` 折入 `session::auth`。
- 1b:`ConnectionState { status, scene_joined }` 资源从 `WorldState` 收口到 session 域;
  camera/hud/movement/net/presentation/skill/stdio/voxel 各插件改读 `ConnectionState`。
  (注:决策稿原写 `ConnectionPhase` 枚举,1b 先做纯所有权迁移保留 String `status`;枚举化推迟到阶段 4。)

### 2026-06-26 — 阶段 2 完成(WorldState 拆解 + 删除)
逐组迁出、每组 cargo test --lib 360 绿、单独 commit:
- 2a `voxel::VoxelAoiState`(subscribed_center/aoi_anchor) — 仅 net 订阅 follow/retry。
- 2b `skill::TargetSelection`(cid/point) — skill/stdio/net/hud/presentation/voxel。
  附带修 1b 潜在漏刷新:HUD 早返回补 `!connection.is_changed()`。
- 2c `hud::GameLogs`(general/chat/combat/effect/skill) — net 全部日志通道 + skill/stdio/voxel/hud。
- 2d `net::NetTelemetry`(rtt/offset/heartbeat/transport×4/fast_lane/udp) — net 写,hud/stdio 读。
- 2e `world::RemotePlayers`(players/identity/health) — net 写,presentation/skill/stdio/hud 读。
- 2f `world::LocalPlayerState`(cid/position/velocity/hp/max_hp/alive) — 全域;迁完**删除 `WorldState`**。
- README + net 模块文档同步更新为「域资源」表述。

### 2026-06-26 — 阶段 3 完成(app 瘦身)
- 新建 `src/scene/`:`SceneEnvironmentPlugin`(Startup spawn 太阳 + 大气行星 + 主相机实体)
  + `build_scene_render_assets`(在组合根 `run()` 内构建共享 mesh/material 句柄)。
- `app::setup` 巨函数(~160 行)拆解:场景资产→组合根 build 期 insert(消除 Startup 时序隐患,
  marker 读 `Res<SceneRenderAssets>` 无依赖);HUD 文本 + 准星→`HudPlugin` Startup;
  chat 文本→`ChatPlugin` Startup;目标点 marker→`VoxelPlugin` Startup;光照/大气/相机→`scene`。
- 相机实体 spawn 放在 `scene`(与大气渲染组件耦合),相机*行为*(orbit/zoom/cursor)仍属 `CameraPlugin`。
  (决策稿原写「相机→camera」,实现上 spawn 与 behavior 分离,避免大气类型泄漏进 camera 域。)
- 删除空的 `InputPlugin` / `ObservePlugin` 迁移 stub。`app/mod.rs` 现仅余组合根 + 坐标/射线纯助手。
- 验证:cargo test --lib 360 绿、cargo build bin 通过、**实机启动冒烟 7s 无 panic**
  (RTX 5060 渲染器初始化 + 窗口创建 + 体素缓存载入 + 所有迁移 Startup 系统正常运行)。

### 2026-06-26 — 阶段 4 完成(会话生命周期闭环)
- 4a `ConnectionPhase` 枚举化:`ConnectionState { phase, status }`,phase ∈
  {Connecting, InScene, Reconnecting{attempt}, Failed};`scene_joined()` 派生自
  `phase==InScene`(顺带修旧 bug:断线后 scene_joined 仍 true)。
- 4b net 线程自重连:`network_loop` 外层重连驱动环绕 `run_session`;指数退避
  (`session::reconnect` 纯策略,0.5s→5s 上限,30 次)+ 每次 re-auth(新 auto_login
  轮换 token);耗尽预算才 `ReconnectFailed`。退避期 poll Shutdown;会话起始 drain
  陈旧命令;`proactive_refresh_due` 令牌将过期主动重连刷新(接缝:依赖服务端
  `expires_in`,客户端已解析就绪,服务端暂未返回→主动刷新关闭,反应式重连仍轮换 token)。
- 4c `SessionPlugin`:相位变化边沿触发结构化观测事件(自动化 + 未来重连 UI 钩子)。
  net/plugin + observe 映射新事件 → 相位。
- **偏离决策稿**:决策稿写「SessionPlugin 驱动退避重连」,实现上选 net 线程自重连
  (最局部、跨线程 bug 最少、最稳健),退避*策略*在 `session::reconnect` 纯逻辑里
  (session 域拥有「何时/多努力恢复」),SessionPlugin 拥有 Bevy 侧生命周期呈现。
  「服务端 refresh 端点」仍为独立 auth_server 工作的接缝。
- 验证:cargo test --lib 363 绿(+3 纯逻辑单测);实机 headless 冒烟连真服务端
  快乐路径完好(connect→in scene→UDP fast-lane);重连后断路径过多智能体对抗复审。

**阶段 1–4 全部完成。** 后续可选:重连 overlay UI、服务端 `expires_in`/refresh 端点、
ConnectionPhase 在 egui 登录态的细化。
