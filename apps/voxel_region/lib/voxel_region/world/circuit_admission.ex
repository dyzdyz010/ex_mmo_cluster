defmodule VoxelRegion.World.CircuitAdmission do
  @moduledoc """
  玩家新增潜在连接的提交前接纳。空间图只由CircuitGraph构造；宏格、微格按显式人工来源各计1，
  附件按整件（同一出生ID的全部槽，无论面或线占多少槽）计1（用户2026-10-29决定）。
  候选图不持久，不决定已有过程是否运行；天然导体只提供连通，不计数量，也不推断未记录的加工因果。
  """
  require Logger
  alias VoxelRegion.{Attachments, Circuit, Prefab, RefinedSlots, ThermalGeometry}
  alias VoxelRegion.World.{Canonical, CircuitGraph, Edits}

  @default_limit 27

  @doc "World构造时一次接纳有限人工单元上限；缺省来自本模块实测默认值。"
  def configure(opts) do
    limit = Keyword.get(opts, :circuit_component_limit,
      Application.get_env(:voxel_region, :circuit_component_limit, @default_limit))
    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "circuit_component_limit must be a positive integer")
    limit
  end

  @doc "普通玩家单宏格建造的同一候选占用视图；只裁决新不变量，不提交或扣账。"
  def macro(before, state, cell, material, cid, limit) do
    candidate = Edits.put_overlay(state, 0, cell, {material, MmoContracts.Voxel.Skins.uniform(material)})
    candidate = %{candidate | placed_by: Canonical.chunk_put(candidate.placed_by, cell, cid)}
    case check(before, candidate, [cell], [], limit) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "已构造候选的新增潜在单元逐分量裁决；缺页沿原请求defer，不能把部分图当作成功。"
  def check(before, state, cells, slots, limit) do
    {seeds, state} = new_seeds(before, state, cells, slots)
    case components(state, seeds, MapSet.new(), MapSet.new(), limit, 0, MapSet.new()) do
      {:ok, state, maximum, pages} ->
        if seeds != [] do
          Logger.info("voxel_circuit_admission status=accepted seq=#{before.seq} artificial_units=#{maximum} limit=#{limit} read_pages=#{MapSet.size(pages)}")
        end
        {:ok, state}
      {:limit, count, pages} ->
        Logger.warning("voxel_circuit_admission status=rejected reason=circuit_component_limit seq=#{before.seq} artificial_units=#{count} limit=#{limit} read_pages=#{MapSet.size(pages)}")
        {:error, :circuit_component_limit}
      {:pages, keys} ->
        Logger.info("voxel_circuit_admission status=page_io seq=#{before.seq} required_pages=#{length(keys)}")
        {:error, {:pages_missing, keys}}
    end
  end

  @doc "完整潜在分量的人工量；直接读取已接纳来源，旧存档缺来源不能猜作人工。附件槽值`{出生ID, 材料}`按出生ID去重。"
  def artificial_units(state, graph) do
    # 出生ID是整件附件的权威身份（拆除、整件HP与Prefab分组均按它），同一件被裁成多段仍是同一件。
    attachments = graph.slots |> Map.values() |> MapSet.new(&elem(&1, 0)) |> MapSet.size()
    attachments + Enum.count(graph.solids, fn
      {0, micro} -> Canonical.chunk_get(state.placed_by, elem(Prefab.macro_slot(micro), 0)) != nil
      {1, micro} ->
        {cell, slot} = Prefab.macro_slot(micro)
        {:ok, {_material, owner}} = RefinedSlots.fetch(Map.fetch!(state.refined, cell), slot)
        case Map.get(state.instances, owner) do
          nil -> false
          instance -> Map.get(instance, :placed_by) != nil
        end
    end)
  end

  defp components(state, [], _solids, _slots, _limit, maximum, pages),
    do: {:ok, state, maximum, pages}
  defp components(state, [seed | rest], solids, slots, limit, maximum, pages) do
    seen = case seed do
      {:solid, target} -> MapSet.member?(solids, ThermalGeometry.key(Circuit.thermal_target(target)))
      {:slot, slot} -> MapSet.member?(slots, slot)
    end
    if seen do
      components(state, rest, solids, slots, limit, maximum, pages)
    else
      case CircuitGraph.advance(state, CircuitGraph.potential(state.seq, seed, state.protection)) do
        {:needs_pages, _missing, graph, _state} ->
          # 已读页与新缺页共同成为该原输入的依赖，避免defer时退休前段后反复走回头路。
          {:pages, CircuitGraph.dependencies(%{graph | keys: MapSet.union(pages, graph.keys)})}
        {:ready, graph, state} ->
          count = artificial_units(state, graph)
          pages = MapSet.union(pages, graph.keys)
          if count > limit do
            {:limit, count, pages}
          else
            components(state, rest, MapSet.union(solids, graph.solids),
              Enum.into(Map.keys(graph.slots), slots), limit, max(maximum, count), pages)
          end
      end
    end
  end

  defp new_seeds(before, state, cells, slots) do
    {solids, _before, state} = Enum.reduce(Enum.uniq(cells), {[], before, state}, fn cell, {seeds, old, current} ->
      points = case Map.fetch(current.refined, cell) do
        {:ok, refined} -> Enum.map(refined, fn {slot, _} -> Prefab.micro_coord(cell, slot) end)
        :error -> [Prefab.micro_coord(cell, 0)]
      end
      Enum.reduce(points, {seeds, old, current}, fn point, {seeds, old, current} ->
        {target, current} = Canonical.target_at(point, current)
        if conducting?(current, target) do
          {previous, old} = Canonical.target_at(point, old)
          seeds = if same_connections?(old, previous, current, target), do: seeds, else: [{:solid, target} | seeds]
          {seeds, old, current}
        else
          {seeds, old, current}
        end
      end)
    end)
    attachments = for slot <- Enum.uniq(slots), {:ok, value} <- [Map.fetch(state.attachments, slot)],
      conducting?(state, Attachments.identity(slot, value)),
      not old_slot_conducting?(before, slot), do: {:slot, slot}
    {Enum.reverse(solids) ++ attachments, state}
  end

  defp old_slot_conducting?(before, slot) do
    case Map.fetch(before.attachments, slot) do
      {:ok, value} -> conducting?(before, Attachments.identity(slot, value))
      :error -> false
    end
  end
  defp conducting?(_state, nil), do: false
  defp conducting?(state, target), do: Circuit.sigma(state.properties, nil, nil, target, :potential) > 0

  # identity、closed与温度不是潜在拓扑；普通导体换成蓄能石只收缩接触，反向替换会新增侧面。
  defp same_connections?(before, old, state, target) do
    conducting?(before, old) and
      ThermalGeometry.key(Circuit.thermal_target(old)) == ThermalGeometry.key(Circuit.thermal_target(target)) and
      not (Circuit.battery?(before.properties.materials[old.material]) and
        not Circuit.battery?(state.properties.materials[target.material]))
  end
end
