defmodule SceneServer.Voxel.Field.TemperatureField do
  @moduledoc """
  Phase 6 局部场最小目标:7-stencil 温度场 tick。

  每个 tick:
    1. 对 AABB 内每个 cell 计算 6-邻居均值(AABB 外的邻居视为 `@env_temp`)。
    2. `new = current + α * (neighbor_avg - current)`,
       α 由 `Storage.effective_attribute_at(storage, idx, "thermal_conductivity")`
       (Q16.16 raw int)调制,并 clamp 到 `@alpha_max` 以满足稳定性(简化的
       Courant 上限)。
    3. `new = new + β * (env_temp - new)`(向环境温度衰减)。
    4. tick 末把 `:temperature` 类型的 source_points 重新写回(热源持续)。
  """

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @base_alpha 0.1
  @alpha_max 0.5
  @beta 0.01
  @env_temp 20.0
  @default_tc_raw 6_554
  @default_tc_float @default_tc_raw / 65_536.0

  @doc """
  Runs one tick of the temperature field for the given region.
  """
  @spec tick(FieldRegion.t(), Storage.t() | nil) :: FieldRegion.t()
  def tick(%FieldRegion{} = region, storage) do
    layer = FieldRegion.get_layer(region, :temperature)
    {{min_x, min_y, min_z}, {max_x, max_y, max_z}} = region.aabb

    new_layer =
      Enum.reduce(
        for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z}),
        layer,
        fn {x, y, z} = coord, acc ->
          idx = Types.macro_index!(coord)
          current_temp = FieldLayer.get(layer, idx)

          neighbors = [
            read_temp_or_env(layer, region, {x - 1, y, z}),
            read_temp_or_env(layer, region, {x + 1, y, z}),
            read_temp_or_env(layer, region, {x, y - 1, z}),
            read_temp_or_env(layer, region, {x, y + 1, z}),
            read_temp_or_env(layer, region, {x, y, z - 1}),
            read_temp_or_env(layer, region, {x, y, z + 1})
          ]

          neighbor_avg = Enum.sum(neighbors) / 6.0

          tc_raw = read_thermal_conductivity(storage, idx)
          tc_float = tc_raw / 65_536.0
          alpha = min(@base_alpha * (tc_float / @default_tc_float), @alpha_max)

          new_temp = current_temp + alpha * (neighbor_avg - current_temp)
          new_temp = new_temp + @beta * (@env_temp - new_temp)

          FieldLayer.put(acc, idx, new_temp)
        end
      )

    # 热源点(temperature)在每 tick 末重写,保证热源持续。
    new_layer =
      Enum.reduce(region.source_points, new_layer, fn sp, acc ->
        if sp.field_type == :temperature do
          coord = Types.macro_coord!(sp.macro_index)

          if FieldRegion.in_aabb?(region, coord) do
            FieldLayer.put(acc, sp.macro_index, sp.value * 1.0)
          else
            acc
          end
        else
          acc
        end
      end)

    FieldRegion.put_layer(region, :temperature, new_layer)
  end

  # ---- helpers --------------------------------------------------------------

  defp read_temp_or_env(layer, region, coord) do
    {x, y, z} = coord

    if x in 0..15 and y in 0..15 and z in 0..15 and FieldRegion.in_aabb?(region, coord) do
      FieldLayer.get(layer, Types.macro_index!(coord))
    else
      @env_temp
    end
  end

  defp read_thermal_conductivity(nil, _macro_index), do: @default_tc_raw

  defp read_thermal_conductivity(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at(storage, macro_index, "thermal_conductivity")
  rescue
    _ -> @default_tc_raw
  end

  defp read_thermal_conductivity(_other, _macro_index), do: @default_tc_raw

  @doc "Returns the constant environment temperature used by the diffuse → env decay step."
  @spec env_temperature() :: float()
  def env_temperature, do: @env_temp
end
