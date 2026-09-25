defmodule VoxelRegion.ThermalSettlement do
  @moduledoc "全局系统功能：结算热内核的有限源、属性与部件损伤；纯值输入输出，不持有 World。"
  alias VoxelRegion.{Combustion, Damage}

  @doc "按内核完成时长结算，返回变更、剩余热源、热格、部件损伤和燃烧供热账。"
  def apply(targets, result, sources, config, done) do
    Enum.zip_reduce(targets, result, {[], %{}, [], %{}, 0.0}, fn {cell, target_cells, t,
                                                                  old_temperature, _electric,
                                                                  combustion},
                                                                 result,
                                                                 {changes, left, hot, losses,
                                                                  combustion_used} ->
      {temperature, hp, phase_energy} =
        case result do
          {temperature, hp, _remaining} -> {temperature, hp, nil}
          {temperature, hp, _remaining, energy} -> {temperature, hp, energy}
        end

      source = if t.granularity == 0, do: Map.get(sources, cell)
      remaining = if source, do: max(0.0, source.remaining_j - source.power_w * done), else: 0.0

      left =
        if t.granularity == 0 and Map.has_key?(sources, cell) and remaining > 1.0e-9,
          do: Map.put(left, cell, %{Map.fetch!(sources, cell) | remaining_j: remaining}),
          else: left

      {burned, energy, _used} =
        if combustion > 0 and Map.get(t, :burning, false),
          do: Combustion.step(t, done),
          else: {t, 0.0, 0.0}

      burned =
        if phase_energy == nil, do: burned, else: Map.put(burned, :phase_energy_j, phase_energy)

      burned = Damage.pick_baseline(burned, hp)

      hot =
        if abs(temperature - VoxelRegion.Thermal.ambient(config, cell)) > config["tolerance_kelvin"] or
             Map.get(burned, :burning, false), do: target_cells ++ hot, else: hot

      pool = if t.granularity == 4, do: {3, t.incarnation}, else: {2, t.owner}

      losses =
        if t.granularity in [1, 4] and hp < t.hp,
          do:
            Map.update(losses, pool, {t, t.hp - hp}, fn {row, loss} ->
              {row, loss + t.hp - hp}
            end),
          else: losses

      hp = if t.granularity in [1, 4], do: t.hp, else: hp

      if temperature == old_temperature and hp == t.hp and burned == t do
        {changes, left, hot, losses, combustion_used + energy}
      else
        t = burned |> Map.put(:temperature_kelvin, temperature) |> Map.put(:hp, hp)
        {[{Damage.key(t), t} | changes], left, hot, losses, combustion_used + energy}
      end
    end)
  end
end
