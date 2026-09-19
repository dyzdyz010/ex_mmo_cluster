defmodule VoxelRegion.ParameterEvolution do
  @moduledoc "全局系统功能：目录参数升级的兼容规则与热参考重标纯计算。"
  alias VoxelRegion.{Phase, Damage, Attachments}

  @doc "保留在用材料、工具、相变及数量语义，只允许参数发布契约声明的变化。"
  def compatible?(old, new) do
    material_fields =
      ~w(display_name tags heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin ignition_kelvin fuel_energy_per_macro_j burn_power_per_macro_w electrical_conductivity phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j)

    tool_fields =
      ~w(display_name interval_seconds fuel_units heat_energy_j heat_power_w cooling_energy_j circuit_energy_j)

    phase_fields =
      ~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j heat_capacity_per_macro max_hp_per_macro)

    old.attachments == new.attachments and old.liquid == new.liquid and
      Enum.all?(old.materials, fn {id, material} ->
        case Map.fetch(new.materials, id) do
          {:ok, next} ->
            Map.drop(material, material_fields) == Map.drop(next, material_fields) and
              (not Phase.enabled?(material) or
                 Map.take(material, phase_fields) == Map.take(next, phase_fields))

          :error ->
            false
        end
      end) and
      Enum.all?(old.tools, fn {id, tool} ->
        case Map.fetch(new.tools, id) do
          {:ok, next} -> Map.drop(tool, tool_fields) == Map.drop(next, tool_fields)
          :error -> false
        end
      end)
  end

  @doc "按实际属性行重标热参考；不供能、不改变温度、燃料、HP 或库存。"
  def thermal_reference(nil, _rows, _old, _catalog), do: nil

  def thermal_reference(thermal, rows, old_catalog, catalog) do
    ambient = thermal.config["ambient_kelvin"]

    rebase =
      Enum.reduce(rows, 0.0, fn {_, row}, sum ->
        old = old_catalog.materials[row.material]

        if row.granularity in [0, 1, 4] and Map.has_key?(row, :temperature_kelvin) and
             not Phase.enabled?(old) do
          volume =
            if row.granularity == 4,
              do: VoxelRegion.ThermalAttachments.volume(Attachments.slot(row), old_catalog),
              else: Damage.volume(row.granularity)

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
end
