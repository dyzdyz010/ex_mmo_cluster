defmodule VoxelRegion.Phase do
  @moduledoc """
  全局系统功能：水/冰当量（含雪）与玄武岩/熔岩的有限焓和完整度搬运。
  各相族以凝固相在目录转变温度处为零焓；潜热段恒温，整格完成后换材料。
  完整度为数量乘HP比例的广延量，流动、携带与再凝固不会免费修复。
  只计算值，不读取 World、不分配事务序号、不保存库存或发送消息。
  """

  @typedoc "焓（J）与数量乘 HP 比例的完整度；数量和余额另由 World 持有。"
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

    cond do
      liquid?(material) and energy <= 0.0 -> properties[material]["phase_peer_material_id"]
      not liquid?(material) and energy >= latent -> properties[material]["phase_peer_material_id"]
      true -> material
    end
  end

  # 与数量内核共用同步通量，每阶段冻结来源，不能在两个阶段重复转移。
  def transport(values, quantities, transfers) do
    Enum.reduce(transfers, values, fn {from, to, units}, out ->
      {energy, integrity} = Map.fetch!(values, from)
      ratio = units / Map.fetch!(quantities, from)
      moved = {energy * ratio, integrity * ratio}
      out |> add(from, scale(moved, -1)) |> add(to, moved)
    end)
  end

  def add(values, key, {energy, integrity}) do
    Map.update(values, key, {energy, integrity}, fn {e, i} -> {e + energy, i + integrity} end)
  end

  def scale({energy, integrity}, factor), do: {energy * factor, integrity * factor}

  @doc "按已接纳的来源数量搬运焓和完整度，返回格与库存的新广延量。"
  @spec transfer(extensive(), extensive(), pos_integer(), pos_integer(), :scoop | :pour) ::
          {extensive(), extensive()}
  def transfer(cell, inventory, source_units, moved, action) do
    {source, sign} = if action == :scoop, do: {cell, -1}, else: {inventory, 1}
    portion = scale(source, moved / source_units)

    values =
      %{cell: cell, inventory: inventory}
      |> add(:cell, scale(portion, sign))
      |> add(:inventory, scale(portion, -sign))

    {values.cell, values.inventory}
  end

  @doc "按实际有限数量和携带完整度派生属性；身份、事务序号仍由调用方持有。"
  def restore(row, {energy, integrity}, units, capacity, properties) do
    volume = units / capacity
    maximum = properties[row.material]["max_hp_per_macro"] * volume

    Map.merge(row, %{
      max_hp: maximum,
      hp: maximum * max(0.0, min(1.0, integrity / units)),
      phase_energy_j: energy,
      temperature_kelvin: temperature(row.material, energy, volume, properties)
    })
  end

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
          energy = energy(%{material: liquid}, units / capacity, properties[liquid], ambient)
          Map.put(values, cell, {energy, units * 1.0})
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
