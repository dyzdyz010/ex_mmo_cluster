defmodule SceneServer.Voxel.Field.ElectricField do
  @moduledoc """
  Phase 6/7 局部场目标:material-aware 电势传播 + ionization tick。

  每个 tick 的语义:
    1. 清空 AABB 内 `:electric_potential` layer。
    2. 从 source_points 出发,只沿 `ParticipantProjection` 证明的导电材料/微格
       接触扩散。
    3. step cost 使用 `electric_conductivity` / `dielectric_strength` 与既有
       ionization 计算,不再走旧的 density fallback。
    4. `:ionization` layer 在 `abs(electric_potential) >= threshold` 时累积,
       否则衰减;clamp 到 `0..255`。
  """

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, NativeBackend, ParticipantProjection}
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @ionization_threshold 50.0
  @ionization_growth 5.0
  @ionization_decay 1.0
  @ionization_max 255.0
  @default_conductivity 0.0
  @default_dielectric_strength 3.0
  @min_conductivity 0.001
  @resistance_weight 4.0
  @breakdown_weight 0.25
  @ionization_bonus_weight 0.01
  @min_step_cost 0.05

  @doc """
  Runs a single tick of the electric field for the given region. Returns
  the updated region with `:electric_potential` and `:ionization` layers
  refreshed.
  """
  @spec tick(FieldRegion.t(), Storage.t() | nil) :: FieldRegion.t()
  @spec tick(FieldRegion.t(), Storage.t() | nil, keyword()) :: FieldRegion.t()
  def tick(%FieldRegion{} = region, storage, opts \\ []) do
    aabb = region.aabb

    potential_layer =
      region
      |> FieldRegion.get_layer(:electric_potential)
      |> FieldLayer.clear_in_aabb(aabb)

    ionization_layer = FieldRegion.get_layer(region, :ionization)
    projection = participant_projection(storage, opts)

    fallback = fn ->
      {:ok, elixir_propagation(region, projection, ionization_layer)}
    end

    {:ok, %{potential_cells: potential_cells, ionization_cells: ionization_cells}} =
      NativeBackend.propagate_electric_potential(
        region.source_points,
        aabb,
        ionization_layer,
        projection,
        backend: Keyword.get(opts, :electric_backend, :native),
        fallback: fallback
      )

    region
    |> FieldRegion.put_layer(:electric_potential, apply_cells(potential_layer, potential_cells))
    |> FieldRegion.put_layer(
      :ionization,
      ionization_layer
      |> FieldLayer.clear_in_aabb(aabb)
      |> apply_cells(ionization_cells)
    )
  end

  # ---- BFS / Dijkstra propagation -------------------------------------------

  defp elixir_propagation(region, projection, ionization_layer) do
    source_map =
      region.source_points
      |> source_map(region, projection)

    initial_queue =
      Enum.reduce(source_map, :gb_sets.empty(), fn {idx, val}, acc ->
        source_state = {idx, :source, MapSet.new()}
        :gb_sets.add({-val, source_state}, acc)
      end)

    visited =
      source_map
      |> Enum.map(fn {idx, val} -> {{idx, :source, MapSet.new()}, val} end)
      |> Map.new()

    final_visited = bfs_propagate(initial_queue, visited, region, projection, ionization_layer)
    potential_cells = best_potential_by_cell(final_visited)

    %{
      potential_cells:
        potential_cells
        |> Enum.filter(fn {_idx, val} -> val > 0.0 end)
        |> Enum.sort_by(&elem(&1, 0)),
      ionization_cells: ionization_cells(ionization_layer, potential_cells, region.aabb)
    }
  end

  defp source_map(source_points, region, projection) do
    source_points
    |> Enum.filter(fn sp ->
      sp.field_type == :electric_potential and
        FieldRegion.in_aabb?(region, Types.macro_coord!(sp.macro_index)) and
        ParticipantProjection.electric_conductive_cell?(projection, sp.macro_index)
    end)
    |> Enum.reduce(%{}, fn sp, acc ->
      val = sp.value * 1.0
      Map.update(acc, sp.macro_index, val, fn prev -> max(prev, val) end)
    end)
  end

  defp bfs_propagate(queue, visited, region, projection, ionization_layer) do
    case :gb_sets.is_empty(queue) do
      true ->
        visited

      false ->
        {{neg_potential, current_state}, rest_queue} = :gb_sets.take_smallest(queue)
        current_potential = -neg_potential

        if Map.get(visited, current_state, 0.0) > current_potential + 0.001 do
          bfs_propagate(rest_queue, visited, region, projection, ionization_layer)
        else
          {new_queue, new_visited} =
            Enum.reduce(
              neighbor_states(current_state, region, projection),
              {rest_queue, visited},
              fn {neighbor_idx, _entry_face, _entry_contacts} =
                   neighbor_state,
                 {q_acc, v_acc} ->
                step_cost =
                  step_cost(projection, ionization_layer, neighbor_idx, abs(current_potential))

                neighbor_potential = current_potential - step_cost

                if neighbor_potential > 0.0 and
                     neighbor_potential > Map.get(v_acc, neighbor_state, 0.0) do
                  q2 = :gb_sets.add({-neighbor_potential, neighbor_state}, q_acc)
                  v2 = Map.put(v_acc, neighbor_state, neighbor_potential)
                  {q2, v2}
                else
                  {q_acc, v_acc}
                end
              end
            )

          bfs_propagate(new_queue, new_visited, region, projection, ionization_layer)
        end
    end
  end

  defp neighbor_states({current_macro_index, entry_face, entry_contacts}, region, projection) do
    current_coord = Types.macro_coord!(current_macro_index)

    current_macro_index
    |> neighbor_indices(region)
    |> Enum.flat_map(fn neighbor_macro_index ->
      neighbor_coord = Types.macro_coord!(neighbor_macro_index)
      {exit_face, neighbor_entry_face} = shared_faces(current_coord, neighbor_coord)

      shared_contacts =
        ParticipantProjection.electric_contact_transfer(
          projection,
          current_macro_index,
          entry_face,
          entry_contacts,
          exit_face,
          projection,
          neighbor_macro_index,
          neighbor_entry_face
        )

      if MapSet.size(shared_contacts) > 0 do
        [{neighbor_macro_index, neighbor_entry_face, shared_contacts}]
      else
        []
      end
    end)
  end

  defp neighbor_indices(macro_index, region) do
    macro_index
    |> Types.macro_coord!()
    |> neighbors_of(region)
    |> Enum.map(&Types.macro_index!/1)
    |> Enum.sort()
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
    |> Enum.filter(fn {nx, ny, nz} = coord ->
      nx in 0..15 and ny in 0..15 and nz in 0..15 and FieldRegion.in_aabb?(region, coord)
    end)
  end

  defp shared_faces({x, y, z}, {nx, y, z}) when nx == x - 1, do: {:x_neg, :x_pos}
  defp shared_faces({x, y, z}, {nx, y, z}) when nx == x + 1, do: {:x_pos, :x_neg}
  defp shared_faces({x, y, z}, {x, ny, z}) when ny == y - 1, do: {:y_neg, :y_pos}
  defp shared_faces({x, y, z}, {x, ny, z}) when ny == y + 1, do: {:y_pos, :y_neg}
  defp shared_faces({x, y, z}, {x, y, nz}) when nz == z - 1, do: {:z_neg, :z_pos}
  defp shared_faces({x, y, z}, {x, y, nz}) when nz == z + 1, do: {:z_pos, :z_neg}

  defp step_cost(projection, ionization_layer, macro_index, source_strength) do
    conductivity =
      ParticipantProjection.electric_attribute(
        projection,
        macro_index,
        "electric_conductivity",
        @default_conductivity
      )

    dielectric_strength =
      ParticipantProjection.electric_attribute(
        projection,
        macro_index,
        "dielectric_strength",
        @default_dielectric_strength
      )

    resistance_cost = @resistance_weight / max(conductivity, @min_conductivity)
    breakdown_cost = breakdown_cost(dielectric_strength, source_strength)
    ionization_bonus = FieldLayer.get(ionization_layer, macro_index) * @ionization_bonus_weight

    max(@min_step_cost, 1.0 + resistance_cost + breakdown_cost - ionization_bonus)
  end

  defp breakdown_cost(dielectric_strength, source_strength) when source_strength > 0.0 do
    if source_strength >= dielectric_strength do
      @breakdown_weight * dielectric_strength / source_strength
    else
      @breakdown_weight * (dielectric_strength - source_strength) + dielectric_strength
    end
  end

  defp breakdown_cost(dielectric_strength, _source_strength), do: dielectric_strength

  defp best_potential_by_cell(visited) do
    Enum.reduce(visited, %{}, fn {{macro_index, _entry_face, _entry_contacts}, potential}, acc ->
      Map.update(acc, macro_index, potential, fn previous -> max(previous, potential) end)
    end)
  end

  # ---- helpers --------------------------------------------------------------

  defp participant_projection(storage, opts) do
    case Keyword.get(opts, :participant_projection) do
      %ParticipantProjection{} = projection -> projection
      _other -> participant_projection_from_storage(storage)
    end
  end

  defp participant_projection_from_storage(%Storage{} = storage),
    do: ParticipantProjection.build(storage)

  defp participant_projection_from_storage(_other), do: %ParticipantProjection{}

  defp apply_cells(%FieldLayer{} = layer, cells) do
    Enum.reduce(cells, layer, fn {idx, value}, acc ->
      FieldLayer.put(acc, idx, value)
    end)
  end

  defp ionization_cells(
         ionization_layer,
         potential_cells,
         {{min_x, min_y, min_z}, {max_x, max_y, max_z}}
       ) do
    Enum.flat_map(
      for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z}),
      fn coord ->
        idx = Types.macro_index!(coord)
        potential = Map.get(potential_cells, idx, 0.0)
        current_ionization = FieldLayer.get(ionization_layer, idx)

        new_ionization =
          if abs(potential) >= @ionization_threshold do
            min(current_ionization + @ionization_growth, @ionization_max)
          else
            max(current_ionization - @ionization_decay, 0.0)
          end

        if new_ionization > 0.0 do
          [{idx, new_ionization}]
        else
          []
        end
      end
    )
    |> Enum.sort_by(&elem(&1, 0))
  end
end
