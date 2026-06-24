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
          source_points: [FieldRegion.source_point()],
          # C4b:nil=普通双向导体;{in_face, out_face}=二极管(正/反偏由离电源跳数判,反偏剪断)。
          conduct_dir: nil | {ParticipantProjection.face(), ParticipantProjection.face()},
          # C4b:nil=非门控;%{base_face,threshold}=三极管(主通路通断由 base 控制网络门控)。
          gate: nil | %{base_face: ParticipantProjection.face(), threshold: float()}
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

    # C4b:每个二极管 segment 的 in/out 邻接 segment(按其 conduct_dir 的 in_face/out_face 面)。
    diode_neighbors = build_diode_neighbors(region, segments, adjacency, segments_by_macro)

    # C4b:每个三极管 segment 的 base 邻接 segment + 门限(base 面邻格 = 控制网络入口)。
    transistor_gates = build_transistor_gates(region, segments, segments_by_macro)

    all_segment_ids = Map.keys(segments)
    global_source_ids = global_source_segment_ids(segments)

    # C4b:**全局**门控——先剪反偏二极管,再门控三极管(base 控制网络常与主回路是不同连通分量,
    # 故 base 可达性必须在全图判,不能限在主回路分量内)。门控后再切连通分量 + 建分量结构,
    # 让被剪断的回路自然分裂、失去闭环。无二极管/三极管时 gated == 原图,零行为变化。
    gated_adjacency =
      adjacency
      |> cut_reverse_diodes(all_segment_ids, global_source_ids, diode_neighbors)
      |> gate_transistors(all_segment_ids, segments, transistor_gates)

    all_segment_ids
    |> connected_components(gated_adjacency)
    |> Enum.map(&build_component(&1, segments, gated_adjacency))
  end

  defp global_source_segment_ids(segments) do
    segments
    |> Enum.filter(fn {_id, segment} -> Map.get(segment, :source_points, []) != [] end)
    |> Enum.map(fn {id, _segment} -> id end)
  end

  @doc """
  Returns components whose closed-loop core contains both a power source and a load.

  This is the authoritative topology predicate for automatic circuits. Runtime
  lifecycle code uses it to decide whether a field region should exist at all,
  while `CircuitCurrentKernel` uses the same predicate to decide which loop
  cores receive current.
  """
  @spec active_circuit_components(FieldRegion.t(), ParticipantProjection.t()) :: [component()]
  def active_circuit_components(%FieldRegion{} = region, %ParticipantProjection{} = projection) do
    region
    |> analyze(projection)
    |> Enum.filter(&active_circuit_component?/1)
  end

  @doc "Returns true when the region contains at least one closed source-load circuit."
  @spec active_circuit?(FieldRegion.t(), ParticipantProjection.t()) :: boolean()
  def active_circuit?(%FieldRegion{} = region, %ParticipantProjection{} = projection) do
    active_circuit_components(region, projection) != []
  end

  @doc "Returns true when a component's closed-loop core contains source and load segments."
  @spec active_circuit_component?(component()) :: boolean()
  def active_circuit_component?(component) when is_map(component) do
    closed_loop_segment_ids = MapSet.new(component.closed_loop_segment_ids)

    component.closed_loop_segment_ids != [] and
      segment_sets_overlap?(component.source_segment_ids, closed_loop_segment_ids) and
      segment_sets_overlap?(component.load_segment_ids, closed_loop_segment_ids)
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
          source_points: maybe_component_source_points(source_points, roles),
          conduct_dir: Map.get(component, :conduct_dir, nil),
          gate: Map.get(component, :gate, nil)
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

  # adjacency 已是**全局门控后**的图(反偏二极管 / 关断三极管已剪)。本函数只在其上建分量结构。
  defp build_component(segment_ids, segments, adjacency) do
    segment_ids = Enum.sort(segment_ids)
    segment_map = Map.new(segment_ids, &{&1, Map.fetch!(segments, &1)})

    source_segment_ids =
      Enum.filter(segment_ids, fn segment_id ->
        segment_map |> Map.fetch!(segment_id) |> Map.get(:source_points, []) |> Kernel.!=([])
      end)

    load_segment_ids =
      Enum.filter(segment_ids, fn segment_id ->
        segment_map
        |> Map.fetch!(segment_id)
        |> Map.get(:roles, MapSet.new())
        |> MapSet.member?(:load)
      end)

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
      source_segment_ids: source_segment_ids,
      load_segment_ids: load_segment_ids,
      segments: segment_map,
      segment_graph: Map.take(adjacency, segment_ids),
      source_points: source_points
    }
  end

  # ── C4b 二极管有向化(hop-bias 剪断模型)─────────────────────────────────
  # 设计偏离:决策稿原拟"有向图 + SCC"判闭环,但实证该法对单回路无效——电源无极性,
  # 反偏二极管只会让电流绕另一圈,永不阻断。改用「离电源跳数」定向:二极管正偏 = 其
  # in_face(anode)侧比 out_face(cathode)侧更近电源(电流应离源流);反偏 = in 侧更远 →
  # 物理上电流要逆流过二极管 → **剪断该二极管**(从图删点),回路真断。无向图 + 剪点,
  # kernel 零改动。

  # 每个二极管 segment 的 in/out 邻接 segment(按 conduct_dir 的 in_face / out_face 面)。
  defp build_diode_neighbors(region, segments, adjacency, segments_by_macro) do
    segments
    |> Enum.filter(fn {_id, segment} -> segment.conduct_dir != nil end)
    |> Map.new(fn {segment_id, segment} ->
      {in_face, out_face} = segment.conduct_dir
      macro_coord = Types.macro_coord!(segment.macro_index)
      adj = Map.get(adjacency, segment_id, MapSet.new())

      {segment_id,
       %{
         in: neighbor_segments_on_face(macro_coord, in_face, region, segments_by_macro, adj),
         out: neighbor_segments_on_face(macro_coord, out_face, region, segments_by_macro, adj)
       }}
    end)
  end

  defp neighbor_segments_on_face(macro_coord, face, region, segments_by_macro, adj_set) do
    case neighbor_coord(macro_coord, face) do
      {:ok, coord} ->
        if FieldRegion.in_aabb?(region, coord) do
          neighbor_index = Types.macro_index!(coord)

          segments_by_macro
          |> Map.get(neighbor_index, [])
          |> MapSet.new()
          |> MapSet.intersection(adj_set)
        else
          MapSet.new()
        end

      :error ->
        MapSet.new()
    end
  end

  defp cut_reverse_diodes(adjacency, segment_ids, source_segment_ids, diode_neighbors) do
    diodes = Enum.filter(segment_ids, &Map.has_key?(diode_neighbors, &1))

    if diodes == [] do
      adjacency
    else
      allowed = MapSet.new(segment_ids)
      hops = bfs_hops(source_segment_ids, adjacency, allowed)

      reverse =
        Enum.filter(diodes, fn diode_id ->
          %{in: in_nbrs, out: out_nbrs} = Map.fetch!(diode_neighbors, diode_id)
          reverse_biased?(min_hop(in_nbrs, hops), min_hop(out_nbrs, hops))
        end)

      remove_segments(adjacency, reverse)
    end
  end

  # 反偏 = in 侧严格比 out 侧离电源远。任一侧无邻/无电源可达(nil)→ 不剪(交 2-core 剪悬挂)。
  defp reverse_biased?(nil, _out_hop), do: false
  defp reverse_biased?(_in_hop, nil), do: false
  defp reverse_biased?(in_hop, out_hop), do: in_hop > out_hop

  defp min_hop(segment_set, hops) do
    segment_set
    |> Enum.map(&Map.get(hops, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  # 删点:从图里去掉这些 segment 自身的邻接表项 + 把它们从所有其它点的邻居集里抹掉。
  defp remove_segments(adjacency, segment_ids) do
    drop = MapSet.new(segment_ids)

    adjacency
    |> Map.drop(segment_ids)
    |> Map.new(fn {id, neighbors} -> {id, MapSet.difference(neighbors, drop)} end)
  end

  # 无向 BFS 跳数(二极管视作可通,建立"离电源"梯度)。allowed 限定在本分量内。
  defp bfs_hops(source_segment_ids, adjacency, allowed) do
    queue =
      source_segment_ids
      |> Enum.filter(&MapSet.member?(allowed, &1))
      |> Enum.map(&{&1, 0})

    do_bfs_hops(queue, adjacency, allowed, %{})
  end

  defp do_bfs_hops([], _adjacency, _allowed, hops), do: hops

  defp do_bfs_hops([{segment_id, hop} | rest], adjacency, allowed, hops) do
    if Map.has_key?(hops, segment_id) do
      do_bfs_hops(rest, adjacency, allowed, hops)
    else
      neighbors =
        adjacency
        |> Map.get(segment_id, MapSet.new())
        |> MapSet.intersection(allowed)
        |> MapSet.to_list()
        |> Enum.map(&{&1, hop + 1})

      do_bfs_hops(rest ++ neighbors, adjacency, allowed, Map.put(hops, segment_id, hop))
    end
  end

  # ── C4b 三极管门控(base 可达性剪断模型)──────────────────────────────────
  # 三极管 main(collector-emitter)主通路仅当其 base 面邻格(控制网络入口)在图中可从一个
  # 电压 ≥ 本管 base_threshold 的电源到达时导通;否则**剪断该三极管点**,主回路断。base 面不入
  # 导电图(传感输入,与 main 隔离),故 base 邻格可达性 = 控制网络是否被驱动。串联=AND、并联=OR。
  # 迭代到稳定:剪掉一个三极管只会让可达集单调缩小(更多管关断),故有界(管数 + 1 轮)收敛。

  # 每个三极管 segment 的 base 邻接 segment(base 面那一格的全部 segment)+ 门限。
  defp build_transistor_gates(region, segments, segments_by_macro) do
    segments
    |> Enum.filter(fn {_id, segment} -> segment.gate != nil end)
    |> Map.new(fn {segment_id, segment} ->
      %{base_face: base_face, threshold: threshold} = segment.gate
      macro_coord = Types.macro_coord!(segment.macro_index)

      {segment_id,
       %{
         base: neighbor_segments_on_face_all(macro_coord, base_face, region, segments_by_macro),
         threshold: threshold
       }}
    end)
  end

  # base 面那一格的全部 segment(不交 adjacency:base 非导电面,本就不在导电邻接里)。
  defp neighbor_segments_on_face_all(macro_coord, face, region, segments_by_macro) do
    case neighbor_coord(macro_coord, face) do
      {:ok, coord} ->
        if FieldRegion.in_aabb?(region, coord) do
          neighbor_index = Types.macro_index!(coord)
          segments_by_macro |> Map.get(neighbor_index, []) |> MapSet.new()
        else
          MapSet.new()
        end

      :error ->
        MapSet.new()
    end
  end

  defp gate_transistors(adjacency, segment_ids, segment_map, transistor_gates) do
    component_transistors = Enum.filter(segment_ids, &Map.has_key?(transistor_gates, &1))

    if component_transistors == [] do
      adjacency
    else
      allowed = MapSet.new(segment_ids)

      do_gate_transistors(
        adjacency,
        component_transistors,
        segment_map,
        transistor_gates,
        allowed,
        length(component_transistors) + 1
      )
    end
  end

  defp do_gate_transistors(adjacency, transistors, segment_map, gates, allowed, iterations_left) do
    off =
      Enum.filter(transistors, fn transistor_id ->
        %{base: base_nbrs, threshold: threshold} = Map.fetch!(gates, transistor_id)
        not transistor_on?(adjacency, segment_map, allowed, base_nbrs, threshold)
      end)

    cond do
      off == [] ->
        adjacency

      iterations_left <= 0 ->
        remove_segments(adjacency, off)

      true ->
        # 关断的管剪掉、留下还在的管对新图复评(关断只会让可达集缩小,单调收敛)。
        new_adjacency = remove_segments(adjacency, off)
        remaining = transistors -- off

        do_gate_transistors(
          new_adjacency,
          remaining,
          segment_map,
          gates,
          allowed,
          iterations_left - 1
        )
    end
  end

  defp transistor_on?(adjacency, segment_map, allowed, base_nbrs, threshold) do
    sources = qualifying_source_segments(segment_map, allowed, threshold)
    reachable = reachable_from(sources, adjacency, allowed)

    base_nbrs
    |> MapSet.intersection(reachable)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  # 电压 ≥ threshold 的电源 segment(限本分量内 allowed)。
  defp qualifying_source_segments(segment_map, allowed, threshold) do
    allowed
    |> Enum.filter(fn id ->
      case Map.get(segment_map, id) do
        %{} = segment -> source_segment_voltage(segment) >= threshold
        _other -> false
      end
    end)
    |> MapSet.new()
  end

  defp source_segment_voltage(segment) do
    segment
    |> Map.get(:source_points, [])
    |> Enum.map(&abs(&1.value * 1.0))
    |> Enum.max(fn -> 0.0 end)
  end

  # 从给定 source segment 集在(无向)图上可达的 segment 集,限 allowed。
  defp reachable_from(sources, adjacency, allowed) do
    do_reach(MapSet.to_list(sources), adjacency, allowed, MapSet.new())
  end

  defp do_reach([], _adjacency, _allowed, seen), do: seen

  defp do_reach([segment_id | rest], adjacency, allowed, seen) do
    if MapSet.member?(seen, segment_id) or not MapSet.member?(allowed, segment_id) do
      do_reach(rest, adjacency, allowed, seen)
    else
      neighbors =
        adjacency
        |> Map.get(segment_id, MapSet.new())
        |> MapSet.intersection(allowed)
        |> MapSet.to_list()

      do_reach(rest ++ neighbors, adjacency, allowed, MapSet.put(seen, segment_id))
    end
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

  defp segment_sets_overlap?(segment_ids, loop_segment_ids) do
    segment_ids
    |> MapSet.new()
    |> MapSet.intersection(loop_segment_ids)
    |> MapSet.size()
    |> Kernel.>(0)
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
