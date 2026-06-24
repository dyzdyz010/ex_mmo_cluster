# Phase 5.C 第一批 attribute catalog seed file.
#
# 设计草案：docs/plans/2026-05-13-phase5c-first-batch-catalog-seed.md
# 用户 2026-05-13 approve C-1..C-8 全部推荐方案：
#   C-1 顺序数字 id (1..12)
#   C-2 fixed32 Q16.16 按表范围
#   C-3 default 绝对值（物理量直观）
#   C-4 .exs Elixir 字面量 seed
#
# Wire 字段语义见 `SceneServer.Voxel.AttributeDefinition`：
#   value_type  :fixed32      → 0x03  (Q16.16, 4 bytes wire)
#   merge_rule  :add_delta    → 0x02
#   merge_rule  :material_default → 0x05
#   dynamic     true/false    → 0/1
#
# 值的 raw 数值为 Q16.16 定点（int32），即 raw = round(real * 65536)。
# 物理范围参考 `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标三缺口 A"。
#
# 一旦发出即冻结：id ↔ name 的映射 wire 上下游已落地后不可重排。

%{
  catalog_version: 14,
  definitions: [
    %{
      id: 1,
      name: "temperature",
      unit: "°C",
      value_type: :fixed32,
      # 20.0 °C
      default_value: 1_310_720,
      # -273.15 °C (绝对零度近似)
      min_value: -17_904_824,
      # 5000.0 °C (远超常规上限，留 4× 安全余量)
      max_value: 327_680_000,
      merge_rule: :add_delta,
      dynamic: true
    },
    %{
      id: 2,
      name: "humidity",
      unit: "%",
      value_type: :fixed32,
      # 50.0%
      default_value: 3_276_800,
      # 0.0%
      min_value: 0,
      # 100.0%
      max_value: 6_553_600,
      merge_rule: :add_delta,
      dynamic: true
    },
    %{
      id: 3,
      name: "moisture",
      unit: "kg/m³",
      value_type: :fixed32,
      # 0.0 kg/m³
      default_value: 0,
      # 0.0 kg/m³
      min_value: 0,
      # 1000.0 kg/m³ (饱和水)
      max_value: 65_536_000,
      merge_rule: :add_delta,
      dynamic: true
    },
    %{
      id: 4,
      name: "density",
      unit: "kg/m³",
      value_type: :fixed32,
      # 1.0 kg/m³
      default_value: 65_536,
      # 0.001 kg/m³ (近真空)
      min_value: 66,
      # 20000.0 kg/m³ (远超普通金属)
      max_value: 1_310_720_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 5,
      name: "thermal_conductivity",
      unit: "W/(m·K)",
      value_type: :fixed32,
      # 0.1 W/(m·K) (空气量级)
      default_value: 6_554,
      # 0.0 W/(m·K)
      min_value: 0,
      # 500.0 W/(m·K) (银的量级 + 余量)
      max_value: 32_768_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 6,
      name: "specific_heat_capacity",
      unit: "J/(kg·K)",
      value_type: :fixed32,
      # 1000.0 J/(kg·K) (水 / 普通材料数量级的保守默认)
      default_value: 65_536_000,
      # 1.0 J/(kg·K)
      min_value: 65_536,
      # 10000.0 J/(kg·K)
      max_value: 655_360_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 7,
      name: "ignition_temperature",
      unit: "°C",
      value_type: :fixed32,
      # 5000.0 °C (inert / non-flammable fallback)
      default_value: 327_680_000,
      # -273.15 °C (aligned with temperature attribute lower bound)
      min_value: -17_904_824,
      # 5000.0 °C
      max_value: 327_680_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 8,
      name: "melting_point",
      unit: "°C",
      value_type: :fixed32,
      # 5000.0 °C (inert / no-melt fallback)
      default_value: 327_680_000,
      min_value: -17_904_824,
      max_value: 327_680_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 9,
      name: "freezing_point",
      unit: "°C",
      value_type: :fixed32,
      # absolute-zero sentinel means "no solidification transition for this fallback"
      default_value: -17_904_824,
      min_value: -17_904_824,
      max_value: 327_680_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 10,
      name: "boiling_point",
      unit: "°C",
      value_type: :fixed32,
      # 5000.0 °C (inert / no-boil fallback)
      default_value: 327_680_000,
      min_value: -17_904_824,
      max_value: 327_680_000,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 11,
      name: "electric_conductivity",
      unit: "MS/m",
      value_type: :fixed32,
      # 0.0 MS/m
      default_value: 0,
      min_value: 0,
      # 100.0 MS/m
      max_value: 6_553_600,
      merge_rule: :material_default,
      dynamic: false
    },
    %{
      id: 12,
      name: "dielectric_strength",
      unit: "MV/m",
      value_type: :fixed32,
      # 3.0 MV/m (air-scale fallback)
      default_value: 196_608,
      min_value: 0,
      # 100.0 MV/m
      max_value: 6_553_600,
      merge_rule: :material_default,
      dynamic: false
    },
    # 功能完善 · 反应层 R5(燃烧):燃烧进度比率 0.0→1.0(满即燃尽成 ash)。
    # `:add_delta` 让 burning 每 tick 累进;clip 到 [0, 1.0]。
    %{
      id: 13,
      name: "burn_progress",
      unit: "ratio",
      value_type: :fixed32,
      # 0.0 未燃
      default_value: 0,
      min_value: 0,
      # 1.0 燃尽
      max_value: 65_536,
      merge_rule: :add_delta,
      dynamic: true
    },
    # 功能完善 · 正交架构 S1(电磁):材料内禀电阻 Ω。载流(闭环电流)的耗散元件按 I²R 产热
    # (CircuitCurrentKernel),替代凭空断言的 powered_heater。理想导体/非耗散 = 0(fallback)。
    %{
      id: 14,
      name: "electric_resistance",
      unit: "Ω",
      value_type: :fixed32,
      # 0.0 Ω (理想导体 / 无耗散 fallback)
      default_value: 0,
      min_value: 0,
      # 10000.0 Ω
      max_value: 655_360_000,
      merge_rule: :material_default,
      dynamic: false
    },
    # 功能完善 · 正交架构 S2(电磁):材料电动势 V。emf>0 → :source 电角色(属性派生,替代
    # power_block material_id 白名单)。0 = 非电源(fallback)。
    %{
      id: 15,
      name: "emf",
      unit: "V",
      value_type: :fixed32,
      # 0.0 V (非电源 fallback)
      default_value: 0,
      min_value: 0,
      # 1000.0 V
      max_value: 65_536_000,
      merge_rule: :material_default,
      dynamic: false
    },
    # 功能完善 · 正交架构 S4(化学/氧化):起反应温度门 °C。材料温度 ≥ 自身 oxidation_temperature 才
    # 起氧化(同 ignition_temperature 范式);惰性/不可氧化 = 哨兵 5000℃ 不可达(fallback)。
    %{
      id: 16,
      name: "oxidation_temperature",
      unit: "°C",
      value_type: :fixed32,
      # 5000.0 °C (inert / non-oxidizable fallback)
      default_value: 327_680_000,
      # -273.15 °C (aligned with temperature attribute lower bound)
      min_value: -17_904_824,
      # 5000.0 °C
      max_value: 327_680_000,
      merge_rule: :material_default,
      dynamic: false
    },
    # 功能完善 · 正交架构 S4(化学/氧化):氧化进度比率 0.0→1.0(满即转氧化产物如 rust)。
    # `:add_delta` 让 rusting 每 tick 累进;clip 到 [0, 1.0](镜像 burn_progress id13)。
    %{
      id: 17,
      name: "oxidation_progress",
      unit: "ratio",
      value_type: :fixed32,
      # 0.0 未氧化
      default_value: 0,
      min_value: 0,
      # 1.0 氧化完成
      max_value: 65_536,
      merge_rule: :add_delta,
      dynamic: true
    },
    # 功能完善 · 形态轨 M5(表面元件物理参与):稳定热源功率 W。带 heat_output>0 的材料(如火炬 ember)
    # 持续向宿主格注热(经守恒热扩散耦合到相变/化学);0 = 不发热(fallback,惰性安全)。定性档:实际注热
    # 量 = heat_output·dt·gain(单 voxel 源经扩散稀释需增益,同 S1 I方R)。fixed32 上限约 32767 W。
    %{
      id: 18,
      name: "heat_output",
      unit: "W",
      value_type: :fixed32,
      # 0.0 W (非热源 fallback)
      default_value: 0,
      min_value: 0,
      # 30000.0 W (fixed32 i32 安全上限内)
      max_value: 1_966_080_000,
      merge_rule: :material_default,
      dynamic: false
    },
    # 光学正交系统(2026-06-23):发光源强度。light_emission>0 的材料(灯/余烬/glowstone)自发光,
    # 经 LightPropagationKernel flood 成权威光场;0 = 不发光(fallback,惰性安全,同 heat_output 范式)。
    %{
      id: 19,
      name: "light_emission",
      unit: "W",
      value_type: :fixed32,
      # 0.0 (非光源 fallback)
      default_value: 0,
      min_value: 0,
      # 30000.0 (同 heat_output 安全上限)
      max_value: 1_966_080_000,
      merge_rule: :material_default,
      dynamic: false
    },
    # 光学正交系统:不透明度 0.0(全透)→1.0(全挡)。LightPropagationKernel 按此衰减/阻断光传播。
    # default 1.0:实心材料默认挡光(物理安全);透光材料(ice/obsidian/glass)显式配低值。
    # 空 cell(无材料)由 kernel 特判为透明(opacity 0),不经此目录默认。
    %{
      id: 20,
      name: "opacity",
      unit: "ratio",
      value_type: :fixed32,
      # 1.0 不透明(实心默认挡光)
      default_value: 65_536,
      min_value: 0,
      # 1.0
      max_value: 65_536,
      merge_rule: :material_default,
      dynamic: false
    },
    # 光学正交系统 · 光合(2026-06-23):生长进度比率 0.0→1.0(满即成熟,如 sprout→wood)。
    # `:add_delta` 让光合每 tick 累进(光照+相邻水时);clip 到 [0, 1.0](镜像 burn/oxidation_progress)。
    %{
      id: 21,
      name: "growth_progress",
      unit: "ratio",
      value_type: :fixed32,
      # 0.0 未生长
      default_value: 0,
      min_value: 0,
      # 1.0 成熟
      max_value: 65_536,
      merge_rule: :add_delta,
      dynamic: true
    },
    # 光学 · 彩色光(2026-06-23):发光源颜色,**packed RGB888 原始整数**(0xRRGGBB,非定点缩放)。
    # default 0xFFFFFF 白光;LightPropagationKernel 读它给光场染色(最亮源的颜色随光传播)。值 ≤ 2^24
    # 在 f32 场层精确可存。仅光源(light_emission>0)有意义;静态 material_default。
    %{
      id: 22,
      name: "light_color",
      unit: "rgb888",
      value_type: :fixed32,
      # 0xFFFFFF 白光(非光源材料回退,惰性安全)
      default_value: 16_777_215,
      min_value: 0,
      max_value: 16_777_215,
      merge_rule: :material_default,
      dynamic: false
    },
    # 力学应力(2026-06-23):此材料是否为**承重/传力的实心结构**。1=结构(参与支撑图:
    # 既能被地锚支撑、也能向上传递支撑);0=流体/气/松散(不承重,如 water/steam/lava/
    # molten_iron/ember)。StructuralSupport 据此 BFS;失支撑的结构 cell → 坍塌。静态
    # material_default。默认 1(绝大多数实心方块是结构)。
    %{
      id: 23,
      name: "structural",
      unit: "bool",
      value_type: :fixed32,
      # 1.0 = 承重结构(默认)
      default_value: 65_536,
      min_value: 0,
      # 1.0
      max_value: 65_536,
      merge_rule: :material_default,
      dynamic: false
    },
    # 建设系统 · 半导体梯队(2026-06-23):逻辑阈值电压(V)。>0 标记该材料为**比较器/阈值门**:
    # CircuitCurrentKernel 比较该 cell 的电位与本阈值,≥ 则置 :signal_high tag(模拟量→数字逻辑)。
    # 0 = 非逻辑元件(默认)。static material_default。
    %{
      id: 24,
      name: "logic_threshold",
      unit: "V",
      value_type: :fixed32,
      default_value: 0,
      min_value: 0,
      # 1000 V 上限(足够覆盖电源 120V 系)。
      max_value: 65_536_000,
      merge_rule: :material_default,
      dynamic: false
    },
    # 建设系统 · C4b 深半导体(2026-06-24):二极管"导通轴"标记。**材料级 >0 ⇒ 该材料是二极管**
    # (diode_material? 派生谓词,无 id 白名单,仿 emf/electric_resistance/logic_threshold 范式)。
    # 具体每格 anode→cathode 朝向由放置时写入的 state_flags 位段承载(投影层解码,C4b step2-4)。
    # raw 离散枚举码(非物理量纲,同 light_color packed 先例):0=无向(回退普通双向导体,惰性安全)/
    # 1=+x /2=-x /3=+y /4=-y /5=+z /6=-z。
    %{
      id: 25,
      name: "conduction_axis",
      unit: "axis",
      value_type: :fixed32,
      # 0 = 无向(普通双向导体回退)
      default_value: 0,
      min_value: 0,
      # 6 = -z(0..6 轴码)
      max_value: 6,
      merge_rule: :material_default,
      dynamic: false
    },
    # 建设系统 · C4b 三极管/逻辑门(2026-06-24):base(控制极)导通门限电压 V。**材料级 >0 ⇒ 该材料
    # 是三极管**(transistor_material? 派生谓词,无 id 白名单)。三极管的 collector-emitter 主通路
    # 仅当 base 端被 ≥ 本门限的电源驱动时导通(否则该 cell 被剪断);主轴/base 面由 state_flags 承载。
    # 与 comparator 的 logic_threshold 分开(comparator 是传感输出 tag、不门控电流;transistor 门控电流)。
    %{
      id: 26,
      name: "base_threshold",
      unit: "V",
      value_type: :fixed32,
      default_value: 0,
      min_value: 0,
      # 1000 V 上限(同 logic_threshold 量程)。
      max_value: 65_536_000,
      merge_rule: :material_default,
      dynamic: false
    }
  ]
}
