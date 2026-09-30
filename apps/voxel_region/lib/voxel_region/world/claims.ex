defmodule VoxelRegion.World.Claims do
  @moduledoc """
  全局系统功能：受保护区域：意图许可的受影响格、玩家认领与提交。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.Attachments
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Protection
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Observation, Log, Liquids}

  # ---- 受保护区域：意图许可的受影响格、玩家认领适配、提交

  # 工具意图作用的全部宏格：宏格本身、叶子构件的全部占用格、附件整件的足迹。
  def target_cells(state, %{granularity: 3} = t),
    do: Attachments.macros(attachment_slots(state, t.incarnation))
  def target_cells(state, %{granularity: 2} = t), do: micro_owner_cells(state, MapSet.new([t.owner]))
  def target_cells(_state, t), do: [Damage.macro(t)]

  # 附件放置的足迹必须落在同一持有者内（不跨区域边界）；拆除只看现有整件足迹。
  def attachment_protection(state, actor, r) do
    holder = {:character, actor.cid}
    cells =
      if r.action == 0,
        do: Attachments.macros(Attachments.footprint(r.kind, r.axis, r.anchor, r.size)),
        else: Attachments.macros(attachment_slots(state, r.id))
    single = r.action != 0 or Protection.empty?(state.protection) or
      length(Enum.uniq_by(cells, &Protection.holder(state.protection, &1))) <= 1

    if single and Protection.permitted?(state.protection, holder, cells),
      do: :ok,
      else: {:error, :protected_region}
  end

  # 玩家适配（认领工具）：第一次点地面记第一角；第二次点记对角并建区域（再点第一角同一格 = 取消）；
  # 无待定角时点自己区域内的格 = 释放该区域。每次点击都经工具射线的射程与遮挡裁决。
  # 上限（数量、面积）来自工具目录行；拒绝：:region_too_large / :region_limit / :region_overlap / :region_occupied。
  def claim_region(_before, state, actor, request, target, tool) do
    holder = {:character, actor.cid}
    cell = Damage.macro(target)
    pending = Map.get(state.claim_corners, actor.player)
    p = state.protection
    corners = Map.delete(state.claim_corners, actor.player)

    cond do
      request.action != 1 ->
        {:reply, {:error, :invalid_protection_operation}, state}

      pending == cell ->
        {:reply, {:ok, state.seq}, %{state | claim_corners: corners}}

      pending != nil ->
        {x0, _, z0} = pending
        {x1, _, z1} = cell
        min = {min(x0, x1), min(z0, z1)}
        max = {max(x0, x1), max(z0, z1)}
        region = %{holder: holder, min: min, max: max, created_seq: state.seq + 1, created_by: actor.cid}
        state = %{state | claim_corners: corners}

        cond do
          Protection.area(region) > tool["region_max_area_m2"] -> {:reply, {:error, :region_too_large}, state}
          length(Protection.held(p, holder)) >= tool["region_max_count"] -> {:reply, {:error, :region_limit}, state}
          Protection.overlaps?(p, min, max) -> {:reply, {:error, :region_overlap}, state}
          region_occupied?(state, region, actor.cid) -> {:reply, {:error, :region_occupied}, state}
          true -> commit_protection(state, state, %{{state.seq + 1, 1} => region})
        end

      match?({_, %{holder: ^holder}}, Protection.region_at(p, cell)) ->
        {id, _} = Protection.region_at(p, cell)
        commit_protection(state, %{state | claim_corners: corners}, %{id => nil})

      Protection.holder(p, cell) != nil ->
        {:reply, {:error, :region_overlap}, state}

      true ->
        {:reply, {:ok, state.seq}, %{state | claim_corners: Map.put(state.claim_corners, actor.player, cell)}}
    end
  end

  # 矩形内有别的角色花材料放下的格或他人建造的 Prefab 实例时不能认领；作者格与天然地形不算占用。
  def region_occupied?(state, region, cid) do
    inside = &Protection.contains?(region, &1)
    foreign = &(&1 != nil and &1 != cid)
    placer = fn id -> state.instances |> Map.get(id, %{}) |> Map.get(:placed_by) end

    Enum.any?(state.placed_by, fn {cell, by} -> foreign.(by) and inside.(cell) end) or
      Enum.any?(state.macro_owners, fn {cell, id} -> inside.(cell) and foreign.(placer.(id)) end) or
      Enum.any?(state.refined, fn {cell, slots} ->
        inside.(cell) and Enum.any?(slots, fn {_, {_, id}} -> foreign.(placer.(id)) end)
      end)
  end

  # 区域增量独立成一笔事务；边界改变后热工作集（接触图、视线缓存）整体重建，边界两侧液体重新唤醒。
  def commit_protection(before, state, delta) do
    next = %{state | seq: state.seq + 1, protection: Protection.apply(state.protection, delta)}
    rects = for {id, r} <- delta, r = r || before.protection.regions[id], do: r
    wet = for {cell, _} <- next.liquid_units, Enum.any?(rects, &Protection.contains?(&1, cell, 1)), do: cell
    next = next |> Thermal.rebuild_work() |> Liquids.wake_liquid(wet)
    txn = %{seq: next.seq, entries: [], coarse: [], protection: delta}

    case Log.append_log(next, txn) do
      :ok ->
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)
        Logger.info("voxel_protection seq=#{next.seq} changes=#{inspect(delta)} regions=#{map_size(next.protection.regions)}")
        {:reply, {:ok, next.seq}, Liquids.schedule_liquid(next)}

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end
end
