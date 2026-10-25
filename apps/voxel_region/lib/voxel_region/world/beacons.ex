defmodule VoxelRegion.World.Beacons do
  @moduledoc """
  全局系统功能：传送信标（Voxim `Docs/Gameplay/Beacon.md`）。

  - **信标记录** `state.beacons`（id => `%{id, name, core, landing}`）是唯一真值，随日志／检查点持久化：
    `core` 为核心内一个微格坐标（1/8 m），`landing` 为落点探针（canonical 米，Y-up）。只经维护入口 `install/3` 写入。
    信标是否可用只看 `core` 处当前材料是否为目录 `beacon_anchor` 材料——核心被挖掉或换掉即失效，不另存状态。
  - **调谐** `state.beacon_attunements`（cid => 已调谐 id 列表）随日志／检查点持久化；只经工具 `beacon.use`
    （玩家 G 对准锚心石）写入。
  - **出发**：Player 是读条 owner；World 只在开始（`prepare/3`）与结束（`commit/3`）各校验一次，返回读条秒数与落点。
    读条 = 目录 `windup_base_s` + `windup_per_km_s` × 两核心距离（km）。
  """
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Edits, Log, Observation}

  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "维护入口：同 key 只装一次；回执记在 `material_supplies[{0, {:beacon, key}}]`。返回 GenServer reply 三元组。"
  def install(state, key, %{id: id, name: name, core: {_, _, _} = core, landing: {_, _, _} = landing})
      when is_binary(key) and byte_size(key) > 0 and is_binary(id) and byte_size(id) > 0 and is_binary(name) do
    rkey = {0, {:beacon, key}}

    case Map.fetch(state.material_supplies, rkey) do
      {:ok, receipt} ->
        {:reply, {:ok, receipt}, state}

      :error ->
        {anchor?, state} = anchor_at?(state, core)

        if anchor? do
          record = %{id: id, name: name, core: core, landing: landing}
          receipt = %{seq: state.seq + 1, beacon: id}
          next = %{state | beacons: Map.put(state.beacons, id, record),
            material_supplies: Map.put(state.material_supplies, rkey, receipt)}
          commit(state, next, %{beacons: %{id => record}, material_supplies: %{rkey => receipt}}, receipt)
        else
          {:reply, {:error, :not_an_anchor}, state}
        end
    end
  end

  def install(state, _key, _record), do: {:reply, {:error, :invalid_beacon}, state}

  @doc "工具 `beacon.use`：命中锚心石时调谐离角色最近、在可达距离内的信标；已调谐时不提交，回当前 seq。"
  def use_tool(before, state, actor, request, target, tool) do
    cond do
      request.action != 1 or not anchor_material?(state, target.material) ->
        {:reply, {:error, :not_an_anchor}, before}

      true ->
        case nearest(state, actor.position, tool["reach_m"]) do
          nil ->
            {:reply, {:error, :too_far}, before}

          beacon ->
            attuned = Map.get(state.beacon_attunements, actor.cid, [])

            if beacon.id in attuned do
              {:reply, {:ok, state.seq}, state}
            else
              list = attuned ++ [beacon.id]
              next = %{state | beacon_attunements: Map.put(state.beacon_attunements, actor.cid, list)}
              commit(before, next, %{beacon_attunements: %{actor.cid => list}}, nil)
            end
        end
    end
  end

  @doc "角色的信标目录：全部信标，按 id 排序，各带是否已调谐。"
  def directory(state, cid) do
    attuned = Map.get(state.beacon_attunements, cid, [])

    state.beacons
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{id: &1.id, name: &1.name, core: core_m(&1), landing: &1.landing, attuned: &1.id in attuned})
  end

  @doc "出发开始：源在可达距离内且完好、目的已调谐且完好；返回 `{{:ok, windup_s} | {:error, reason}, state}`。"
  def prepare(state, actor, %{from: from, to: to}) do
    tool = tool(state)

    with {:ok, source, state} <- intact(state, from),
         {:ok, dest, state} <- intact(state, to),
         true <- from != to || {:error, :same_beacon},
         true <- to in Map.get(state.beacon_attunements, actor.cid, []) || {:error, :not_attuned},
         true <- distance(actor.position, core_m(source)) <= tool["reach_m"] || {:error, :too_far} do
      km = distance(core_m(source), core_m(dest)) / 1000
      {{:ok, tool["windup_base_s"] + tool["windup_per_km_s"] * km}, state}
    else
      {:error, reason, state} -> {{:error, reason}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @doc "读条结束：目的仍完好即放行，返回落点探针。"
  def commit_travel(state, _actor, %{to: to}) do
    case intact(state, to) do
      {:ok, dest, state} -> {{:ok, dest.landing}, state}
      {:error, reason, state} -> {{:error, reason}, state}
    end
  end

  @doc "目录里唯一的 `beacon.use` 工具行。"
  def tool(state), do: Enum.find_value(state.properties.tools, fn {_, t} -> t["action"] == "beacon.use" && t end)

  def anchor_material?(state, material),
    do: Map.get(state.properties.materials[material] || %{}, "beacon_anchor", false) == true

  defp intact(state, id) do
    case Map.fetch(state.beacons, id) do
      {:ok, beacon} ->
        case anchor_at?(state, beacon.core) do
          {true, state} -> {:ok, beacon, state}
          {false, state} -> {:error, :beacon_lost, state}
        end

      :error ->
        {:error, :unknown_beacon, state}
    end
  end

  defp anchor_at?(state, micro) do
    {cell, _} = VoxelRegion.Prefab.macro_slot(micro)
    state = Edits.ensure_sources(state, [cell])
    {target, state} = target_at(micro, state)
    {target != nil and anchor_material?(state, target.material), state}
  end

  defp nearest(state, position, reach) do
    state.beacons
    |> Map.values()
    |> Enum.map(&{distance(position, core_m(&1)), &1})
    |> Enum.filter(fn {d, _} -> d <= reach end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_, beacon} -> beacon
    end
  end

  defp core_m(%{core: {x, y, z}}), do: {(x + 0.5) / @micro, (y + 0.5) / @micro, (z + 0.5) / @micro}

  defp distance({ax, ay, az}, {bx, by, bz}),
    do: :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by) + (az - bz) * (az - bz))

  # 不改几何的一笔提交（同 `Production.supply_materials`）。
  defp commit(before, next, fields, receipt) do
    next = %{next | seq: before.seq + 1}
    txn = Map.merge(%{seq: next.seq, entries: [], coarse: []}, fields)

    case Log.append_log(before, next, txn) do
      :ok ->
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)
        {:reply, {:ok, receipt || next.seq}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end
end
