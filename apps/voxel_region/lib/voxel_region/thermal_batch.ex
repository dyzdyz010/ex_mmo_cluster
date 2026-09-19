defmodule VoxelRegion.ThermalBatch do
  @moduledoc """
  全局系统功能：由本次已读取的节点、属性、相态体积构造热内核批次。
  只计算有限时长、供能预算和事件参数，不访问 World、不保存演化状态。
  """
  alias VoxelRegion.{Combustion, Phase}

  @typedoc "按接触索引原顺序排列的节点键、几何摘要、当前属性和可选相态体积。"
  @type sample :: {term(), map(), map(), number() | nil}

  @doc "共同批长不越过有限源/燃料耗尽点；返回内核输入及按同一顺序结算所需的目标摘要。"
  @spec prepare([sample()], map(), map(), MapSet.t(), number(), number()) :: map()
  def prepare(samples, sources, powers, hot, ambient, duration) do
    duration =
      Enum.reduce(sources, duration, fn {_, s}, dt -> min(dt, s.remaining_j / s.power_w) end)

    duration =
      Enum.reduce(samples, duration, fn {_, _, row, _}, dt ->
        if Map.get(row, :burning, false),
          do: min(dt, row.remaining_fuel_j / row.power_w),
          else: dt
      end)

    {targets, input} =
      Enum.map(samples, fn {key, n, row, volume} ->
        temperature = Map.get(row, :temperature_kelvin, ambient)
        source = if row.granularity == 0, do: Map.get(sources, n.cell)
        combustion = if Map.get(row, :burning, false), do: row.power_w, else: 0.0
        electric = Map.get(powers, key, 0.0)
        power = electric + combustion + if(source, do: source.power_w * 1.0, else: 0.0)

        ignition =
          if n.ignition != nil and row.hp > 0 and
               not Map.get(row, :burning, false) and not Combustion.exhausted?(row),
             do: n.ignition,
             else: nil

        phase =
          if volume != nil do
            {Phase.energy(row, volume, n.material, ambient), volume * 1.0,
             n.material["phase_transition_kelvin"] * 1.0,
             volume * n.material["latent_heat_per_macro_j"],
             n.material["heat_capacity_per_macro"] * 1.0, Phase.liquid?(row.material)}
          end

        {{n.cell, n.cells, row, temperature, electric, combustion},
         {{temperature, row.hp, row.max_hp, n.capacity, n.material["thermal_conductivity"] * 1.0,
           n.material["heat_resistance_kelvin"] * 1.0, n.exposed_faces * 1.0, power,
           abs(power) * duration,
           Enum.any?(n.cells, &MapSet.member?(hot, &1)) or source != nil or combustion > 0 or
             electric != 0}, {ignition, phase, row.granularity in [1, 4]}}}
      end)
      |> Enum.unzip()

    %{duration: duration, targets: targets, input: input}
  end
end
