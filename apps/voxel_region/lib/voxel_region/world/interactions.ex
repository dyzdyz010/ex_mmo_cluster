defmodule VoxelRegion.World.Interactions do
  alias VoxelRegion.RefinedSlots
  @moduledoc "全局系统功能：World 已提交操作的有界经历序列，与世界事务及检查点一起持久化。"
  alias VoxelRegion.{Damage, FileStore, Prefab}
  alias VoxelRegion.World.Canonical

  @limit 512

  @doc """
  在操作构造边界冻结实际目标的提交前归属，不改变既有 operation 的网络字段。

  `placed_by` 是放下目标的角色；`prefab` 是目标所属建筑的定义 id——目标属于某个 prefab 实例时取它的根实例
  （整体放下的那一个）的定义，散格、细化空槽、无主附件为 nil。定义的名字不在这里：读者按 id 查
  `VoxelRegion.World.published_prefab_metadata/1`。2026-11-12 之前提交的事件没有 `prefab` 键。

  `instance` 是那个根实例的 id（`{birth, occurrence}`，与 `World.instance_cells/2`、`voxel_prefab_remove_v1` 同一身份），
  `anchor` 是根实例锚点所在的宏格；散格等没有所属实例时都为 nil。`instance_removed` 不在这里：它要提交后的状态，
  由提交处的 `settle/2` 补上。这三个键 2026-11-12（S1-D2）之前提交的事件没有。

  `placed_by` 总按提交前（`state`）取。所属建筑（`prefab` / `instance` / `anchor`）按 `holder`——目标存在的那一侧——取，
  缺省就是 `state`：damage / destroy 被打的是原来那座；prefab 放置 / 替换的目标提交后才存在，由 `Prefabs` 传提交后的
  状态，于是这类 build 带的是刚放下的那座。散格建造与附件建造没有所属建筑。
  """
  def capture(state, actor, kind, target), do: capture(state, actor, kind, target, state)

  def capture(state, actor, kind, target, holder) do
    placed_by =
      case origin(state, target) do
        {:instance, id} -> Map.get(Map.get(state.instances, id, %{}), :placed_by)
        {:cell, cell} -> Canonical.chunk_get(state.placed_by, cell)
        nil -> nil
      end

    root =
      case origin(holder, target) do
        {:instance, id} -> root(holder, id)
        {:cell, cell} -> root(holder, Map.get(holder.macro_owners, cell))
        nil -> nil
      end

    instance = root && Map.fetch!(holder.instances, root)

    %{
      seq: state.seq + 1,
      at_ms: System.system_time(:millisecond),
      actor: actor.cid,
      kind: Enum.at([:damage, :destroy, :build], kind),
      cell: Damage.macro(target),
      material: target.material,
      placed_by: placed_by,
      prefab: instance && instance.definition_id,
      instance: root,
      anchor: instance && elem(Prefab.macro_slot(instance.anchor), 0)
    }
  end

  @doc """
  提交处（事务已构造、提交后的状态已定、尚未落盘）补上 `instance_removed`：这笔提交之后根实例 `instance` 已不在
  World（整座被移除——World 裁掉失去全部格且没有存活后代的实例，`Payloads.prune_instances/1`）。按根实例判断：
  多构件建筑拆掉一个叶子构件，根还在就是 false。没有所属实例为 false。不带经历的事务原样返回。
  """
  def settle(%{interaction: event} = txn, state),
    do: %{txn | interaction: Map.put(event, :instance_removed, event.instance != nil and not Map.has_key?(state.instances, event.instance))}

  def settle(txn, _state), do: txn

  # 提交前目标的归属：`{:instance, 实例 id}`（细化槽、附件）、`{:cell, 宏格}`（宏格：放置溯源按格记，
  # 所属实例在 macro_owners 里，散格没有）或 nil（细化空槽、无主附件）。
  defp origin(state, %{granularity: 2, micro: micro}) do
    {cell, slot} = Prefab.macro_slot(micro)

    # 替换后的目标粒度不表示提交前粒度；旧表示是宏格时用其唯一溯源，细化空槽仍然无主。
    case Map.fetch(state.refined, cell) do
      {:ok, slots} ->
        case RefinedSlots.fetch(slots, slot) do
          {:ok, {_material, owner}} -> {:instance, owner}
          :error -> nil
        end

      :error ->
        {:cell, cell}
    end
  end

  defp origin(_state, %{granularity: 1, owner: owner}), do: {:instance, owner}

  defp origin(state, %{granularity: 3, slot: slot}) do
    case Map.get(state.attachments, slot) do
      {id, _material} -> origin(state, %{granularity: 3, incarnation: id})
      nil -> nil
    end
  end

  defp origin(state, %{granularity: 3, incarnation: id}) do
    case Map.get(state.attachment_owners, id) do
      {owner, _slot} -> {:instance, owner}
      nil -> nil
    end
  end

  defp origin(_state, target), do: {:cell, elem(Prefab.macro_slot(target.micro), 0)}

  # 沿父链到根实例，取它的 id；没有所属实例（散格的 nil）或实例记录不在（与 placed_by 同样读作无主）为 nil。
  defp root(state, id) do
    case Map.get(state.instances, id) do
      nil ->
        nil

      instance ->
        case Map.get(instance, :parent_id, {0, 0}) do
          {0, 0} -> id
          parent -> root(state, parent)
        end
    end
  end

  @doc "仅成功落盘后或重放同一事务时推进序列；检查点恢复完整历史与已淘汰边界。"
  def apply(state, %{interaction_history: history, interaction_floor: floor}),
    do: %{state | interaction_history: history, interaction_floor: floor}

  def apply(state, %{interaction: event}) do
    history = state.interaction_history ++ [event]
    {removed, retained} = Enum.split(history, max(0, length(history) - @limit))

    floor =
      case List.last(removed) do
        nil -> state.interaction_floor
        event -> event.seq
      end

    %{state | interaction_history: retained, interaction_floor: floor}
  end

  def apply(state, _transaction), do: state

  @doc "nil 建立现在的游标；落后于已淘汰操作或非法游标明确失败。"
  def since(state, nil), do: reply(state, [])

  def since(state, cursor) when is_integer(cursor) and cursor >= 0 and cursor <= state.seq do
    if cursor < state.interaction_floor,
      do: {:error, {:interaction_gap, hd(state.interaction_history).seq}},
      else: reply(state, Enum.filter(state.interaction_history, &(&1.seq > cursor)))
  end

  def since(_state, _cursor), do: {:error, :invalid_interaction_cursor}

  defp reply(state, events),
    do: {:ok, %{world_id: FileStore.hex(state.cv), cursor: state.seq, events: events}}
end
