defmodule SceneServer.Voxel.Field.TemperatureField do
  @moduledoc """
  Phase 6 局部场最小目标:7-stencil 温度场 tick。

  每个 tick:
    1. 温度层只保存相对环境温度的整数 delta;未保存 cell 视为 `@env_temp`。
    2. 只对当前异常 cell、热源 cell 及其 6-邻居 halo 计算扩散,避免把
       背景温度写满整个 chunk。
    3. `new_delta = current_delta + α * (neighbor_avg_delta - current_delta)`,
       α 由 `Storage.effective_attribute_at(storage, idx, "thermal_conductivity")`
       (Q16.16 raw int)调制,并 clamp 到 `@alpha_max` 以满足稳定性(简化的
       Courant 上限)。
    4. `new_delta = round(new_delta * (1 - β))`(向环境温度损耗);绝对值小于
       layer threshold 的 cell 自动退出 layer。
    5. tick 末把 `:temperature` 类型的 source_points 重新写回(热源持续)。
  """

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @base_alpha 0.1
  @alpha_max 0.5
  @beta 0.01
  @env_temp 20
  @default_tc_raw 6_554
  @default_tc_float @default_tc_raw / 65_536.0

  @doc """
  Runs one tick of the temperature field for the given region.
  """
  @spec tick(FieldRegion.t(), Storage.t() | nil) :: FieldRegion.t()
  def tick(%FieldRegion{} = region, storage) do
    layer = FieldRegion.get_layer(region, :temperature)
    candidate_indices = candidate_indices(layer, region)

    new_layer =
      Enum.reduce(candidate_indices, layer, fn idx, acc ->
        current_delta = FieldLayer.get_delta(layer, idx)
        neighbor_avg_delta = neighbor_avg_delta(layer, region, idx)

        tc_raw = read_thermal_conductivity(storage, idx)
        tc_float = tc_raw / 65_536.0
        alpha = min(@base_alpha * (tc_float / @default_tc_float), @alpha_max)

        new_delta =
          (current_delta + alpha * (neighbor_avg_delta - current_delta))
          |> Kernel.*(1.0 - @beta)
          |> round()

        FieldLayer.put_delta(acc, idx, new_delta)
      end)

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

  defp candidate_indices(layer, region) do
    active_indices =
      layer
      |> FieldLayer.active_cells(region.aabb, 0)
      |> Enum.map(&elem(&1, 0))

    source_indices =
      region.source_points
      |> Enum.filter(fn sp ->
        sp.field_type == :temperature and
          FieldRegion.in_aabb?(region, Types.macro_coord!(sp.macro_index))
      end)
      |> Enum.map(& &1.macro_index)

    (active_indices ++ source_indices)
    |> Enum.flat_map(fn idx -> [idx | neighbor_indices(region, idx)] end)
    |> Enum.uniq()
  end

  defp neighbor_avg_delta(layer, region, macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> neighbor_coords()
    |> Enum.map(fn coord ->
      if coord_in_region?(region, coord) do
        coord
        |> Types.macro_index!()
        |> then(&FieldLayer.get_delta(layer, &1))
      else
        0
      end
    end)
    |> Enum.sum()
    |> Kernel./(6.0)
  end

  defp neighbor_indices(region, macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> neighbor_coords()
    |> Enum.filter(&coord_in_region?(region, &1))
    |> Enum.map(&Types.macro_index!/1)
  end

  defp neighbor_coords({x, y, z}) do
    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
  end

  defp coord_in_region?(region, {x, y, z} = coord) do
    x in 0..15 and y in 0..15 and z in 0..15 and FieldRegion.in_aabb?(region, coord)
  end

  defp read_thermal_conductivity(nil, _macro_index), do: @default_tc_raw

  defp read_thermal_conductivity(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at(storage, macro_index, "thermal_conductivity")
  rescue
    _ -> @default_tc_raw
  end

  defp read_thermal_conductivity(_other, _macro_index), do: @default_tc_raw

  @doc "Returns the integer environment temperature used by the sparse delta layer."
  @spec env_temperature() :: integer()
  def env_temperature, do: @env_temp
end
