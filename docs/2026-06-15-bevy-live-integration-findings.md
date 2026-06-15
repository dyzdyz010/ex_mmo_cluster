# bevy 客户端 live 联调发现（2026-06-15）

把 M0–M2 + CLI 指令系统建成后,对**运行中的真实服务器**做了 live 联调,经 CLI 从运行
中的客户端取状态验证。本文记录可复现的启动流程、已验证的 live 路径、以及剩余 gap。

## 1. 可复现的服务器启动流程（已验证）

```powershell
# 单节点起全栈(gate + auth + scene + world + data_service),需 Postgres 已运行。
# 关键:PHX_SERVER=1 才启 Phoenix HTTP(auth 在 :20000);DEV_AUTO_LOGIN=1 才开 dev 登录。
$env:PHX_SERVER = '1'; $env:DEV_AUTO_LOGIN = '1'
cmd /c mix run --no-halt        # 后台;约 50s compile+boot
# 验证:gate 127.0.0.1:20002、auth 127.0.0.1:20000 均 open;日志 "server ready"
```

- gate TCP `:20002`(`@default_port`)、UDP fast-lane `:20003`、auth HTTP `:20000`。
- 单节点模式:`No cluster peers found ... continuing in single-node mode`(正常)。

## 2. 体素场种子（已验证）

```powershell
Invoke-RestMethod -Uri 'http://127.0.0.1:20000/ingame/voxel/dev_seed' -Method Post `
  -Body (@{logical_scene_id=1} | ConvertTo-Json) -ContentType 'application/json'
# → WorldServer.Voxel.DevSeed.ensure_default_region:scene 1、chunk (0,0,0)、
#   16×16 dirt 平台(material 1)256 块 + 10 demo 电路块,chunk_version 3,region_id 1000001
```

路由是 `/ingame/voxel/dev_seed`(不是 `voxel_dev_seed`);同 scope 还有
`voxel/set_temperature`、`voxel/dev_heat_voxel`、`voxel/conduct`、`voxel/auto_circuit`
(可触发涌现特性)。

## 3. 客户端 live 运行 + CLI 测试（已验证）

```bash
BEVY_CLIENT_HEADLESS=1 BEVY_CLIENT_STDIO=1 \
  ./target/debug/bevy_client.exe --headless --stdio --username tester
# stdin 驱动:va-subscribe 1 0 0 0 2 / va-status / va-chunk <cx> <cy> <cz> / quit
```

**已验证 live(对真实服务器)**:
- ✅ **auth + enter-scene**:`auto_login`(DEV_AUTO_LOGIN)成功,`scene_joined=true`、
  服务器权威 spawn(local_cid、position 750,750,185)。
- ✅ **订阅 + 服务器流式快照 + 客户端摄入**:`va-subscribe` 发 0x60(客户端 observe
  `send_voxel opcode=0x60`)→ 服务器回流 chunk 快照 → 客户端 decode→ingest → 
  `va-status chunks` 从 0 增长到 **7**。**整条 live 网络→解码→摄入管线对真实服务器跑通。**
- ✅ **CLI 指令系统**:va-subscribe/va-status/va-chunk 均从运行中客户端正确返回状态。

## 4. 剩余 gap（服务器侧,非客户端）

- ⚠️ **种子 chunk (0,0,0) 的几何未到达玩家**:玩家 AOI 内到达的是 (0,0,0) 周围的
  **空 chunk(version 0,4096 empty)**;种子写入的 (0,0,0)(version 3,256 块平台)服务给
  玩家时是空的。即:`dev_seed` 写了 DB(owner_scene_instance_ref 1 / region 1000001),
  但玩家 live scene 实例服务的是空的 in-memory chunk。
- 这是**服务器侧 scene 实例 / lease / chunk-ownership / 懒加载协调**问题(种子 region owner
  vs 玩家 scene 实例),**不是客户端问题**——客户端对收到的任何非空快照都正确摄入+网格化
  (已由 `tests/voxel_socket.rs` 在真实 golden 字节[含几何]上证实)。
- 待查:web client 的 dev 流程如何让种子数据进玩家 scene 实例(顺序?显式 load?
  lease owner 对齐?);或需玩家 spawn 在种子 chunk 区域 + 种子→chunk_process 载入。
- 次要:客户端 Resync(delta base 不匹配)目前只记日志,未自动重订阅(M3/后续接)。
- 次要:`logical_scene_id` 客户端无协议下发来源(本次手填 1=默认);自动订阅触发待接。

## 5. 结论（M2 阶段）

客户端体素管线**对真实服务器 live 验证通过**(连接→auth→入场→订阅→收快照→解码→摄入),
配合 golden 字节级 parity + socket 帧级测试,客户端侧"渲染权威体素"已就绪。**剩余 last-mile
是服务器侧把已种子的几何送进玩家 AOI**,是一次服务器侧 scene-instance/lease 协调,作后续
协作调试。CLI 指令系统(va-status/va-subscribe/va-chunk)可继续作 live 测试工具。

## 6. GUI 目视确认 + 渲染坐标对齐（2026-06-15 续，已闭环）

### 6.1 §4 的「几何未到玩家」gap 已解决

重新 `POST /ingame/voxel/dev_seed` + 订阅含 spawn 的 chunk 后,几何**确实到达玩家**。原因
不是 scene 实例不一致,而是**服务器按坐标序从 AOI 角落逐 chunk 流式推送(~每 AOI tick 一个)**:
radius 2 = 125 chunk,(0,0,0) 在迭代中段(~18s 才轮到),早期短测试窗口先退出了。改用
**radius 0/1**(spawn chunk 在前)后,chunk (0,0,0) 几秒内到达:`va-chunk 0 0 0` →
`present=true version=20 solid=266 empty=3830 quads=29`。客户端入场已自动订阅 radius 1
(net/plugin.rs `EnteredScene`:`center_chunk = floor(spawn / 1600)`,玩家 spawn (750,750,185)
→ center (0,0,0))。

### 6.2 渲染坐标/缩放/轴向对齐（commit 278d924，GUI 目视确认通过）

`voxel/chunk_render.rs` 三处对齐,让已摄入的几何在 GUI 正确上屏:
- `MACRO_RENDER_SIZE` 1.0 → **100.0**:对齐 server 100cm macro 与离线渲染器
  `VOXEL_RENDER_CELL_SIZE`。
- `build_mesh` 烘焙 **sim→render Y/Z 轴交换**(sim Z = render「上」,见
  `app::sim_to_render_position`)进每个顶点(位置+法线),并**反转三角形 winding**——
  Y/Z 交换是反射(det=-1),不反转则 CCW 正面变 CW 被背面剔除而整面消失。
- `chunk_translation` 经 `sim_to_render_position` 把 chunk 放到其 sim 原点的 render 像。
- **用户 GUI 目视确认**:平台正确、水平铺开、朝向正确、有光照。坐标/缩放/winding 全对。

### 6.3 CLI 测试工具的 stdin 首行 BOM 注意（仅自动化驱动,非客户端 bug）

用 PowerShell `Process.StandardInput` 向 headless+stdio 客户端喂命令时,**管道首行会被加
UTF-8 BOM**(`﻿`),Rust `str::trim()` 不剥 BOM,导致首条命令 `strip_prefix` 失配 →
`unknown command`(后续行正常)。规避:先发一条**弃用首行**(如 `snapshot`)吸收 BOM,再发真
命令。**这只影响自动化 PowerShell 驱动**:(a) GUI 自动订阅走 `NetworkCommand` 不过 stdin;
(b) 人手交互输入无 BOM;(c) parser 单测 `parses_voxel_authority_commands` 通过。
**后续可在 stdio reader 加 `trim_start_matches('\u{feff}')` 防御性硬化**(待下次重建二进制时
一并做——GUI 运行中会锁 `bevy_client.exe,` Windows 下 cargo 无法覆盖)。

### 6.4 当前能力边界 → 下一步

单 chunk(266 块 → 29 面)规模化渲染**视觉验证通过**。要达成 /goal「大规模渲染体素」,
缺的是**服务器侧多 chunk 内容**(dev_seed 只种 1 chunk)+ 客户端**扩订阅半径并验证 N-chunk
规模化渲染性能**(贪婪网格化 + per-chunk 实体 + frustum culling 架构已就位,待压测)。
