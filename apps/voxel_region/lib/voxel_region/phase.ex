defmodule VoxelRegion.Phase do
  @moduledoc """
  全局系统功能：有限宏格（液体、相态材料与 R8-07 散体）随数量搬运的广延量。
  各相族以凝固相在目录转变温度处为零焓；潜热段恒温，整格完成后换材料。
  无相变的散体以相对环境的显热 C·V·(T − T_amb) 为能量（与热账同一参考）。
  完整度为数量乘HP比例的广延量，流动、携带与再凝固不会免费修复。
  格值为 `{能量, 完整度, 已烧燃料, 火}`：已烧燃料 = 满燃料 − 剩余燃料（未初始化为 0），随数量按比例搬运；
  火为 nil（燃料未初始化）/ false（已初始化未燃）/ true（燃烧），合并取较强者，流入燃烧格或带火流入即燃烧。
  只计算值，不读取 World、不分配事务序号、不保存库存或发送消息。

  ## 整数定点单位（格值的唯一定义处）

  格值在内存中是整数：能量单位 µJ；完整度单位 = 数量单位 × 2^10（满 HP 的 q 单位格 = q·2^10）；
  已烧燃料单位 = 满燃料分数 × 数量单位 × 2^18（全烧 = q·2^18，剩余燃料 J = 满燃料 J × (q·2^18 − 已烧)/(q·2^18)）。
  整数单位就是最小单位，没有更小的数量。搬运按源格累计取整（`portions/3`）：一个源格同一阶段的外流按目标格键排序，
  c_k = v·(u_1+…+u_k)/q 为精确有理数，第 k 笔得 floor(c_k) − floor(c_{k−1})，源格留 v − floor(c_n)；源减、目标加同一整数，
  能量、完整度、已烧燃料用同一规则。每个源格只读阶段起点值，之后只做整数加减（火标记取较强者），所以结果与流列表次序、
  map 遍历次序和 OTP 版本无关。
  上界由构造保证：若 0 ≤ v ≤ q·S（S 为每单位满值：完整度 2^10、已烧 2^18），则 c_k − c_{k−1} = v·u_k/q ∈ [0, u_k·S]，
  相邻 floor 之差落在 [0, u_k·S]；余数 v − floor(c_n) = ceil(v·(q−Σu)/q) ∈ [0, (q−Σu)·S]。所以每格的完整度、已烧燃料、
  剩余燃料都在 [0, 满值] 内，HP 比例 ∈ [0, 1]。逐笔各自 floor 会让分 n 笔流出的源格多留至多 n−1 个单位（剩余燃料变负、
  HP 比例 > 1），逐笔各自 ceil 会让源格欠下同样多（已烧或完整度 < 0）；累计取整两者都不会。

  属性行、库存、持久化、线格式和热内核仍是浮点；只在两处换算：读行时 `quantize/1,2`，写回行与入库存时
  `dequantize/1,2`。浮点→整数一律用 `Kernel.round/1`（四舍五入，半数远离零）。剩余燃料先按满燃料分数取整再求已烧，
  所以低于半个燃料单位的剩余燃料读作 0（全烧）。这是“整数单位即最小单位”的定义，不是误差，只出现在一期保留的浮点行边界上。

  一期已知限制：纯搬运的燃料账精确为零，但全局燃料闭合（初始化 = 燃烧 + 弃置 + 还原剂 + 行上余量）不精确。热内核写回的
  剩余燃料是浮点、不在燃料单位格点上，下次被读入并写回时取整，每读入一行至多半个燃料单位，这部分不入账。
  消除它要把剩余燃料以整数存进属性行（审计候选 #2），排在分发版本之后。
  库存是浮点 `{能量 J, 完整度 数量单位}` 二元组：舀取按整数拆分后反量化入库，倾倒按库存浮点比例取出后量化入格。
  """

  @energy_unit 1_000_000
  @integrity_unit 1024
  @fuel_unit 262_144

  alias VoxelRegion.Combustion

  @typedoc "格值 {能量 µJ, 完整度 q·2^10}（整数）或库存 {能量 J, 完整度 数量单位}（浮点）；数量和余额另由 World 持有。"
  @type extensive :: {number(), number()}
  @typedoc "本次已读取的格摘要，包含空气及无相变材质。"
  @type samples :: %{term() => {non_neg_integer(), extensive()}}
  @typedoc "相变结算所需的材料参数；只有新作者格的环境初始化需要 ambient。"
  @type settlement_context :: %{
          materials: map(),
          capacity: pos_integer(),
          ambient: number() | nil,
          material: non_neg_integer()
        }

  def enabled?(material), do: Map.has_key?(material, "phase_peer_material_id")

  @doc "当前已实现的液态身份；相变能力仍由目录字段接纳。"
  def liquid?(material), do: material in [21, 22]

  @doc "本轮明确支持的有向相变；雪融水后只重新凝固为冰。"
  def valid_pair?(material, peer),
    do: {material, peer} in [{4, 21}, {20, 21}, {21, 20}, {13, 22}, {22, 13}]

  @doc "有限宏格的能量：相态材料为相族焓（energy/4），散体为相对环境的显热；无热环境时散体温度不建模，能量为零。"
  def finite_energy(row, volume, material, ambient) do
    cond do
      enabled?(material) -> energy(row, volume, material, ambient)
      ambient == nil -> 0.0
      true -> material["heat_capacity_per_macro"] * volume * (Map.get(row, :temperature_kelvin, ambient) - ambient)
    end
  end

  def energy(row, volume, material, ambient) do
    Map.get_lazy(row, :phase_energy_j, fn ->
      latent = if liquid?(row.material), do: material["latent_heat_per_macro_j"], else: 0.0

      volume *
        (latent +
           material["heat_capacity_per_macro"] *
             (Map.get(row, :temperature_kelvin, ambient) - material["phase_transition_kelvin"]))
    end)
  end

  def temperature(material, energy, volume, properties) do
    m = Map.fetch!(properties, material)

    sensible =
      if liquid?(material),
        do: max(0.0, energy - volume * m["latent_heat_per_macro_j"]),
        else: min(0.0, energy)

    m["phase_transition_kelvin"] + sensible / (volume * m["heat_capacity_per_macro"])
  end

  def material(material, energy, volume, properties) do
    latent = volume * properties[material]["latent_heat_per_macro_j"]
    # 整数格值与按同一规则取整的潜热比较：工具写入的精确终点量化后仍恰在阈值上。
    latent = if is_integer(energy), do: round(latent * @energy_unit), else: latent

    cond do
      liquid?(material) and energy <= 0.0 -> properties[material]["phase_peer_material_id"]
      not liquid?(material) and energy >= latent -> properties[material]["phase_peer_material_id"]
      true -> material
    end
  end

  # 与数量内核共用同步通量，每阶段冻结来源，不能在两个阶段重复转移。
  def transport(values, quantities, transfers) do
    transfers
    |> Enum.group_by(fn {from, _to, _units} -> from end, fn {_from, to, units} -> {to, units} end)
    |> Enum.reduce(values, fn {from, outflows}, out ->
      outflows
      |> portions(Map.fetch!(values, from), Map.fetch!(quantities, from))
      |> Enum.reduce(out, fn {to, moved}, out -> out |> add(from, scale(moved, -1)) |> add(to, moved) end)
    end)
  end

  @doc """
  一个源格（q 单位、阶段起点值 value）同一阶段的全部外流 `[{目标, units}]` 的累计取整拆分：按目标格键排序
  （同一源格的几笔外流没有构造次序，键序就是定义），第 k 笔得 floor(v·C_k/q) − floor(v·C_{k−1}/q)，C_k 为前 k 笔单位之和；
  源格留 v − floor(v·C_n/q)。三个分量用同一规则。
  """
  def portions(outflows, value, q) do
    {portions, _, _} =
      outflows
      |> Enum.sort()
      |> Enum.reduce({[], 0, split(value, 0, q)}, fn {to, units}, {portions, total, taken} ->
        next = split(value, total + units, q)
        {[{to, merge(next, scale(taken, -1))} | portions], total + units, next}
      end)

    portions
  end

  @doc "q 单位整数格值中前 units 单位所带的部分：每个分量 floor_div(v·units, q)。"
  def split({energy, integrity}, units, q),
    do: {Integer.floor_div(energy * units, q), Integer.floor_div(integrity * units, q)}

  def split({energy, integrity, burnt, fire}, units, q),
    do: {Integer.floor_div(energy * units, q), Integer.floor_div(integrity * units, q),
      Integer.floor_div(burnt * units, q), fire}

  @doc "整数完整度对应的 HP；写回行与采掘扣减用同一换算，HP 与基准落在同一格点上。"
  def hp(maximum, integrity, units), do: maximum * max(0.0, min(1.0, integrity / @integrity_unit / units))

  @doc "浮点 → 整数格值。二元组为 {能量 J, 完整度 数量单位}；四元组第三项是剩余燃料占满燃料的比例（火为 nil 时不读）。"
  def quantize({energy, integrity}), do: {round(energy * @energy_unit), round(integrity * @integrity_unit)}

  def quantize({energy, integrity, remaining, fire}, q) do
    {e, i} = quantize({energy, integrity})
    {e, i, if(fire == nil, do: 0, else: full_fuel(q) - round(remaining * full_fuel(q))), fire}
  end

  @doc "整数格值 → 浮点。二元组为 {能量 J, 完整度 数量单位}；四元组第三项为剩余燃料占满燃料的比例。"
  def dequantize({energy, integrity}), do: {energy / @energy_unit, integrity / @integrity_unit}

  def dequantize({energy, integrity, burnt, fire}, q) do
    {e, i} = dequantize({energy, integrity})
    {e, i, (full_fuel(q) - burnt) / full_fuel(q), fire}
  end

  def add(values, key, value), do: Map.update(values, key, value, &merge(&1, value))

  @doc "同材料两份值合并：广延量相加，火取较强者。"
  def merge({e, i}, {e2, i2}), do: {e + e2, i + i2}
  def merge({e, i, b, f}, {e2, i2, b2, f2}), do: {e + e2, i + i2, b + b2, fire(f, f2)}

  @doc "格值的 {能量, 完整度} 部分（库存只携带这两项）。"
  def pair({energy, integrity}), do: {energy, integrity}
  def pair({energy, integrity, _burnt, _fire}), do: {energy, integrity}

  def scale({energy, integrity}, factor), do: {energy * factor, integrity * factor}
  def scale({energy, integrity, burnt, fire}, factor),
    do: {energy * factor, integrity * factor, burnt * factor, fire}

  defp fire(a, b) when a == true or b == true, do: true
  defp fire(nil, nil), do: nil
  defp fire(_, _), do: false

  @doc "按已接纳的来源数量在整数格值与浮点库存之间搬运焓和完整度，返回格与库存的新值。"
  @spec transfer(extensive(), extensive(), pos_integer(), pos_integer(), :scoop | :pour) ::
          {extensive(), extensive()}
  def transfer(cell, inventory, source_units, moved, :scoop) do
    portion = split(cell, moved, source_units)
    {merge(cell, scale(portion, -1)), merge(inventory, dequantize(portion))}
  end

  def transfer(cell, inventory, source_units, moved, :pour) do
    portion = scale(inventory, moved / source_units)
    {merge(cell, quantize(portion)), merge(inventory, scale(portion, -1))}
  end

  @doc """
  按实际有限数量和携带值派生属性；身份、事务序号仍由调用方持有。
  相态材料写焓与温度；散体按显热写温度（ambient 为 nil 时不建模温度），可燃散体的燃料已初始化（火非 nil）时
  写剩余燃料 = 满燃料 − 已烧、燃烧功率 = 每宏格功率 × 体积。
  """
  def restore(row, value, units, capacity, properties, ambient \\ nil)

  def restore(row, {energy, integrity}, units, capacity, properties, ambient),
    do: restore(row, {energy, integrity, 0, nil}, units, capacity, properties, ambient)

  def restore(row, value, units, capacity, properties, ambient) do
    {energy, _integrity, fuel, fire} = dequantize(value, units)
    volume = units / capacity
    material = properties[row.material]
    maximum = material["max_hp_per_macro"] * volume
    row = Map.merge(row, %{max_hp: maximum, hp: hp(maximum, elem(value, 1), units)})

    cond do
      enabled?(material) ->
        Map.merge(row, %{
          phase_energy_j: energy,
          temperature_kelvin: temperature(row.material, energy, volume, properties)
        })

      ambient == nil ->
        row

      true ->
        row = Map.put(row, :temperature_kelvin, ambient + energy / (material["heat_capacity_per_macro"] * volume))

        if fire != nil and Combustion.combustible?(material) do
          remaining = Combustion.capacity_j(material, volume) * fuel
          burning = fire and fuel > 0.0
          Map.merge(row, %{remaining_fuel_j: remaining, burning: burning,
            power_w: if(burning, do: Combustion.power_w(material, volume), else: 0.0)})
        else
          row
        end
    end
  end

  @doc "q 单位格值中已初始化的剩余燃料（燃料单位，整数）；未初始化或不可燃为 0。热账的燃料初始化／移除按它前后之差记。"
  def explicit_fuel({_, _}, _material, _q), do: 0
  def explicit_fuel({_, _, _, nil}, _material, _q), do: 0

  def explicit_fuel({_, _, burnt, _}, material, q) do
    if Combustion.combustible?(material), do: full_fuel(q) - burnt, else: 0
  end

  @doc "q 单位的满燃料（燃料单位）。"
  def full_fuel(q), do: q * @fuel_unit

  @doc "燃料单位换算成 J（capacity 为单格数量容量）。"
  def fuel_j(units, material, capacity), do: Combustion.capacity_j(material, units / (capacity * @fuel_unit))

  @doc "已接纳工具的有限能量账；足额时精确抵达相变端点，不把多付能量注入材料。"
  def tool_energy(energy, volume, material, tool) do
    cool = tool["action"] == "phase.cool"
    budget = tool[if(cool, do: "cooling_energy_j", else: "heat_energy_j")]
    goal = if cool, do: 0.0, else: volume * material["latent_heat_per_macro_j"]
    needed = max(0.0, if(cool, do: energy - goal, else: goal - energy))
    used = min(budget, needed)
    signed = if cool, do: -used, else: used
    # 直接写精确终点，避免负初焓的减加抵消将结果留在阈值下方。
    %{
      energy: if(budget >= needed, do: goal, else: energy + signed),
      supplied_j: signed,
      paid_j: budget,
      unused_j: budget - used
    }
  end

  @doc "以当前格摘要和显式运输值结算材质；仅无运输值的新作者格初始化环境焓。"
  @spec settle(map(), samples(), %{term() => extensive()}, settlement_context()) ::
          {list(), %{term() => extensive()}}
  def settle(changes, current, supplied, context) do
    %{materials: properties, capacity: capacity, ambient: ambient, material: liquid} = context
    values = Map.new(current, fn {cell, {_, value}} -> {cell, value} end)

    values =
      Enum.reduce(changes, values, fn {cell, units}, values ->
        {old, _} = Map.fetch!(current, cell)

        if units > 0 and old == 0 and not Map.has_key?(supplied, cell) do
          energy = finite_energy(%{material: liquid}, units / capacity, properties[liquid], ambient)
          fresh = if tuple_size(elem(Map.fetch!(current, cell), 1)) == 4,
            do: quantize({energy, units, nil, nil}, units), else: quantize({energy, units})
          Map.put(values, cell, fresh)
        else
          values
        end
      end)

    values = Map.merge(values, supplied)

    edits =
      Enum.map(changes, fn {cell, units} ->
        {old, _} = Map.fetch!(current, cell)
        old = if enabled?(properties[old]), do: old, else: liquid

        next =
          cond do
            units == 0 ->
              0

            enabled?(properties[old]) ->
              material(old, elem(Map.fetch!(values, cell), 0), units / capacity, properties)

            true ->
              liquid
          end

        {cell, next}
      end)

    {edits, values}
  end

  @doc "逐阶段搬运广延量；净数量未变但参与通量的格也进入提交结果。"
  def transport_stages(values, quantities, changes, stages) do
    values =
      Enum.reduce(stages, values, fn {units, flows}, values -> transport(values, units, flows) end)

    affected = for {_units, flows} <- stages, {from, to, _} <- flows, cell <- [from, to], do: cell

    changes =
      Enum.reduce(affected, changes, fn cell, changes ->
        Map.put_new(changes, cell, Map.get(quantities, cell, 0))
      end)

    {changes, Map.take(values, Map.keys(changes))}
  end
end
