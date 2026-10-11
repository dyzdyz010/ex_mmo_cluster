defmodule VoxelRegion.World.Interactions do
  @moduledoc "全局系统功能：World 已提交操作的有界经历序列，与世界事务及检查点一起持久化。"
  alias VoxelRegion.{Damage, FileStore, Prefab}

  @limit 512

  @doc "在操作构造边界冻结实际目标的提交前归属，不改变既有 operation 的网络字段。"
  def capture(state, actor, kind, target) do
    %{
      seq: state.seq + 1,
      at_ms: System.system_time(:millisecond),
      actor: actor.cid,
      kind: Enum.at([:damage, :destroy, :build], kind),
      cell: Damage.macro(target),
      material: target.material,
      placed_by: placed_by(state, target)
    }
  end

  defp placed_by(state, %{granularity: 2, micro: micro}) do
    {cell, slot} = Prefab.macro_slot(micro)

    case get_in(state.refined, [cell, slot]) do
      {_material, owner} -> Map.get(Map.get(state.instances, owner, %{}), :placed_by)
      nil -> nil
    end
  end

  defp placed_by(state, %{granularity: 1, owner: owner}),
    do: Map.get(Map.get(state.instances, owner, %{}), :placed_by)

  defp placed_by(state, %{granularity: 3, slot: slot}) do
    case Map.get(state.attachments, slot) do
      {id, _material} -> placed_by(state, %{granularity: 3, incarnation: id})
      nil -> nil
    end
  end

  defp placed_by(state, %{granularity: 3, incarnation: id}) do
    case Map.get(state.attachment_owners, id) do
      {owner, _slot} -> Map.get(Map.get(state.instances, owner, %{}), :placed_by)
      nil -> nil
    end
  end

  defp placed_by(state, target),
    do: Map.get(state.placed_by, elem(Prefab.macro_slot(target.micro), 0))

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
