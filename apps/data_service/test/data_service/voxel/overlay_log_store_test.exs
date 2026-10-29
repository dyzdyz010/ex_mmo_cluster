defmodule DataService.Voxel.OverlayLogStoreTest do
  use ExUnit.Case, async: false

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  alias DataService.Voxel.{OverlayLogStore, PageStore}

  @cv 0xF1E2_D3C4_B5A6_9788
  @other 0x0000_0000_0000_0001

  setup do
    OverlayLogStore.reset()
    :ok
  end

  defp row(seq, ordinal, kind, level, region, payload),
    do: %{seq: seq, ordinal: ordinal, kind: kind, level: level, region: region, payload: payload}

  test "reset_world clears locators and pages together while preserving the other world" do
    ids = [{1, 71, 2}, {2, 81, 0}]
    seed_pages(@cv, ids, {-1, 2, -3})
    seed_pages(@other, ids, {4, -5, 6})
    other_pages = PageStore.load(@other)
    other_locators = PageStore.locate(@other, ids)
    assert map_size(PageStore.locate(@cv, ids)) == 2

    assert :ok = OverlayLogStore.reset_world(@cv)
    assert PageStore.locate(@cv, ids) == %{}
    assert PageStore.load(@cv) == %{prefix: nil}
    assert PageStore.page_keys(@cv) == []
    assert OverlayLogStore.read_all(@cv) == []
    assert PageStore.load(@other) == other_pages
    assert PageStore.locate(@other, ids) == other_locators

    # 同世界同身份重建必须指向新 home，不能被只插入定位表的旧行挡住。
    seed_pages(@cv, ids, {9, -8, 7})
    assert PageStore.locate(@cv, ids) ==
             Map.new(ids, &{&1, %{root: {71, 2}, home: {9, -8, 7}}})
  end

  test "reset clears published and unpublished locators across all test worlds" do
    ids = [{1, 91, 3}, {2, 101, 0}]
    seed_pages(@cv, ids, {-4, 5, 6})
    seed_pages(@other, ids, {7, 8, -9})
    pending = %{locator: {1, 111, 4}, root: {111, 4}, home: {-10, 11, 12}}
    assert :ok = PageStore.write(@other, 9, [pending])
    assert map_size(PageStore.locate(@other, ids ++ [pending.locator])) == 3

    assert :ok = OverlayLogStore.reset()

    for cv <- [@cv, @other] do
      assert PageStore.locate(cv, ids ++ [pending.locator]) == %{}
      assert PageStore.load(cv) == %{prefix: nil}
      assert PageStore.page_keys(cv) == []
      assert OverlayLogStore.read_all(cv) == []
    end
  end

  defp seed_pages(cv, ids, home) do
    segment = %{level: 0, region: home, segment: 0, chunk: {0, 0, 0}, payload: "page"}
    locators = Enum.map(ids, &%{locator: &1, root: {elem(hd(ids), 1), elem(hd(ids), 2)}, home: home})
    assert :ok = PageStore.publish(cv, 7, [segment | locators], "globals")
    assert :ok = OverlayLogStore.append(cv, [row(8, 0, 0, 0, home, "tail")])
  end

  test "rows come back per world in (seq, ordinal) order; replace swaps the whole world atomically" do
    # u64 content_version（最高位为 1）按补码存 bigint，读回原值。
    OverlayLogStore.append(@cv, [
      row(1, 1, 2, 1, {0, 0, 0}, "coarse"),
      row(1, 0, 0, 0, {-1, 0, 2}, "cell")
    ])

    OverlayLogStore.append(@cv, [row(2, 0, 1, 3, {0, -1, 0}, <<0, 255, 7>>)])
    OverlayLogStore.append(@other, [row(1, 0, 0, 0, {9, 9, 9}, "elsewhere")])

    assert Enum.map(
             OverlayLogStore.read_all(@cv),
             &{&1.seq, &1.ordinal, &1.kind, &1.level, &1.region, &1.payload}
           ) ==
             [
               {1, 0, 0, 0, {-1, 0, 2}, "cell"},
               {1, 1, 2, 1, {0, 0, 0}, "coarse"},
               {2, 0, 1, 3, {0, -1, 0}, <<0, 255, 7>>}
             ]

    OverlayLogStore.replace(@cv, [row(2, 0, 1, 0, {0, 0, 0}, "checkpoint")])
    assert Enum.map(OverlayLogStore.read_all(@cv), &{&1.seq, &1.payload}) == [{2, "checkpoint"}]
    assert Enum.map(OverlayLogStore.read_all(@other), &{&1.seq, &1.payload}) == [{1, "elsewhere"}]

    # 重复 (seq, ordinal) 被唯一索引拒绝，事务整体回滚，已有行不变。
    assert_raise Postgrex.Error, fn ->
      OverlayLogStore.append(@cv, [
        row(3, 0, 0, 0, {0, 0, 0}, "a"),
        row(2, 0, 0, 0, {0, 0, 0}, "dup")
      ])
    end

    assert Enum.map(OverlayLogStore.read_all(@cv), &{&1.seq, &1.payload}) == [{2, "checkpoint"}]
  end

  test "prefix replacement keeps every later row and the other world" do
    prefix = [row(1, 0, 0, 0, {-1, 0, 0}, "old"), row(4, 0, 3, 0, {0, 0, 0}, "at-cut")]

    tail = [
      row(5, 0, 0, 0, {1, 0, 0}, "tail-cell"),
      row(5, 1, 3, 0, {0, 0, 0}, "tail-metadata"),
      row(6, 0, 2, 1, {0, 0, 0}, "later")
    ]

    other = [row(2, 0, 0, 0, {0, 0, 0}, "other-world")]

    checkpoint = [
      row(4, 0, 1, 0, {-1, 0, 0}, "checkpoint-region"),
      row(4, 1, 3, 0, {0, 0, 0}, "checkpoint-metadata")
    ]

    :ok = OverlayLogStore.append(@cv, prefix ++ tail)
    :ok = OverlayLogStore.append(@other, other)

    assert :ok = OverlayLogStore.replace(@cv, checkpoint, through_seq: 4)
    assert OverlayLogStore.read_all(@cv) == checkpoint ++ tail
    assert OverlayLogStore.read_all(@other) == other

    # 截止序号独立于条目数；空检查点也只删除指定前缀。
    assert :ok = OverlayLogStore.replace(@cv, [], through_seq: 5)
    assert OverlayLogStore.read_all(@cv) == [List.last(tail)]
    assert OverlayLogStore.read_all(@other) == other
  end

  test "failed second insert batch rolls back prefix deletion and partial checkpoint rows" do
    before = [
      row(1, 0, 0, 0, {0, 0, 0}, "old"),
      row(4, 0, 3, 0, {0, 0, 0}, "at-cut"),
      row(5, 0, 3, 0, {0, 0, 0}, "tail")
    ]

    :ok = OverlayLogStore.append(@cv, before)

    # 第一批500行已写入后，第二批触发真实PG唯一约束；整笔替换必须回滚。
    checkpoint = for ordinal <- 0..499, do: row(4, ordinal, 0, 0, {0, 0, 0}, "checkpoint")

    assert_raise Postgrex.Error, fn ->
      OverlayLogStore.replace(@cv, checkpoint ++ [hd(checkpoint)], through_seq: 4)
    end

    assert OverlayLogStore.read_all(@cv) == before
  end
end
