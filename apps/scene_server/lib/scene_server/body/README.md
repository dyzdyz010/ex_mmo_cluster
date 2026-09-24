# body/ — 角色身体 L1（首片：体温）

设计来源：Voxim `Docs/Magic.md` §6。本目录只有纯值与纯函数，不持有进程；后续由 `Movement.Player` 以 1 Hz
调用 `Thermo.step/3`，接触热 `q_j` 由 `VoxelRegion.World` 作为热内核外部节点算出并异步回传。

```mermaid
flowchart LR
  W[World 外部节点<br/>q_j, max_contact_k] --> T[Body.Thermo.step/3]
  A[环境空气 air_k] --> T
  T --> B[%Body{}<br/>core_k skin_k 剂量 lethal_s status]
  B --> S[systems/1] --> L[life/1]
  B --> I[injuries/1]
  B --> P[progress/2 濒死计时]
```

- `SceneServer.Body`：状态字段只有 `core_k`、`skin_k`、`burn_dose_s`、`frost_dose_k_s`、`lethal_s`、`status`；
  系统功能水平、生命值、伤病表全部由它们推导，不另存。
- `SceneServer.Body.Thermo.step(body, dt, %{q_j, max_contact_k, air_k, immersed})` → `{body, account}`，
  `account.stored_j = q_j + metabolic_j − convection_j − sweat_j`（J）。

## 模型

Gagge 两节点模型（Gagge, Stolwijk & Nishi 1971；ASHRAE Handbook — Fundamentals 第 9 章 two-node model）的
简化版，显式欧拉：皮肤节点吸收 `q_j`、经服装 + 空气散热、出汗蒸发；核心节点产热（静息 + 寒战），经组织导热
与皮肤血流传到皮肤。血管舒缩、寒战、出汗按体温调节功能水平缩放。未建模：呼吸散热、湿度对蒸发的上限、
辐射加热、浸水（`immersed` 保留字段）。1 clo 服装下全局 20 °C 空气稳态核心约 36.9 °C；0 °C 空气中寒战
可把核心维持在约 36.7 °C，所以失温主要来自与雪 / 冰 / 水接触的 `q_j`。

## 参数（`Body.params/0`，首片常量，待资产化）

| 参数 | 值 | 依据 |
|---|---|---|
| 体表面积 / 体重 / 比热 | 1.8 m² / 70 kg / 3490 J/(kg·K) | ASHRAE 两节点标准人 |
| 皮肤质量分数 | 0.1（皮肤 24430 J/K，核心 219870 J/K） | Gagge 1971 中性值（首片固定，不随血流变） |
| 静息代谢 | 58.2 W/m²（1 met，104.76 W） | ASHRAE |
| 寒战 | 19.4 W/(m²·K²) × 冷皮肤 × 冷核心，封顶 232.8 W/m² | Stolwijk / Gagge 系数；峰值寒战约为静息 5 倍（Eyolfson et al. 2001） |
| 调定点 | 核心 36.8 °C，皮肤 34 °C | Gagge 1971 |
| 核心-皮肤导热 | 5.28 W/(m²·K) + 1.163 W·h/(L·K) × 皮肤血流 | Gagge 1971 |
| 皮肤血流 | (6.3 + 50·暖核心)/(1 + 0.5·冷皮肤) L/(m²·h) | Gagge 1971 / ASHRAE |
| 出汗 | 170 g/(m²·h·K) × 暖核心 × e^(暖皮肤/10.7)，潜热 2430 J/g | Gagge 1971 / ASHRAE（首片用核心信号代替平均体温信号） |
| 干热交换 | 对流 3.1 + 辐射 4.7 W/(m²·K)，服装 0.155 m²·K/W（1 clo） | Gagge 静止空气 h_c；ASHRAE 典型线性辐射系数；ASHRAE 55 常规服装 |
| 体温调节功能带 | 28 °C→0、32 °C→1；40 °C→1、42 °C→0 | 中度失温 28–32 °C 寒战停止（瑞士分级 HT II）；热射病 > 40 °C 出汗衰竭；原创线性插值 |
| 循环功能带 | 24→0、32→1；40→1、43→0 °C | < 24 °C 心脏骤停风险高（HT IV）；> 42–43 °C 常致命 |
| 神经功能带 | 28→0、35→1；39→1、42→0 °C | < 28 °C 意识丧失（HT III）；热射病昏迷 |
| 生命值 | round(100 × min(循环, 神经)) | Magic.md §6.2（首片只接体温这一路） |
| 濒死 | 致命水平 < 0.1 持续 10 s → 濒死，再 120 s → 死亡 | 原创游戏参数；时间压缩系数待定（Magic.md §6.7） |
| 体温过低 1/2/3 | 核心 < 35 / 32 / 28 °C | 临床分级（轻 32–35、中 28–32、重 < 28） |
| 体温过高 1/2/3 | 核心 > 38.5 / 40 / 41 °C | 热衰竭 / 热射病 > 40 °C |
| 烧伤剂量 | 接触 ≥ 44 °C 起，率 2^((T − 60 °C)/1.32 K)，单位 = 60 °C 下的秒 | 拟合 Moritz & Henriques 1947（44 °C 约 6 h 全层坏死）与 CPSC 热水烫伤表（60 °C 约 5 s 三度）两端点：16 K / log2(21600/5) = 1.32 K |
| 烧伤 1/2/3 度 | 剂量 1 / 2.5 / 5 | 三度锚 5 s；一、二度比例为原创取值 |
| 冻伤剂量 | 接触低于 −0.55 °C（组织冰点）累计 K·s，600 K·s 冻伤 | 冰点为常见临床取值；600 K·s 为原创取值，待校准 |

烧伤 / 冻伤首片按设计“伤口撤不回”：剂量只增不减，严重度不自愈，自然愈合留给后续切片（Magic.md §6.5）。
体温过低 / 过高随核心温度变化，回到正常带即消失。

## 测试

`apps/scene_server/test/scene_server/body/thermo_test.exs`：手算单步、能量账每步闭合、20 °C 稳态、0 °C 寒战、
60 °C / 600 K 烧伤、−10 °C 冻伤、体温伤病与生命推导、濒死 → 死亡、窗口内救回、复温恢复而烧伤保留。
