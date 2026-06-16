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
  catalog_version: 4,
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
    }
  ]
}
