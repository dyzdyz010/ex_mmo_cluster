defmodule SceneServer.Voxel.Field.ElectricField do
  @moduledoc """
  Phase 6 局部场最小目标:BFS 电场 + ionization tick。

  每个 tick 的语义:
    1. 清空 AABB 内 `:electric_potential` layer。
    2. 从 source_points 出发,按 Dijkstra 风格(`gb_sets` 当 priority queue)
       向 6-邻居扩散。
    3. step_cost = `decay_factor / max(density / 65536.0, 0.001)`,
       density 取自 `Storage.effective_attribute_at(storage, cell, "density")`
       (Q16.16 raw int)。
    4. `:ionization` layer 在 `abs(electric_potential) >= threshold` 时累积,
       否则衰减;clamp 到 `0..255`。
  """

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @ionization_threshold 50.0
  @ionization_growth 5.0
  @ionization_decay 1.0
  @ionization_max 255.0
  @decay_factor 0.1
  @default_density_raw 65_536
  @min_density_float 0.001

  @doc """
  Runs a single tick of the electric field for the given region. Returns
  the updated region with `:electric_potential` and `:ionization` layers
  refreshed.
  """
  @spec tick(FieldRegion.t(), Storage.t() | nil) :: FieldRegion.t()
  def tick(%FieldRegion{} = region, storage) do
    aabb = region.aabb

    potential_layer =
      region
      |> FieldRegion.get_layer(:electric_potential)
      |> clear_layer_in_aabb(aabb)

    sources_in_aabb =
      region.source_points
      |> Enum.filter(fn sp ->
        sp.field_type == :electric_potential and FieldRegion.in_aabb?(region, Types.macro_coord!(sp.macro_index))
      end)

    source_map =
      Enum.reduce(sources_in_aabb, %{}, fn sp, acc ->
        val = sp.value * 1.0
        Map.update(acc, sp.macro_index, val, fn prev -> max(prev, val) end)
      end)

    initial_queue =
      Enum.reduce(source_map, :gb_sets.empty(), fn {idx, val}, acc ->
        # 使用 {-val, idx} 把 max-heap 模拟成 :gb_sets.take_smallest 的 min-heap。
        :gb_sets.add({-val, idx}, acc)
      end)

    final_visited = bfs_propagate(initial_queue, source_map, region, storage)

    potential_layer =
      Enum.reduce(final_visited, potential_layer, fn {idx, val}, layer ->
        FieldLayer.put(layer, idx, val)
      end)

    ionization_layer =
      region
      |> FieldRegion.get_layer(:ionization)
      |> update_ionization(potential_layer, aabb)

    region
    |> FieldRegion.put_layer(:electric_potential, potential_layer)
    |> FieldRegion.put_layer(:ionization, ionization_layer)
  end

  # ---- BFS / Dijkstra propagation -------------------------------------------

  defp bfs_propagate(queue, visited, region, storage) do
    case :gb_sets.is_empty(queue) do
      true ->
        visited

      false ->
        {{neg_potential, macro_index}, rest_queue} = :gb_sets.take_smallest(queue)
        current_potential = -neg_potential

        if Map.get(visited, macro_index, 0.0) > current_potential + 0.001 do
          # 已经找到了更好的路径,跳过这条 stale 入队记录。
          bfs_propagate(rest_queue, visited, region, storage)
        else
          coord = Types.macro_coord!(macro_index)

          {new_queue, new_visited} =
            Enum.reduce(neighbors_of(coord, region), {rest_queue, visited}, fn neighbor_coord,
                                                                                {q_acc, v_acc} ->
              neighbor_idx = Types.macro_index!(neighbor_coord)
              density_raw = read_density(storage, neighbor_idx)
              density_float = max(density_raw / 65_536.0, @min_density_float)
              step_cost = @decay_factor / density_float
              neighbor_potential = current_potential - step_cost

              if neighbor_potential > 0.0 and
                   neighbor_potential > Map.get(v_acc, neighbor_idx, 0.0) do
                q2 = :gb_sets.add({-neighbor_potential, neighbor_idx}, q_acc)
                v2 = Map.put(v_acc, neighbor_idx, neighbor_potential)
                {q2, v2}
              else
                {q_acc, v_acc}
              end
            end)

          bfs_propagate(new_queue, new_visited, region, storage)
        end
    end
  end

  defp neighbors_of({x, y, z}, region) do
    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
    |> Enum.filter(fn {nx, ny, nz} ->
      nx in 0..15 and ny in 0..15 and nz in 0..15 and
        FieldRegion.in_aabb?(region, {nx, ny, nz})
    end)
  end

  defp read_density(nil, _macro_index), do: @default_density_raw

  defp read_density(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at(storage, macro_index, "density")
  rescue
    _ -> @default_density_raw
  end

  defp read_density(_other, _macro_index), do: @default_density_raw

  # ---- helpers --------------------------------------------------------------

  defp clear_layer_in_aabb(layer, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    Enum.reduce(
      for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z}),
      layer,
      fn coord, acc ->
        idx = Types.macro_index!(coord)
        FieldLayer.put(acc, idx, 0.0)
      end
    )
  end

  defp update_ionization(ionization_layer, potential_layer, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    Enum.reduce(
      for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z}),
      ionization_layer,
      fn coord, acc ->
        idx = Types.macro_index!(coord)
        potential = FieldLayer.get(potential_layer, idx)
        current_ionization = FieldLayer.get(acc, idx)

        new_ionization =
          if abs(potential) >= @ionization_threshold do
            min(current_ionization + @ionization_growth, @ionization_max)
          else
            max(current_ionization - @ionization_decay, 0.0)
          end

        FieldLayer.put(acc, idx, new_ionization)
      end
    )
  end
end
