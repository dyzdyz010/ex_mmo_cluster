defmodule SceneServer.Voxel.Field.CircuitComponentAnalysis do
  @moduledoc """
  Pure chunk-local conductive component analysis for automatic circuit kernels.

  This module turns `ParticipantProjection` facts into connected conductive
  segment graphs without reaching back into prefab/material catalogs. Each
  segment is one projection-frozen conductive subcomponent inside a macro cell,
  and component connectivity is derived only from shared-face contact overlap.
  """

  alias SceneServer.Voxel.Field.{FieldRegion, ParticipantProjection}
  alias SceneServer.Voxel.Types

  @type segment_id :: {0..4095, non_neg_integer()}
  @type segment :: %{
          id: segment_id(),
          macro_index: 0..4095,
          roles: MapSet.t(ParticipantProjection.electric_role()),
          faces: MapSet.t(ParticipantProjection.face()),
          face_contacts: %{
            optional(ParticipantProjection.face()) => MapSet.t(ParticipantProjection.contact())
          },
          source_points: [FieldRegion.source_point()]
        }
  @type component :: %{
          segment_ids: [segment_id()],
          closed_loop_segment_ids: [segment_id()],
          macro_indices: [0..4095],
          closed_loop_macro_indices: [0..4095],
          source_macro_indices: [0..4095],
          load_macro_indices: [0..4095],
          source_segment_ids: [segment_id()],
          load_segment_ids: [segment_id()],
          segments: %{optional(segment_id()) => segment()},
          segment_graph: %{optional(segment_id()) => MapSet.t(segment_id())},
          source_points: [FieldRegion.source_point()]
        }

  @doc "Builds conductive connected components for the region AABB."
  @spec analyze(FieldRegion.t(), ParticipantProjection.t()) :: [component()]
  def analyze(%FieldRegion{} = region, %ParticipantProjection{} = projection) do
    segments = build_segments(region, projection)
    segments_by_macro = group_segments_by_macro(segments)
    adjacency = build_adjacency(region, segments, segments_by_macro)

    segments
    |> Map.keys()
    |> connected_components(adjacency)
    |> Enum.map(&build_component(&1, segments, adjacency))
  end

  defp build_segments(region, projection) do
    region
    |> aabb_macro_indices()
    |> Enum.reduce(%{}, fn macro_index, acc ->
      source_points = source_points_for(region, macro_index)

      projection
      |> ParticipantProjection.electric_components(macro_index)
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {component, component_index}, inner_acc ->
        roles = Map.get(component, :roles, MapSet.new())

        segment = %{
          id: {macro_index, component_index},
          macro_index: macro_index,
          roles: roles,
          faces: component.faces,
          face_contacts: component.face_contacts,
          source_points: maybe_component_source_points(source_points, roles)
        }

        Map.put(inner_acc, segment.id, segment)
      end)
    end)
  end

  defp maybe_component_source_points(source_points, roles) do
    if MapSet.member?(roles, :source), do: source_points, else: []
  end

  defp group_segments_by_macro(segments) do
    Enum.reduce(segments, %{}, fn {segment_id, %{macro_index: macro_index}}, acc ->
      Map.update(acc, macro_index, [segment_id], &[segment_id | &1])
    end)
  end

  defp build_adjacency(region, segments, segments_by_macro) do
    initial = Map.new(segments, fn {segment_id, _segment} -> {segment_id, MapSet.new()} end)

    Enum.reduce(segments, initial, fn {segment_id, segment}, acc ->
      Enum.reduce(segment.faces, acc, fn face, face_acc ->
        connect_face_neighbors(
          region,
          segments,
          segments_by_macro,
          segment_id,
          segment,
          face,
          face_acc
        )
      end)
    end)
  end

  defp connect_face_neighbors(region, segments, segments_by_macro, segment_id, segment, face, acc) do
    macro_coord = Types.macro_coord!(segment.macro_index)

    case neighbor_coord(macro_coord, face) do
      {:ok, coord} ->
        if FieldRegion.in_aabb?(region, coord) do
          neighbor_index = Types.macro_index!(coord)
          neighbor_face = opposite_face(face)
          contacts = Map.get(segment.face_contacts, face, MapSet.new())

          Enum.reduce(Map.get(segments_by_macro, neighbor_index, []), acc, fn neighbor_id,
                                                                              inner_acc ->
            neighbor_segment = Map.fetch!(segments, neighbor_id)

            neighbor_contacts =
              Map.get(neighbor_segment.face_contacts, neighbor_face, MapSet.new())

            if contacts_overlap?(contacts, neighbor_contacts) do
              inner_acc
              |> Map.update!(segment_id, &MapSet.put(&1, neighbor_id))
              |> Map.update!(neighbor_id, &MapSet.put(&1, segment_id))
            else
              inner_acc
            end
          end)
        else
          acc
        end

      :error ->
        acc
    end
  end

  defp connected_components(segment_ids, adjacency) do
    do_connected_components(segment_ids, adjacency, MapSet.new(), [])
  end

  defp do_connected_components([], _adjacency, _visited, acc), do: Enum.reverse(acc)

  defp do_connected_components([segment_id | rest], adjacency, visited, acc) do
    if MapSet.member?(visited, segment_id) do
      do_connected_components(rest, adjacency, visited, acc)
    else
      {component_ids, visited} = collect_component([segment_id], adjacency, visited, MapSet.new())
      do_connected_components(rest, adjacency, visited, [MapSet.to_list(component_ids) | acc])
    end
  end

  defp collect_component([], _adjacency, visited, component_ids), do: {component_ids, visited}

  defp collect_component([segment_id | queue], adjacency, visited, component_ids) do
    if MapSet.member?(visited, segment_id) do
      collect_component(queue, adjacency, visited, component_ids)
    else
      neighbors = adjacency |> Map.get(segment_id, MapSet.new()) |> MapSet.to_list()

      collect_component(
        queue ++ neighbors,
        adjacency,
        MapSet.put(visited, segment_id),
        MapSet.put(component_ids, segment_id)
      )
    end
  end

  defp build_component(segment_ids, segments, adjacency) do
    segment_ids = Enum.sort(segment_ids)
    segment_map = Map.new(segment_ids, &{&1, Map.fetch!(segments, &1)})
    closed_loop_segment_ids = closed_loop_segment_ids(segment_ids, adjacency)

    macro_indices =
      segment_map |> Map.values() |> Enum.map(& &1.macro_index) |> Enum.uniq() |> Enum.sort()

    closed_loop_macro_indices =
      closed_loop_segment_ids
      |> Enum.map(fn segment_id -> Map.fetch!(segment_map, segment_id).macro_index end)
      |> Enum.uniq()
      |> Enum.sort()

    source_points =
      segment_map |> Map.values() |> Enum.flat_map(& &1.source_points) |> Enum.uniq()

    %{
      segment_ids: segment_ids,
      closed_loop_segment_ids: closed_loop_segment_ids,
      macro_indices: macro_indices,
      closed_loop_macro_indices: closed_loop_macro_indices,
      source_macro_indices:
        source_points |> Enum.map(& &1.macro_index) |> Enum.uniq() |> Enum.sort(),
      load_macro_indices:
        segment_map
        |> Map.values()
        |> Enum.filter(&MapSet.member?(&1.roles, :load))
        |> Enum.map(& &1.macro_index)
        |> Enum.uniq()
        |> Enum.sort(),
      source_segment_ids:
        segment_ids
        |> Enum.filter(fn segment_id ->
          segment_map
          |> Map.fetch!(segment_id)
          |> Map.get(:source_points, [])
          |> Kernel.!=([])
        end),
      load_segment_ids:
        segment_ids
        |> Enum.filter(fn segment_id ->
          segment_map
          |> Map.fetch!(segment_id)
          |> Map.get(:roles, MapSet.new())
          |> MapSet.member?(:load)
        end),
      segments: segment_map,
      segment_graph: Map.take(adjacency, segment_ids),
      source_points: source_points
    }
  end

  # The automatic circuit kernel needs actual closed loops, not just any
  # source-to-load path. The graph 2-core is the stable topology boundary:
  # repeatedly pruning degree-0/1 leaves removes open-ended branches and leaves
  # exactly the conductive segments that can participate in a closed cycle.
  defp closed_loop_segment_ids(segment_ids, adjacency) do
    segment_ids
    |> MapSet.new()
    |> prune_open_ends(adjacency)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp prune_open_ends(remaining, adjacency) do
    leaves =
      remaining
      |> Enum.filter(&(degree_in_remaining(&1, remaining, adjacency) <= 1))
      |> MapSet.new()

    if MapSet.size(leaves) == 0 do
      remaining
    else
      remaining
      |> MapSet.difference(leaves)
      |> prune_open_ends(adjacency)
    end
  end

  defp degree_in_remaining(segment_id, remaining, adjacency) do
    adjacency
    |> Map.get(segment_id, MapSet.new())
    |> MapSet.intersection(remaining)
    |> MapSet.size()
  end

  defp source_points_for(region, macro_index) do
    Enum.filter(region.source_points, fn source_point ->
      source_point.field_type == :electric_potential and source_point.macro_index == macro_index
    end)
  end

  defp aabb_macro_indices(%FieldRegion{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}}) do
    for x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z do
      Types.macro_index!({x, y, z})
    end
  end

  defp neighbor_coord({x, y, z}, :x_neg) when x > 0, do: {:ok, {x - 1, y, z}}
  defp neighbor_coord({x, y, z}, :x_pos) when x < 15, do: {:ok, {x + 1, y, z}}
  defp neighbor_coord({x, y, z}, :y_neg) when y > 0, do: {:ok, {x, y - 1, z}}
  defp neighbor_coord({x, y, z}, :y_pos) when y < 15, do: {:ok, {x, y + 1, z}}
  defp neighbor_coord({x, y, z}, :z_neg) when z > 0, do: {:ok, {x, y, z - 1}}
  defp neighbor_coord({x, y, z}, :z_pos) when z < 15, do: {:ok, {x, y, z + 1}}
  defp neighbor_coord(_coord, _face), do: :error

  defp opposite_face(:x_neg), do: :x_pos
  defp opposite_face(:x_pos), do: :x_neg
  defp opposite_face(:y_neg), do: :y_pos
  defp opposite_face(:y_pos), do: :y_neg
  defp opposite_face(:z_neg), do: :z_pos
  defp opposite_face(:z_pos), do: :z_neg

  defp contacts_overlap?(contacts, neighbor_contacts) do
    contacts
    |> MapSet.intersection(neighbor_contacts)
    |> MapSet.size()
    |> Kernel.>(0)
  end
end
