defmodule VoxelRegion.Magic.Catalog do
  @moduledoc """
  全局系统功能（魔法）：魔法目录 v5——施法者常数、上限、构造与运行期参数、配额与符号清单的唯一服务端读取入口。

  schema 见 `docs/10-active/magic/2026-11-19-catalog-v5-schema.md`（符号组合魔法 v2，切片 0a）。
  唯一作者源是本仓 `apps/voxel_region/priv/magic/<sha256>.json`（不可变、按内容寻址，切片 3 决策 P9）：
  Voxim 按 sha256 校验后拷入 `Content/Voxel/Magic/Published/`，部署照旧拷成 `catalogs/magic-catalog.json`，
  World 启动时读取（`:magic_catalog_path`），digest = 文件字节 sha256，与属性目录同法（`VoxelRegion.Damage.load/1`）。
  部署文件是信任边界：结构在这里校验一次，之后 `Program`、`Signature`、`Cost` 与 World 直接消费。

  解码为 `%VoxelRegion.Magic.Catalog{}`：符号表按 u16 下标索引（`Catalog.Symbol` / `Catalog.Slot`）、预留下标表
  （`reserved`，设计 v2.4 K3：未开放阶段的下标只占位，解码层按未知下标拒绝）、计数上限、`backup_modes`、配额、
  运行期常数与预设字节；任何不符都抛出带字段路径的 `ArgumentError`。
  预设逐个经 `Program.diagnose_ir/2` 解码，保证发布的预设都是合法程序。

  版本 4（v1 JSON 程序的旧目录）已随切片 3 删除（决策稿 `2026-11-19-slice3-protocol.md` §6）：部署 v4 文件时
  World 启动即显式失败，升级须同时替换 `magic-catalog.json`（决策稿 §5.2）。
  """

  alias VoxelRegion.Magic.Program

  defmodule Slot do
    @moduledoc """
    目录 v5 的一个参数槽（设计 §11.4.2）。字节宽度由量化类决定，取值约束全部来自目录。

    - `key`：解码后程序参数表里的键。能量槽换算为整数 mJ，键名随之由 `_j` 改为 `_mj`；其余与 `name` 相同。
    - `scale`：槽单位 → 内部单位的整数倍数（能量 1000，其余 1）。
    - `min` / `max`：以槽单位计的闭区间；为 `nil` 时由符号的 `ranges_by_param` 给出。
    - `enum`：`enum8` 的 `%{编号 => 名称}`；`bits`：`mask8` 的 `%{位 => 名称}`；都只含已发布项。
    """
    @enforce_keys [:name, :key, :class]
    defstruct [
      :name,
      :key,
      :class,
      :unit,
      :min,
      :max,
      scale: 1,
      enum: %{},
      bits: %{},
      zero_means_absent: false,
      refs_enabled: false
    ]
  end

  defmodule Symbol do
    @moduledoc """
    目录 v5 的一个已发布符号：下标、id、所属段、参数槽（顺序即字节顺序）与类型签名数据（设计 §3.2、§11.4.5）。

    签名字段只由 `Magic.Signature` 解释；`numeric_checks`、计价（`units`、`precision` 及其 `*_by_param`）与
    `pose`（弧度）由 Cost 消费。`*_by_param` 的形状为 `%{槽名 => %{取值键 => 值}}`，取值键规则见 schema 文档 §5。
    `refs` 为 `[%{param: 槽名, kind: :group | :rule}]`（位置约束目前只有“严格在前”）。
    `property_class`：质段耦合写入的性质类别（设计 v2.9 §4.5 Q21(a)），`nil` 表示不写入性质类；同组写入两类以上
    时由 Cost 按“从零定义”计价。
    `reading_source`：读数段符号读的是外部信号（`:external`，外人可伪造）还是结构自身（`:self`）（设计 v2.10 E2，
    §4.2、§11.4.5）；只有读数段符号有，其余为 `nil`。Cost 据此数 `entries_spoof`。
    """
    @enforce_keys [:index, :id, :section, :phase, :params]
    defstruct [
      :index,
      :id,
      :section,
      :phase,
      :params,
      :max_per_group,
      :max_per_rule,
      :units,
      :precision,
      :pose,
      :property_class,
      :reading_source,
      in_program: true,
      ranges_by_param: %{},
      provides: [],
      provides_by_param: %{},
      requires_all: [],
      requires_any: [],
      requires_by_param: %{},
      excludes: [],
      unique_by: [],
      refs: [],
      numeric_checks: [],
      units_by_param: %{},
      precision_by_param: %{}
    ]
  end

  @typedoc "目录 v5 的已校验值；字段含义见 schema 文档。"
  @type t :: %__MODULE__{}
  defstruct [
    :digest,
    :caster,
    :construction,
    :limits,
    :quotas,
    :runtime,
    :semblance,
    :group_requires_all,
    :symbols,
    :reserved,
    :presets
  ]

  # 段名：目录字符串 → 程序布局中的段（设计 §11.4.1）。
  @sections %{
    "caster_action" => :caster_action,
    "anchor.form" => :form_anchor,
    "anchor.ref" => :ref_anchor,
    "shape" => :shape,
    "quality" => :quality,
    "energy" => :energy,
    "motion" => :motion,
    "rule.reading" => :reading,
    "rule.response" => :response
  }
  # 这些段内同一下标能否重复由 `max_per_group` 决定，所以必须写明（§11.4.3 第 2 条）。
  @segment_sections [:ref_anchor, :shape, :quality, :energy, :motion]
  # `id16`、`sid96` 随 P2 符号（〈仿〉、〈调〉）开放，现在出现即拒绝加载。
  @classes %{
    "dec" => :dec,
    "lin16" => :lin16,
    "u8" => :u8,
    "enum8" => :enum8,
    "mask8" => :mask8,
    "ref8" => :ref8
  }
  # 单位 → {量化类, 槽名后缀, 内部单位倍数, 解码后键后缀}（设计 §11.4.2 单位表与 N7；能量内部单位为整数 mJ）。
  @units %{
    "J" => {:dec, "_j", 1000, "_mj"},
    "W" => {:dec, "_w", 1, "_w"},
    "g" => {:dec, "_g", 1, "_g"},
    "mm" => {:lin16, "_mm", 1, "_mm"},
    "dK" => {:lin16, "_dk", 1, "_dk"},
    "mm/s" => {:lin16, "_mmps", 1, "_mmps"},
    "cs" => {:lin16, "_cs", 1, "_cs"},
    "cdeg" => {:lin16, "_cdeg", 1, "_cdeg"},
    "bp" => {:lin16, "_bp", 1, "_bp"}
  }
  @class_max %{dec: 4095 * 10 ** 15, lin16: 0xFFFF, u8: 0xFF}
  # 性质类别（设计 v2.9 §4.5）：P1 发布 thermal（〈热〉）与 emission（〈辉〉），P2 起 appearance、mechanical。
  @property_classes ~w(thermal emission appearance mechanical)
  # 读数来源（设计 v2.10 E2）：读数段符号必填。
  @reading_sources %{"external" => :external, "self" => :self}
  @top_fields ~w(version caster construction limits quotas runtime semblance group_signature symbols reserved_symbols
    presets)
  @symbol_fields ~w(index id section phase in_program property_class reading_source params ranges_by_param provides
    provides_by_param
    requires_all requires_any requires_by_param excludes max_per_group max_per_rule unique_by refs numeric_checks units
    units_by_param precision precision_by_param pose)
  @slot_fields ~w(name class unit min max enum bits zero_means_absent refs_enabled)
  @quotas ~w(structures_per_caster folded_per_caster flights_per_caster region_budget_units region_reserve_units
    fair_share_ratio structure_weight_base structure_weight_awake_thermal_node structure_weight_per_rule
    structure_weight_per_sensing_coupling structures_per_npc npc_budget_ratio region_flight_slots_base
    awake_thermal_nodes_per_region triggers_per_region_tick triggers_per_caster_tick quotes_per_caster_per_s
    present_floor_structures region_flight_slots_per_present)a
  # `windup_interrupt_dose` 起的 14 项是设计 v2.3 §11.4.5.1 建议补入的常数（名称与值照抄该表）；
  # 末尾 2 项是设计 v2.9 §4.5（Q21(a)）从零定义计价的单元与精度步长。
  @runtime ~w(run_loss_ratio reference_volume_m3 disruption_rate_per_s disruption_load_gain repair_rate_per_s
    repair_unit_cost_j coherence_loss_per_debt segment_debt_limit coherence_min min_energy_per_complexity_j
    storage_density_j_per_m3 throughput_density_w_per_m2 env_temperature_gain env_neighbor_gain env_embedded_gain
    disruption_dose_gain release_dose_ratio leak_deposit_max_j leak_deposit_temperature_k thermal_step_min_ms
    thermal_check_temperature_k windup_interrupt_dose env_neighbor_radius_m env_neighbor_max env_temperature_ref_k
    env_temperature_scale_k release_dose_radius_m overline_leak_factor dropout_debt_scale dropout_max
    leak_heat_fraction release_heat_fraction thermal_sleep_delta_k thermal_sleep_power_w quote_life_slices
    scratch_unit_step scratch_precision_step)a

  @doc "读取并校验已发布目录文件；返回带 digest 的不可变值。"
  def load(path), do: decode(File.read!(path))

  @doc """
  目录字节 → `%Catalog{}`；字节即发布物，digest 取其 sha256。只接受版本 5，其余版本与任何不合规都抛出
  `ArgumentError`（消息带字段路径）。
  """
  def decode(bytes) do
    data = Jason.decode!(bytes)

    case data["version"] do
      5 -> decode_v5(bytes, data)
      other -> fail!("version", "只接受 5，收到 #{inspect(other)}")
    end
  end

  # ---------------------------------------------------------------------------
  # 版本 5
  # ---------------------------------------------------------------------------

  defp decode_v5(bytes, data) do
    known!(data, @top_fields, "目录")
    caster = object!(data, "caster")
    construction = object!(data, "construction")
    limits = object!(data, "limits")
    semblance = object!(data, "semblance")
    known!(caster, ~w(resolution_omega capacity_j max_power_w draw_efficiency), "caster")

    known!(
      construction,
      ~w(b0_w b_floor alpha e_ref_j eta_j_s_per_rad2 release_lead_s rest_pose),
      "construction"
    )

    known!(
      limits,
      ~w(program_max_bytes range_m local_domain_m cast_interval_ms backup_modes counts),
      "limits"
    )

    known!(semblance, ~w(specific_heat_j_per_kg_k thermal_conductivity_w_per_m_k), "semblance")
    known!(object!(data, "group_signature"), ["requires_all"], "group_signature")
    symbols = symbols!(list!(data, "symbols"))
    reserved = reserved!(list!(data, "reserved_symbols"), symbols)

    catalog = %__MODULE__{
      digest: :crypto.hash(:sha256, bytes),
      caster: %{
        resolution_omega: positive!(caster, "resolution_omega", "caster"),
        capacity_j: positive!(caster, "capacity_j", "caster"),
        max_power_w: positive!(caster, "max_power_w", "caster"),
        draw_efficiency: fraction!(caster, "draw_efficiency", "caster")
      },
      construction: %{
        b0_w: positive!(construction, "b0_w", "construction"),
        b_floor: positive!(construction, "b_floor", "construction"),
        alpha: positive!(construction, "alpha", "construction"),
        e_ref_j: positive!(construction, "e_ref_j", "construction"),
        eta_j_s_per_rad2: positive!(construction, "eta_j_s_per_rad2", "construction"),
        release_lead_s: non_negative!(construction, "release_lead_s", "construction"),
        rest_pose: pose!(construction["rest_pose"], "construction.rest_pose")
      },
      limits: limits!(limits),
      quotas: numbers!(object!(data, "quotas"), @quotas, "quotas"),
      runtime: runtime!(object!(data, "runtime")),
      semblance: %{
        specific_heat_j_per_kg_k: positive!(semblance, "specific_heat_j_per_kg_k", "semblance"),
        thermal_conductivity_w_per_m_k:
          positive!(semblance, "thermal_conductivity_w_per_m_k", "semblance")
      },
      group_requires_all:
        tags!(object!(data, "group_signature")["requires_all"], "group_signature.requires_all"),
      symbols: symbols,
      reserved: reserved,
      presets: []
    }

    %{catalog | presets: presets!(list!(data, "presets"), catalog)}
  end

  defp limits!(limits) do
    hard = Program.hard_limits()
    max_bytes = integer!(limits["program_max_bytes"], "limits.program_max_bytes")

    check!(
      max_bytes in 1..hard.program_max_bytes,
      "limits.program_max_bytes",
      "须在 1..#{hard.program_max_bytes}"
    )

    range = positive!(limits, "range_m", "limits")
    domain = positive!(limits, "local_domain_m", "limits")
    check!(domain <= range, "limits.local_domain_m", "不得大于 range_m")

    modes = list!(limits, "backup_modes")

    check!(
      0 in modes and Enum.all?(modes, &(&1 in [0, 1, 2])) and
        length(Enum.uniq(modes)) == length(modes),
      "limits.backup_modes",
      "须为含 0 的 {0, 1, 2} 子集"
    )

    counts = object!(limits, "counts")

    counts =
      Map.new(hard.counts, fn {name, hard_max} ->
        value = integer!(counts[Atom.to_string(name)], "limits.counts.#{name}")
        check!(value in 0..hard_max, "limits.counts.#{name}", "不得超过解码器硬上限 #{hard_max}")
        {name, value}
      end)

    known!(
      object!(limits, "counts"),
      Enum.map(Map.keys(hard.counts), &Atom.to_string/1),
      "limits.counts"
    )

    check!(counts.n_act == 1, "limits.counts.n_act", "须为 1")
    check!(counts.n_grp >= 1, "limits.counts.n_grp", "须 ≥ 1")

    %{
      program_max_bytes: max_bytes,
      range_m: range,
      local_domain_m: domain,
      cast_interval_us: round(positive!(limits, "cast_interval_ms", "limits") * 1000),
      backup_modes: modes,
      counts: counts
    }
  end

  defp runtime!(runtime) do
    numbers!(runtime, @runtime, "runtime", ["grade_multipliers", "repair_quality"])
    |> Map.put(
      :grade_multipliers,
      triple!(runtime["grade_multipliers"], "runtime.grade_multipliers")
    )
    |> Map.put(:repair_quality, triple!(runtime["repair_quality"], "runtime.repair_quality"))
  end

  defp symbols!(entries) do
    symbols = Enum.map(entries, &symbol!/1)
    check!(length(Enum.uniq_by(symbols, & &1.index)) == length(symbols), "symbols", "index 重复")
    check!(length(Enum.uniq_by(symbols, & &1.id)) == length(symbols), "symbols", "id 重复")
    Map.new(symbols, &{&1.index, &1})
  end

  # 预留下标（设计 v2.4 K3）：全部 61 个下标按 §2.3 表序一次冻结，未开放阶段的符号只占位、不发布。
  # 预留项不进入 `symbols`，所以解码层照旧按“未知下标”拒绝；发布时从预留表移入符号表，下标不变、永不复用。
  # 已发布与预留合起来必须恰好是 0..n−1，表序中不留空洞，下标与 id 都不得与已发布符号重复。
  defp reserved!(entries, symbols) do
    reserved =
      Map.new(entries, fn entry ->
        check!(is_map(entry), "reserved_symbols[]", "须为对象")
        known!(entry, ~w(index id), "reserved_symbols[]")
        id = entry["id"]
        check!(is_binary(id), "reserved_symbols[].id", "须为字符串")
        index = integer!(entry["index"], "reserved_symbols[#{id}].index")
        {index, id}
      end)

    published_ids = MapSet.new(Map.values(symbols), & &1.id)
    check!(map_size(reserved) == length(entries), "reserved_symbols", "index 重复")

    check!(
      length(Enum.uniq(Map.values(reserved))) == map_size(reserved),
      "reserved_symbols",
      "id 重复"
    )

    check!(
      Enum.all?(Map.keys(reserved), &(not Map.has_key?(symbols, &1))),
      "reserved_symbols",
      "index 与已发布符号重复"
    )

    check!(
      Enum.all?(Map.values(reserved), &(not MapSet.member?(published_ids, &1))),
      "reserved_symbols",
      "id 与已发布符号重复"
    )

    all = Map.keys(symbols) ++ Map.keys(reserved)

    check!(
      Enum.sort(all) == Enum.to_list(0..(length(all) - 1)//1),
      "reserved_symbols",
      "已发布与预留下标须恰好覆盖 0..n−1"
    )

    reserved
  end

  defp symbol!(entry) do
    id = entry["id"]
    check!(is_binary(id), "symbols[].id", "须为字符串")
    at = "symbols[#{id}]"
    known!(entry, @symbol_fields, at)
    index = integer!(entry["index"], "#{at}.index")
    check!(index in 0..0xFFFF, "#{at}.index", "须为 u16")

    section =
      Map.get(@sections, entry["section"]) ||
        fail!("#{at}.section", "未知段 #{inspect(entry["section"])}")

    params = Enum.map(list!(entry, "params"), &slot!(&1, at))
    check!(length(Enum.uniq_by(params, & &1.name)) == length(params), "#{at}.params", "槽名重复")
    names = MapSet.new(params, & &1.name)
    ranges = ranges_by_param!(entry["ranges_by_param"] || %{}, params, at)

    for slot <- params, slot.class in [:dec, :lin16, :u8], slot.min == nil do
      covered =
        Map.values(ranges)
        |> Enum.flat_map(&Map.values/1)
        |> Enum.all?(&Map.has_key?(&1, slot.name))

      check!(
        covered and ranges != %{},
        "#{at}.params.#{slot.name}",
        "数值槽须有 [min, max] 或被 ranges_by_param 每项覆盖"
      )
    end

    max_per_group = optional_count!(entry["max_per_group"], "#{at}.max_per_group")

    check!(
      max_per_group != nil or section not in @segment_sections,
      "#{at}.max_per_group",
      "段符号必须写明"
    )

    unique_by = Map.get(entry, "unique_by", [])

    check!(
      is_list(unique_by) and Enum.all?(unique_by, &(&1 in names)),
      "#{at}.unique_by",
      "须为本符号的槽名"
    )

    in_program = Map.get(entry, "in_program", true)
    check!(is_boolean(in_program), "#{at}.in_program", "须为布尔值")

    refs = Enum.map(Map.get(entry, "refs", []), &ref!(&1, params, at))

    # ref8 的非 0xFF 值只由签名层按 `refs` 判“严格在前”（设计 v2.6 S4），所以每个 ref8 槽都必须有对应声明。
    for slot <- params, slot.class == :ref8 do
      check!(
        Enum.any?(refs, &(&1.param == slot.name)),
        "#{at}.params.#{slot.name}",
        "ref8 槽须在 refs 中声明"
      )
    end

    # 计价层数值检查名（设计 §3.3）只有线协议一份定义：0x83 `rejects` 的位序（T5、T6、T13、T14、T15）。
    known_checks = Enum.map(MmoContracts.Voxel.Codec.spell_reject_checks(), &Atom.to_string/1)
    checks = Map.get(entry, "numeric_checks", [])

    check!(
      is_list(checks) and Enum.all?(checks, &(&1 in known_checks)),
      "#{at}.numeric_checks",
      "只允许 #{Enum.join(known_checks, "、")}"
    )

    # 施法者动作不建结构，数值检查只可能是 T6（设计 v2.10 E4）；Cost 的〈取〉报价只有施放处读数可判。
    check!(
      section != :caster_action or checks -- ["domain"] == [],
      "#{at}.numeric_checks",
      "施法者动作段只允许 domain"
    )

    # 可选；只有质段耦合写入性质类，其余符号不写（§4.5）。
    property_class = entry["property_class"]

    check!(
      not Map.has_key?(entry, "property_class") or
        (section == :quality and property_class in @property_classes),
      "#{at}.property_class",
      "只允许质段符号取 #{Enum.join(@property_classes, "、")}"
    )

    # 读数段必填、其余段不得写（v2.10 E2）：外部与否只看这个字段，不从签名推断。
    reading_source =
      cond do
        section != :reading ->
          check!(not Map.has_key?(entry, "reading_source"), "#{at}.reading_source", "只允许读数段符号写")
          nil

        source = @reading_sources[entry["reading_source"]] ->
          source

        true ->
          fail!("#{at}.reading_source", "读数段符号必填，取 external 或 self")
      end

    %Symbol{
      index: index,
      id: id,
      section: section,
      phase: positive_integer!(entry["phase"], "#{at}.phase"),
      in_program: in_program,
      property_class: property_class,
      reading_source: reading_source,
      params: params,
      ranges_by_param: ranges,
      provides: tags!(Map.get(entry, "provides", []), "#{at}.provides"),
      provides_by_param:
        by_param!(entry["provides_by_param"], params, &tags!/2, "#{at}.provides_by_param"),
      requires_all: tags!(Map.get(entry, "requires_all", []), "#{at}.requires_all"),
      requires_any:
        Enum.map(Map.get(entry, "requires_any", []), &tags!(&1, "#{at}.requires_any")),
      requires_by_param:
        by_param!(entry["requires_by_param"], params, &tags!/2, "#{at}.requires_by_param"),
      excludes: tags!(Map.get(entry, "excludes", []), "#{at}.excludes"),
      max_per_group: max_per_group,
      max_per_rule: optional_count!(entry["max_per_rule"], "#{at}.max_per_rule"),
      unique_by: unique_by,
      refs: refs,
      numeric_checks: checks,
      units: non_negative!(entry, "units", at),
      units_by_param:
        by_param!(entry["units_by_param"], params, &non_negative_value!/2, "#{at}.units_by_param"),
      precision: non_negative!(entry, "precision", at),
      precision_by_param:
        by_param!(
          entry["precision_by_param"],
          params,
          &non_negative_value!/2,
          "#{at}.precision_by_param"
        ),
      pose: pose!(entry["pose"], "#{at}.pose")
    }
  end

  defp slot!(entry, symbol_at) do
    name = entry["name"]
    check!(is_binary(name), "#{symbol_at}.params[].name", "须为字符串")
    at = "#{symbol_at}.params.#{name}"
    known!(entry, @slot_fields, at)

    class =
      Map.get(@classes, entry["class"]) ||
        fail!("#{at}.class", "不支持的量化类 #{inspect(entry["class"])}")

    slot = %Slot{name: name, key: name, class: class}

    slot =
      case class do
        numeric when numeric in [:dec, :lin16] ->
          {unit_class, suffix, scale, key_suffix} =
            Map.get(@units, entry["unit"]) ||
              fail!("#{at}.unit", "未知单位 #{inspect(entry["unit"])}")

          check!(unit_class == class, "#{at}.unit", "单位 #{entry["unit"]} 不属于 #{entry["class"]}")
          check!(String.ends_with?(name, suffix), at, "槽名须以单位后缀 #{suffix} 结尾（N7）")
          key = String.replace_suffix(name, suffix, key_suffix)
          %{slot | unit: entry["unit"], scale: scale, key: key}

        _ ->
          check!(not Map.has_key?(entry, "unit"), "#{at}.unit", "#{entry["class"]} 槽不带单位")
          slot
      end

    slot =
      case {Map.has_key?(entry, "min"), Map.has_key?(entry, "max")} do
        {false, false} ->
          slot

        {true, true} ->
          check!(class in [:dec, :lin16, :u8], at, "#{entry["class"]} 槽不带区间")
          {min, max} = interval!([entry["min"], entry["max"]], class, at)
          check!(slot.unit != "cdeg" or max <= 35_999, "#{at}.max", "角度上限须 < 36000（N6）")
          %{slot | min: min, max: max}

        _ ->
          fail!(at, "min 与 max 须同时给出")
      end

    %{
      slot
      | enum: published!(entry, class == :enum8, "enum", "code", 0..0xFF, at),
        bits: published!(entry, class == :mask8, "bits", "bit", 0..7, at),
        zero_means_absent: flag!(entry, "zero_means_absent", class in [:dec, :lin16, :u8], at),
        refs_enabled: flag!(entry, "refs_enabled", class == :ref8, at)
    }
  end

  # 枚举表与位表：只列已发布项（B4）；名称是解码后的值，也是 `*_by_param` 的取值键。
  defp published!(entry, wanted, field, number, range, at) do
    case {wanted, Map.get(entry, field)} do
      {false, nil} ->
        %{}

      {true, items} when is_list(items) and items != [] ->
        table =
          Map.new(items, fn item ->
            code = integer!(item[number], "#{at}.#{field}[].#{number}")

            check!(
              code in range and is_binary(item["name"]),
              "#{at}.#{field}",
              "项须为 {#{number}, name}"
            )

            {code, item["name"]}
          end)

        check!(
          map_size(table) == length(items) and
            length(Enum.uniq(Map.values(table))) == length(items),
          "#{at}.#{field}",
          "编号或名称重复"
        )

        table

      _ ->
        fail!("#{at}.#{field}", if(wanted, do: "须为非空数组", else: "该量化类不带 #{field}"))
    end
  end

  defp flag!(entry, field, allowed, at) do
    case Map.get(entry, field, false) do
      false -> false
      true -> if allowed, do: true, else: fail!("#{at}.#{field}", "该量化类不支持")
      _ -> fail!("#{at}.#{field}", "须为布尔值")
    end
  end

  # ranges_by_param：键为本符号的 enum8 槽，必须覆盖其每个已发布名称；区间对象只能列本符号的数值槽。
  defp ranges_by_param!(table, params, at) do
    check!(is_map(table), "#{at}.ranges_by_param", "须为对象")

    Map.new(table, fn {param, by_value} ->
      slot =
        Enum.find(params, &(&1.name == param)) ||
          fail!("#{at}.ranges_by_param.#{param}", "不是本符号的槽")

      check!(slot.class == :enum8, "#{at}.ranges_by_param.#{param}", "只能按 enum8 槽取值")

      check!(
        is_map(by_value) and Enum.sort(Map.keys(by_value)) == Enum.sort(Map.values(slot.enum)),
        "#{at}.ranges_by_param.#{param}",
        "须覆盖每个已发布枚举名"
      )

      {param,
       Map.new(by_value, fn {value, ranges} ->
         {value,
          Map.new(ranges, fn {name, interval} ->
            target = Enum.find(params, &(&1.name == name and &1.class in [:dec, :lin16, :u8]))
            check!(target != nil, "#{at}.ranges_by_param.#{param}.#{value}.#{name}", "不是本符号的数值槽")

            {name,
             interval!(interval, target.class, "#{at}.ranges_by_param.#{param}.#{value}.#{name}")}
          end)}
       end)}
    end)
  end

  # `*_by_param` 的取值键：枚举名；数值的十进制字符串；`"present"` 匹配任何已写入的值（schema 文档 §5）。
  defp by_param!(nil, _params, _value!, _at), do: %{}

  defp by_param!(table, params, value!, at) do
    check!(is_map(table), at, "须为对象")

    Map.new(table, fn {param, by_value} ->
      slot = Enum.find(params, &(&1.name == param)) || fail!("#{at}.#{param}", "不是本符号的槽")
      check!(is_map(by_value), "#{at}.#{param}", "须为对象")

      {param,
       Map.new(by_value, fn {key, value} ->
         check!(key_allowed?(slot, key), "#{at}.#{param}.#{key}", "不是该槽可能的取值键")
         {key, value!.(value, "#{at}.#{param}.#{key}")}
       end)}
    end)
  end

  defp key_allowed?(_slot, "present"), do: true
  defp key_allowed?(%Slot{class: :enum8, enum: enum}, key), do: key in Map.values(enum)
  defp key_allowed?(%Slot{class: :ref8}, _key), do: false
  defp key_allowed?(_slot, key), do: match?({_, ""}, Integer.parse(key))

  defp ref!(entry, params, at) do
    param = entry["param"]

    check!(
      Enum.any?(params, &(&1.name == param and &1.class == :ref8)),
      "#{at}.refs",
      "param 须为本符号的 ref8 槽"
    )

    check!(entry["must_be"] == "earlier", "#{at}.refs", "must_be 目前只支持 earlier")

    kind =
      case entry["kind"] do
        "group" -> :group
        "rule" -> :rule
        other -> fail!("#{at}.refs", "未知引用种类 #{inspect(other)}")
      end

    %{param: param, kind: kind}
  end

  defp presets!(entries, catalog) do
    presets =
      Enum.map(entries, fn entry ->
        at = "presets[#{entry["id"]}]"
        check!(is_binary(entry["id"]) and is_binary(entry["name"]), at, "须有 id 与 name")
        # 小写十六进制、无空格（N8）。
        bytes =
          case is_binary(entry["program_hex"]) &&
                 Base.decode16(entry["program_hex"], case: :lower) do
            {:ok, bytes} -> bytes
            _ -> fail!("#{at}.program_hex", "须为小写十六进制字符串")
          end

        case Program.diagnose_ir(bytes, catalog) do
          {:ok, _} -> %{id: entry["id"], name: entry["name"], program: bytes}
          {:error, reason} -> fail!("#{at}.program_hex", "不是合法程序：#{inspect(reason)}")
        end
      end)

    check!(length(Enum.uniq_by(presets, & &1.id)) == length(presets), "presets", "id 重复")
    presets
  end

  # ---- 字段读取与校验小工具：失败一律带字段路径抛出 ArgumentError ----

  defp object!(data, field) do
    case data[field] do
      value when is_map(value) -> value
      _ -> fail!(field, "须为对象")
    end
  end

  defp list!(data, field) do
    case data[field] do
      value when is_list(value) -> value
      _ -> fail!(field, "须为数组")
    end
  end

  defp numbers!(data, keys, at, list_fields \\ []) do
    known!(data, Enum.map(keys, &Atom.to_string/1) ++ list_fields, at)
    Map.new(keys, &{&1, positive!(data, Atom.to_string(&1), at)})
  end

  # 拒绝拼错或未定义的字段，避免签名等数据被静默忽略。
  defp known!(data, fields, at) do
    extra = Map.keys(data) -- fields
    check!(extra == [], at, "含未知字段 #{Enum.join(extra, "、")}")
  end

  defp triple!(value, at) do
    check!(
      is_list(value) and length(value) == 3 and Enum.all?(value, &(is_number(&1) and &1 > 0)),
      at,
      "须为 3 个正数"
    )

    value
  end

  defp tags!(value, at) do
    check!(is_list(value) and Enum.all?(value, &is_binary/1), at, "须为标签字符串数组")
    value
  end

  defp positive!(data, field, at) do
    value = data[field]
    check!(is_number(value) and value > 0, "#{at}.#{field}", "须为正数")
    value
  end

  defp non_negative!(data, field, at), do: non_negative_value!(data[field], "#{at}.#{field}")

  defp non_negative_value!(value, at) do
    check!(is_number(value) and value >= 0, at, "须为非负数")
    value
  end

  defp fraction!(data, field, at) do
    value = positive!(data, field, at)
    check!(value <= 1, "#{at}.#{field}", "须 ≤ 1")
    value
  end

  defp integer!(value, at) do
    check!(is_integer(value), at, "须为整数")
    value
  end

  defp positive_integer!(value, at) do
    check!(is_integer(value) and value > 0, at, "须为正整数")
    value
  end

  defp optional_count!(nil, _at), do: nil
  defp optional_count!(value, at), do: positive_integer!(value, at)

  # 区间以槽单位计、闭区间；上界不得超过量化类能表示的最大值。
  defp interval!([min, max], class, at) when is_integer(min) and is_integer(max) do
    check!(
      0 <= min and min <= max and max <= Map.fetch!(@class_max, class),
      at,
      "须为 0 ≤ min ≤ max ≤ 量化类上限"
    )

    {min, max}
  end

  defp interval!(_, _class, at), do: fail!(at, "须为整数 [min, max]")

  defp pose!(value, at) do
    check!(pose?(value), at, "须为 6 个整数度、5 的倍数、|q| ≤ 175")
    Enum.map(value, &(&1 * :math.pi() / 180))
  end

  defp check!(true, _at, _reason), do: :ok
  defp check!(_, at, reason), do: fail!(at, reason)

  defp fail!(at, reason), do: raise(ArgumentError, "magic catalog v5: #{at}: #{reason}")

  defp pose?(p),
    do:
      is_list(p) and length(p) == 6 and
        Enum.all?(p, &(is_integer(&1) and rem(&1, 5) == 0 and abs(&1) <= 175))
end
