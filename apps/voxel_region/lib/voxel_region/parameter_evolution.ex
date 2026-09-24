defmodule VoxelRegion.ParameterEvolution do
  @moduledoc "全局系统功能：目录参数升级的兼容规则与热参考重标纯计算。"
  alias VoxelRegion.{Phase, Damage, Attachments, ThermalAttachments}

  @doc "保留在用材料、工具、相变及数量语义，只允许参数发布契约声明的变化；新目录 retired_tools 列出的工具可撤下（retire_devices 迁移）。"
  def compatible?(old, new) do
    material_fields =
      ~w(display_name tags heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin ignition_kelvin fuel_energy_per_macro_j burn_power_per_macro_w electrical_conductivity phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j) ++
        # 单向转化是一次性事件，行上不存进度：五个字段可在线新增、调整或撤下。
        ~w(transform_material_id transform_kelvin transform_heat_per_macro_j transform_reductant_material_id transform_reductant_units_per_unit) ++
        # 塞贝克系数只在每次求解时现读，行上不存与之相关的量。储能轴不在此列：行上的 stored_j 以它为容量。
        ~w(seebeck_v_per_k) ++
        # R8-07 散体休止阈值只在每步流动时现读（改动唤醒全部有限格）：可在线新增或调整；
        # 已可倾倒的材料不能撤下（世界里可能有它的散体格），见下方检查。
        ~w(loose_threshold_units)

    # 设备电阻只在每次建电路时按目录现读（Circuit.prepare），行上不存与之相关的量：可在线调整。
    tool_fields =
      ~w(display_name interval_seconds fuel_units heat_energy_j heat_power_w cooling_energy_j circuit_energy_j circuit_resistance_ohm)

    phase_fields =
      ~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j heat_capacity_per_macro max_hp_per_macro)

    old.attachments == new.attachments and liquid_compatible?(old.liquid, new.liquid) and
      Enum.all?(old.materials, fn {id, material} ->
        case Map.fetch(new.materials, id) do
          {:ok, next} ->
            Map.drop(material, material_fields) == Map.drop(next, material_fields) and
              (not Map.has_key?(material, "loose_threshold_units") or Map.has_key?(next, "loose_threshold_units")) and
              (not Phase.enabled?(material) or
                 Map.take(material, phase_fields) == Map.take(next, phase_fields))

          :error ->
            false
        end
      end) and
      Enum.all?(old.tools, fn {id, tool} ->
        case Map.fetch(new.tools, id) do
          {:ok, next} -> Map.drop(tool, tool_fields) == Map.drop(next, tool_fields)
          # 有在用设备的工具（安装类）退役时必须给出迁移材料。
          :error -> Map.has_key?(new.retired, id) and (tool["action"] != "circuit.install" or new.retired[id] != nil)
        end
      end)
  end

  # 全局系统功能：液体只允许在线调整侧向水位差阈值。
  # 缺失阈值沿用原有零阈值语义。
  defp liquid_compatible?(nil, nil), do: true
  defp liquid_compatible?(old, new) when is_map(old) and is_map(new),
    do: Map.delete(old, "side_threshold_units") == Map.delete(new, "side_threshold_units")
  defp liquid_compatible?(_, _), do: false

  @doc """
  按实际属性行重标热参考；不供能、不改变温度、燃料、HP 或库存。
  fill 给出宏格行的有限体积比例（散体按数量，R8-07）；缺省为满格。
  """
  def thermal_reference(thermal, rows, old_catalog, catalog, fill \\ fn _ -> 1.0 end)
  def thermal_reference(nil, _rows, _old, _catalog, _fill), do: nil

  def thermal_reference(thermal, rows, old_catalog, catalog, fill) do
    ambient = thermal.config["ambient_kelvin"]

    rebase =
      Enum.reduce(rows, 0.0, fn {_, row}, sum ->
        old = old_catalog.materials[row.material]

        if row.granularity in [0, 1, 4] and Map.has_key?(row, :temperature_kelvin) and
             not Phase.enabled?(old) do
          volume =
            if row.granularity == 4,
              do: VoxelRegion.ThermalAttachments.volume(Attachments.slot(row), old_catalog),
              else: Damage.volume(row.granularity) * fill.(row)

          next = catalog.materials[row.material]

          previous =
            volume * Map.get(old, "heat_capacity_per_macro", 0.0) *
              (row.temperature_kelvin - ambient)

          current =
            if row.granularity == 0 and Phase.enabled?(next),
              do: Phase.energy(row, volume, next, ambient),
              else: volume * next["heat_capacity_per_macro"] * (row.temperature_kelvin - ambient)

          sum + current - previous
        else
          sum
        end
      end)

    Map.update(thermal, :parameter_rebase_j, rebase, &(&1 + rebase))
  end

  @doc """
  按新目录重标已点燃行的剩余燃料与燃烧功率，保持已烧比例不变。
  两者都与体积成正比，按单宏格字段之比缩放即对宏格、微格、附件同样成立；
  熄灭行功率为零仍为零。差额记入独立燃料重标账，不计为燃烧或供热。
  """
  def combustion(damage, nil, _old_catalog, _catalog), do: {damage, nil}

  def combustion(damage, thermal, old_catalog, catalog) do
    {damage, rebase} =
      Enum.map_reduce(damage, 0.0, fn {key, row}, sum ->
        if Map.has_key?(row, :remaining_fuel_j) do
          old = old_catalog.materials[row.material]
          next = catalog.materials[row.material]

          remaining =
            row.remaining_fuel_j / old["fuel_energy_per_macro_j"] * next["fuel_energy_per_macro_j"]

          power = row.power_w / old["burn_power_per_macro_w"] * next["burn_power_per_macro_w"]

          {{key, %{row | remaining_fuel_j: remaining, power_w: power}},
           sum + remaining - row.remaining_fuel_j}
        else
          {{key, row}, sum}
        end
      end)

    {Map.new(damage), Map.update(thermal, :fuel_rebase_j, rebase, &(&1 + rebase))}
  end

  @doc """
  R8-04 增量 2／3（D8）：新目录 `retired_tools` 撤下的设备工具，其在用设备在同一次发布里变成同一附件的材料面：
  整件行去掉电路记录、换成映射材料（映射到开关材料时保持原开合），逐槽热行换材料键（旧键出删除记录）、温度不变；
  整件与逐槽 HP 按两种材料每宏格 HP 之比缩放；槽热容差按 thermal_reference 同一口径计入参数重标账。
  电源（增量 3，映射到铜面）的剩余电能不退还，记入 `circuit_removed_j`。撤下加热器投料工具（动作 heat）时，
  它付费注入的有限热源一并撤销，剩余热能记入 `discarded_source_j`。
  返回 %{damage, attachments, slots（改了材料的槽）, tombstones（旧槽热行）, thermal}。
  """
  def retire_devices(damage, attachments, nil, _old, _new),
    do: %{damage: damage, attachments: attachments, slots: [], tombstones: [], thermal: nil}

  def retire_devices(damage, attachments, thermal, old, new) do
    ambient = thermal.config["ambient_kelvin"]

    moved =
      for {_, %{granularity: 3, circuit: c} = t} <- damage, Map.has_key?(new.retired, c.tool_id), into: %{},
        do: {t.incarnation, {t.material, new.retired[c.tool_id], c.closed}}

    removed =
      for {_, %{granularity: 3, circuit: c}} <- damage, Map.has_key?(new.retired, c.tool_id), reduce: 0.0,
        do: (sum -> sum + Map.get(c, :remaining_j, 0.0))

    heater? = Enum.any?(old.tools, fn {id, t} -> t["action"] == "heat" and Map.has_key?(new.retired, id) end)
    discarded = if heater?, do: Enum.reduce(thermal.sources, 0.0, fn {_, source}, sum -> sum + source.remaining_j end), else: 0.0
    thermal = if heater?, do: %{thermal | sources: %{}}, else: thermal

    {rows, {tombstones, rebase}} =
      Enum.map_reduce(damage, {[], 0.0}, fn {key, row}, {tombstones, sum} ->
        case {row.granularity, Map.get(moved, row.incarnation)} do
          {granularity, {from, to, closed}} when granularity in [3, 4] ->
            ratio = new.materials[to]["max_hp_per_macro"] / old.materials[from]["max_hp_per_macro"]
            next = %{row | material: to, hp: row.hp * ratio, max_hp: row.max_hp * ratio}

            if granularity == 3 do
              next = Map.delete(next, :circuit)
              next = if Map.get(new.materials[to], "circuit_switch", false), do: Map.put(next, :closed, closed), else: next
              {{key, next}, {tombstones, sum}}
            else
              energy =
                ThermalAttachments.volume(Attachments.slot(row), old) *
                  (new.materials[to]["heat_capacity_per_macro"] - old.materials[from]["heat_capacity_per_macro"]) *
                  (row.temperature_kelvin - ambient)

              {{Damage.key(next), next}, {[row | tombstones], sum + energy}}
            end

          _ ->
            {{key, row}, {tombstones, sum}}
        end
      end)

    slots = for {slot, {id, _}} <- attachments, Map.has_key?(moved, id), do: slot

    %{
      damage: Map.new(rows),
      attachments:
        Enum.reduce(slots, attachments, fn slot, all ->
          Map.update!(all, slot, fn {id, _} -> {id, elem(Map.fetch!(moved, id), 1)} end)
        end),
      slots: slots,
      tombstones: tombstones,
      thermal:
        thermal
        |> Map.update(:parameter_rebase_j, rebase, &(&1 + rebase))
        |> Map.update(:circuit_removed_j, removed, &(&1 + removed))
        |> Map.update(:discarded_source_j, discarded, &(&1 + discarded))
    }
  end
end
