defmodule SceneServer.Voxel.MaterialCatalog do
  @moduledoc """
  Material-specific defaults for `material_default` voxel attributes.

  `Storage` owns per-chunk truth, while this module is the small static material
  lookup table used to derive L1 defaults from a normal/refined cell's
  `material_id`. Runtime voxel state should store only dynamic changes; stable
  material thresholds and physical constants belong here and in the attribute
  catalog definition.
  """

  @fixed32_scale 65_536
  @absolute_zero_raw -17_904_824
  @inert_temperature_raw 327_680_000

  @dirt_material_id 1
  @stone_material_id 2
  @wood_material_id 3
  @ice_material_id 4
  @iron_material_id 5
  @power_block_material_id 6
  @electric_load_material_id 7
  # 功能完善 · 反应层:相变/燃烧目标材料。append-only id。R1 water;R4 steam;R5 ash(燃尽)。
  @water_material_id 8
  @steam_material_id 9
  @ash_material_id 10
  # 功能完善 · 反应层 R9b:门/机关(电路驱动设备)。导电 + 电负载 → 闭环通电置 :powered → 开。
  @door_material_id 11
  # 功能完善 · 正交架构 S4(化学/氧化):铁锈——iron 氧化终产物。不导电(锈断路)、惰性(不再氧化)。
  @rust_material_id 12
  # 功能完善 · 形态轨 M5(表面元件物理参与):余烬/火焰——稳定热源(heat_output>0)。火炬表面元件借其
  # 属性向量持续向宿主格注热(经守恒热扩散耦合到相变/化学);非导电、惰性(不可燃/不氧化)。
  @ember_material_id 13

  # 材料名 ↔ id(反应规则用名引用,稳定不写裸 id)。
  @material_ids %{
    dirt: @dirt_material_id,
    stone: @stone_material_id,
    wood: @wood_material_id,
    ice: @ice_material_id,
    iron: @iron_material_id,
    power_block: @power_block_material_id,
    electric_load: @electric_load_material_id,
    water: @water_material_id,
    steam: @steam_material_id,
    ash: @ash_material_id,
    door: @door_material_id,
    rust: @rust_material_id,
    ember: @ember_material_id
  }

  @power_source_defaults %{
    output_mode: :dc,
    voltage: 120.0,
    current_limit_amps: 20.0,
    energy_budget_joules: 20_000.0
  }

  @material_default_attributes %{
    @dirt_material_id => %{
      "density" => round(1_600.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.25 * @fixed32_scale),
      "specific_heat_capacity" => round(800.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_100.0 * @fixed32_scale),
      "freezing_point" => round(1_100.0 * @fixed32_scale),
      "boiling_point" => round(2_200.0 * @fixed32_scale),
      "electric_conductivity" => round(0.01 * @fixed32_scale),
      "dielectric_strength" => round(10.0 * @fixed32_scale)
    },
    @stone_material_id => %{
      "density" => round(2_700.0 * @fixed32_scale),
      "thermal_conductivity" => round(2.5 * @fixed32_scale),
      "specific_heat_capacity" => round(790.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_200.0 * @fixed32_scale),
      "freezing_point" => round(1_200.0 * @fixed32_scale),
      "boiling_point" => round(3_000.0 * @fixed32_scale),
      "electric_conductivity" => 0,
      "dielectric_strength" => round(12.0 * @fixed32_scale)
    },
    @wood_material_id => %{
      "density" => round(600.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.13 * @fixed32_scale),
      "specific_heat_capacity" => round(1_700.0 * @fixed32_scale),
      "ignition_temperature" => round(300.0 * @fixed32_scale),
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => round(10.0 * @fixed32_scale)
    },
    @ice_material_id => %{
      "density" => round(917.0 * @fixed32_scale),
      "thermal_conductivity" => round(2.2 * @fixed32_scale),
      "specific_heat_capacity" => round(2_100.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => 0,
      "freezing_point" => 0,
      "boiling_point" => round(100.0 * @fixed32_scale),
      "electric_conductivity" => 0,
      "dielectric_strength" => round(9.8 * @fixed32_scale)
    },
    @iron_material_id => %{
      "density" => round(7_870.0 * @fixed32_scale),
      "thermal_conductivity" => round(80.0 * @fixed32_scale),
      "specific_heat_capacity" => round(449.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_538.0 * @fixed32_scale),
      "freezing_point" => round(1_538.0 * @fixed32_scale),
      "boiling_point" => round(2_862.0 * @fixed32_scale),
      "electric_conductivity" => round(10.0 * @fixed32_scale),
      "dielectric_strength" => 0,
      # S4 化学/氧化:起锈温度门 0℃——常温即缓慢氧化成 rust(冻铁 <0℃ 不锈)。属性派生激活,无白名单。
      "oxidation_temperature" => 0
    },
    @power_block_material_id => %{
      "density" => round(7_870.0 * @fixed32_scale),
      "thermal_conductivity" => round(80.0 * @fixed32_scale),
      "specific_heat_capacity" => round(449.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_538.0 * @fixed32_scale),
      "freezing_point" => round(1_538.0 * @fixed32_scale),
      "boiling_point" => round(2_862.0 * @fixed32_scale),
      "electric_conductivity" => round(12.0 * @fixed32_scale),
      "dielectric_strength" => 0,
      # S2:电动势 → :source 电角色由属性派生(emf>0),不再靠 material_id 白名单。
      "emf" => round(120.0 * @fixed32_scale)
    },
    @electric_load_material_id => %{
      "density" => round(7_870.0 * @fixed32_scale),
      "thermal_conductivity" => round(65.0 * @fixed32_scale),
      "specific_heat_capacity" => round(520.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_450.0 * @fixed32_scale),
      "freezing_point" => round(1_450.0 * @fixed32_scale),
      "boiling_point" => round(2_700.0 * @fixed32_scale),
      # σ/R 一致性(2026-06-16):发热元件=劣导体——低 σ(2.0,nichrome 类)与高集总 R(50Ω)方向
      # 自洽(不再"高导电却高电阻");仍 ≥ 导体阈 1.0 照常参与电路。详 sigma-R-coherence 决策稿。
      "electric_conductivity" => round(2.0 * @fixed32_scale),
      "dielectric_strength" => 0,
      # S1:发热元件——载流时按 I²R 耗散为热(door 高 σ→小 R→基本不发热,同为 load 但行为由属性分流)。
      "electric_resistance" => round(50.0 * @fixed32_scale)
    },
    # 反应层 R1:水(冰熔化目标)。freezing_point=0 冻回冰;boiling_point=100 → 蒸汽。
    @water_material_id => %{
      "density" => round(1_000.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.6 * @fixed32_scale),
      "specific_heat_capacity" => round(4_186.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => 0,
      "boiling_point" => round(100.0 * @fixed32_scale),
      "electric_conductivity" => round(0.005 * @fixed32_scale),
      "dielectric_strength" => 0
    },
    # 反应层 R4:蒸汽(水沸腾目标)。低密度、低导热;condense 阈值后续接。
    @steam_material_id => %{
      "density" => round(0.6 * @fixed32_scale),
      "thermal_conductivity" => round(0.025 * @fixed32_scale),
      "specific_heat_capacity" => round(2_010.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => 0
    },
    # 反应层 R5:灰烬(木燃尽目标)。轻、ignition inert(不复燃),惰性产物。
    @ash_material_id => %{
      "density" => round(80.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.05 * @fixed32_scale),
      "specific_heat_capacity" => round(840.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => round(3.0 * @fixed32_scale)
    },
    # 反应层 R9b:门——导电金属(参与电路 + 电负载,通电置 :powered → 开),常温惰性。
    # S2:小电阻(螺线管/作动器线圈)→ :load 电角色由属性派生(electric_resistance>0);载流微热
    # (R 远小于加热元件 electric_load 50Ω,I²R 可忽略)。
    @door_material_id => %{
      "density" => round(2_500.0 * @fixed32_scale),
      "thermal_conductivity" => round(50.0 * @fixed32_scale),
      "specific_heat_capacity" => round(500.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_500.0 * @fixed32_scale),
      "freezing_point" => round(1_500.0 * @fixed32_scale),
      "boiling_point" => round(2_800.0 * @fixed32_scale),
      "electric_conductivity" => round(8.0 * @fixed32_scale),
      "dielectric_strength" => 0,
      "electric_resistance" => round(0.5 * @fixed32_scale)
    },
    # S4 化学/氧化:铁锈(Fe2O3 量级)——iron 氧化终产物。electric_conductivity=0(锈断路,化学×电磁
    # 涌现);oxidation_temperature=哨兵(惰性,不再氧化,同 ash ignition inert 范式);低导热、不可燃。
    @rust_material_id => %{
      "density" => round(5_240.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.6 * @fixed32_scale),
      "specific_heat_capacity" => round(650.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => round(1_565.0 * @fixed32_scale),
      "freezing_point" => round(1_565.0 * @fixed32_scale),
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => round(2.0 * @fixed32_scale),
      "oxidation_temperature" => @inert_temperature_raw
    },
    # M5 表面元件物理参与:余烬/火焰——稳定热源。heat_output>0 → 火炬表面元件持续注热;低密度、惰性
    # (ignition/oxidation 哨兵不可达 → 不可燃不氧化)、不导电。
    @ember_material_id => %{
      "density" => round(300.0 * @fixed32_scale),
      "thermal_conductivity" => round(0.1 * @fixed32_scale),
      "specific_heat_capacity" => round(800.0 * @fixed32_scale),
      "ignition_temperature" => @inert_temperature_raw,
      "melting_point" => @inert_temperature_raw,
      "freezing_point" => @absolute_zero_raw,
      "boiling_point" => @inert_temperature_raw,
      "electric_conductivity" => 0,
      "dielectric_strength" => 0,
      "oxidation_temperature" => @inert_temperature_raw,
      # 稳定热源功率(定性档,经守恒热扩散增益放大;火炬借此向宿主格注热)。
      "heat_output" => round(1_500.0 * @fixed32_scale)
    }
  }

  @doc "材料名 → append-only id(未知名返回 nil)。反应规则用名引用。"
  @spec material_id(atom()) :: pos_integer() | nil
  def material_id(name) when is_atom(name), do: Map.get(@material_ids, name)

  @doc """
  material_id 是否在 catalog 中已定义(反应层用:未知材料不参与阈值反应,避免缺省阈值 0 反转惰性安全)。
  """
  @spec known_material?(term()) :: boolean()
  def known_material?(material_id), do: Map.has_key?(@material_default_attributes, material_id)

  @doc "id → 材料名(未知 id 返回 nil)。"
  @spec material_name(integer()) :: atom() | nil
  def material_name(id) when is_integer(id) do
    Enum.find_value(@material_ids, fn {name, mid} -> if mid == id, do: name end)
  end

  @doc "全部已知材料名 → id 映射。"
  @spec material_ids() :: %{atom() => pos_integer()}
  def material_ids, do: @material_ids

  @doc "Q16.16 定点比例(1.0 == 65536 raw)。反应层把 raw 阈值转摄氏度用。"
  @spec fixed32_scale() :: pos_integer()
  def fixed32_scale, do: @fixed32_scale

  @doc "Returns the append-only material id for the physical electric power block."
  @spec power_source_material_id() :: pos_integer()
  def power_source_material_id, do: @power_block_material_id

  @doc """
  Returns true when a material is a circuit power source. S2 正交架构:由属性派生
  (`emf` > 0),不再绑 material_id 白名单——任何配 emf 的材料自动成为 :source。
  """
  @spec power_source_material?(term()) :: boolean()
  def power_source_material?(material_id), do: default_attribute_value(material_id, "emf", 0) > 0

  @doc "Returns the append-only material id for a physical electric load/sink block."
  @spec electric_load_material_id() :: pos_integer()
  def electric_load_material_id, do: @electric_load_material_id

  @doc """
  Returns true when a material is a circuit load/sink. S2 正交架构:由属性派生
  (`electric_resistance` > 0 = 耗散/作动元件),不再绑 material_id 白名单——任何配电阻的
  导电材料自动成为 :load(闭环置 :powered)。发热(I²R)与否、机械响应等具体行为再由材料属性 +
  反应规则正交分流(electric_load 高电阻发热;door 小电阻作动)。
  """
  @spec electric_load_material?(term()) :: boolean()
  def electric_load_material?(material_id),
    do: default_attribute_value(material_id, "electric_resistance", 0) > 0

  @doc "Returns the current default supply policy for a physical power block."
  @spec power_source_defaults() :: %{
          output_mode: :dc,
          voltage: float(),
          current_limit_amps: float(),
          energy_budget_joules: float()
        }
  def power_source_defaults, do: @power_source_defaults

  @doc """
  Returns all material-default attributes for a material id.
  """
  @spec material_defaults(non_neg_integer() | nil) :: %{optional(String.t()) => integer()}
  def material_defaults(material_id) do
    Map.get(@material_default_attributes, material_id, %{})
  end

  @doc """
  Returns a material-specific attribute value, or `fallback` for unknown
  material ids / attributes.
  """
  @spec default_attribute_value(non_neg_integer() | nil, String.t(), integer()) :: integer()
  def default_attribute_value(material_id, attr_name, fallback)
      when is_binary(attr_name) and is_integer(fallback) do
    material_id
    |> material_defaults()
    |> Map.get(attr_name, fallback)
  end
end
