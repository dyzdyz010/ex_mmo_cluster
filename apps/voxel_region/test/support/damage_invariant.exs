defmodule VoxelRegion.TestSupport.DamageInvariant do
  @moduledoc """
  只测试：damage 无过期行的不变量（M1 编辑清理按“提交前改动格上的目标”反查行的前提）。

  一行不过期 = 它的键仍等于当前世界在该行坐标上实占目标的键：
  - granularity 0 / 1 / 2：`target_at(row.micro)` 非空，且按行粒度归一后键相同（2 → 1 为 refined 微格热节点）；
  - granularity 4：附件槽仍是 `{incarnation, material}`；
  - granularity 3（附件整件 HP）：最大 HP 仍等于该实例现有槽折算的值（实例已无槽时为 0，即过期）。
  期望只用 `target_at`、附件表与 `attachment_max_hp` 的定义，不调用被测的反查。
  测试与 M1 真实数据核对（bench 经 `Code.compile_file/1` 编译进节点）共用本文件。
  """

  alias VoxelRegion.{Attachments, Damage}
  alias VoxelRegion.World.Canonical

  @doc "过期行（按粒度分组的键列表）与逐粒度行数；返回的 state 只多了区域缓存，调用方可丢弃。"
  def stale(state) do
    {stale, counts, _} =
      Enum.reduce(state.damage, {%{}, %{}, state}, fn {key, row}, {stale, counts, s} ->
        {ok?, s} = current?(s, row)
        counts = Map.update(counts, row.granularity, 1, &(&1 + 1))
        stale = if ok?, do: stale, else: Map.update(stale, row.granularity, [key], &[key | &1])
        {stale, counts, s}
      end)

    {stale, counts}
  end

  defp current?(s, %{granularity: 3} = row), do: {Canonical.attachment_max_hp(s, row) == row.max_hp, s}

  defp current?(s, %{granularity: 4} = row),
    do: {Map.get(s.attachments, Attachments.slot(row)) == {row.incarnation, row.material}, s}

  defp current?(s, %{granularity: g} = row) do
    case Canonical.target_at(row.micro, s) do
      {nil, s} -> {false, s}
      {%{granularity: 2} = t, s} when g == 1 -> {Damage.key(%{t | granularity: 1}) == Damage.key(row), s}
      {t, s} -> {t.granularity == g and Damage.key(t) == Damage.key(row), s}
    end
  end
end
