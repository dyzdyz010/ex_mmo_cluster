defmodule DataService.Voxel.OverlayLogStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Voxel.OverlayLogStore

  @cv 0xF1E2_D3C4_B5A6_9788
  @other 0x0000_0000_0000_0001

  setup do
    OverlayLogStore.reset()
    :ok
  end

  defp row(seq, ordinal, kind, level, region, payload),
    do: %{seq: seq, ordinal: ordinal, kind: kind, level: level, region: region, payload: payload}

  test "rows come back per world in (seq, ordinal) order; replace swaps the whole world atomically" do
    # u64 content_version（最高位为 1）按补码存 bigint，读回原值。
    OverlayLogStore.append(@cv, [row(1, 1, 2, 1, {0, 0, 0}, "coarse"), row(1, 0, 0, 0, {-1, 0, 2}, "cell")])
    OverlayLogStore.append(@cv, [row(2, 0, 1, 3, {0, -1, 0}, <<0, 255, 7>>)])
    OverlayLogStore.append(@other, [row(1, 0, 0, 0, {9, 9, 9}, "elsewhere")])

    assert Enum.map(OverlayLogStore.read_all(@cv), &{&1.seq, &1.ordinal, &1.kind, &1.level, &1.region, &1.payload}) ==
             [{1, 0, 0, 0, {-1, 0, 2}, "cell"}, {1, 1, 2, 1, {0, 0, 0}, "coarse"}, {2, 0, 1, 3, {0, -1, 0}, <<0, 255, 7>>}]

    OverlayLogStore.replace(@cv, [row(2, 0, 1, 0, {0, 0, 0}, "checkpoint")])
    assert Enum.map(OverlayLogStore.read_all(@cv), &{&1.seq, &1.payload}) == [{2, "checkpoint"}]
    assert Enum.map(OverlayLogStore.read_all(@other), &{&1.seq, &1.payload}) == [{1, "elsewhere"}]

    # 重复 (seq, ordinal) 被唯一索引拒绝，事务整体回滚，已有行不变。
    assert_raise Postgrex.Error, fn -> OverlayLogStore.append(@cv, [row(3, 0, 0, 0, {0, 0, 0}, "a"), row(2, 0, 0, 0, {0, 0, 0}, "dup")]) end
    assert Enum.map(OverlayLogStore.read_all(@cv), &{&1.seq, &1.payload}) == [{2, "checkpoint"}]
  end
end
