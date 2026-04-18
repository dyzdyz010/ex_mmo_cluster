defmodule SceneServer.Native.OctreeTest do
  use ExUnit.Case, async: true

  alias SceneServer.Native.Octree

  # 辅助：创建一棵以原点为中心、半径 500 的标准测试树
  defp big_tree do
    Octree.new_tree({0.0, 0.0, 0.0}, {500.0, 500.0, 500.0})
  end

  # ──────────────────────────────────────────────────────────
  # 1. new_tree/2
  # ──────────────────────────────────────────────────────────

  describe "new_tree/2" do
    test "不同 center/half_size 均返回 reference" do
      tree1 = Octree.new_tree({0.0, 0.0, 0.0}, {100.0, 100.0, 100.0})
      tree2 = Octree.new_tree({50.0, 50.0, 50.0}, {200.0, 200.0, 200.0})

      assert is_reference(tree1)
      assert is_reference(tree2)
      refute tree1 == tree2
    end
  end

  # ──────────────────────────────────────────────────────────
  # 2. new_item/2
  # ──────────────────────────────────────────────────────────

  describe "new_item/2" do
    test "创建 item 返回 reference" do
      item = Octree.new_item(1, {0.0, 0.0, 0.0})
      assert is_reference(item)
    end

    test "不同 cid/位置 返回不同 reference" do
      item1 = Octree.new_item(1, {0.0, 0.0, 0.0})
      item2 = Octree.new_item(2, {10.0, 10.0, 10.0})
      refute item1 == item2
    end
  end

  # ──────────────────────────────────────────────────────────
  # 3. add_item/2 + get_in_bound/3
  # ──────────────────────────────────────────────────────────

  describe "add_item/2 + get_in_bound/3" do
    test "插入 item 后在包含它的 bounding box 内查到该 cid" do
      tree = big_tree()
      item = Octree.new_item(42, {10.0, 10.0, 10.0})
      Octree.add_item(tree, item)

      result = Octree.get_in_bound(tree, {10.0, 10.0, 10.0}, {5.0, 5.0, 5.0})
      assert 42 in result
    end

    test "查询不包含 item 的 bounding box 返回空列表" do
      tree = big_tree()
      item = Octree.new_item(42, {10.0, 10.0, 10.0})
      Octree.add_item(tree, item)

      # 查询一个完全不相交的区域
      result = Octree.get_in_bound(tree, {-200.0, -200.0, -200.0}, {10.0, 10.0, 10.0})
      assert result == []
    end

    test "插入多个 item 后查询 bounding box，结果包含所有期望 cid" do
      tree = big_tree()

      items =
        for cid <- 1..5 do
          pos = {cid * 1.0, 0.0, 0.0}
          item = Octree.new_item(cid, pos)
          Octree.add_item(tree, item)
          cid
        end

      # 查询一个覆盖所有 item 的区域
      result = Octree.get_in_bound(tree, {3.0, 0.0, 0.0}, {3.0, 1.0, 1.0})

      assert Enum.sort(result) == Enum.sort(items)
    end
  end

  # ──────────────────────────────────────────────────────────
  # 4. remove_item/2
  # ──────────────────────────────────────────────────────────

  describe "remove_item/2" do
    test "删除已插入的 item 返回 true，再查询不再命中" do
      tree = big_tree()
      item = Octree.new_item(7, {20.0, 20.0, 20.0})
      Octree.add_item(tree, item)

      assert Octree.remove_item(tree, item) == true

      result = Octree.get_in_bound(tree, {20.0, 20.0, 20.0}, {5.0, 5.0, 5.0})
      refute 7 in result
    end

    test "重复删除同一 item 返回 false" do
      tree = big_tree()
      item = Octree.new_item(8, {30.0, 30.0, 30.0})
      Octree.add_item(tree, item)

      assert Octree.remove_item(tree, item) == true
      assert Octree.remove_item(tree, item) == false
    end
  end

  # ──────────────────────────────────────────────────────────
  # 5. get_in_bound_except/3
  # ──────────────────────────────────────────────────────────

  describe "get_in_bound_except/3" do
    test "排除指定 item 后，结果不含该 cid，但含其他在范围内的 cid" do
      tree = big_tree()

      anchor = Octree.new_item(100, {0.0, 0.0, 0.0})
      neighbor1 = Octree.new_item(101, {5.0, 0.0, 0.0})
      neighbor2 = Octree.new_item(102, {-5.0, 0.0, 0.0})

      Octree.add_item(tree, anchor)
      Octree.add_item(tree, neighbor1)
      Octree.add_item(tree, neighbor2)

      # get_in_bound_except 以 anchor 的位置为中心，排除 anchor 自身
      result = Octree.get_in_bound_except(tree, anchor, {10.0, 10.0, 10.0})

      refute 100 in result
      assert 101 in result
      assert 102 in result
    end
  end

  # ──────────────────────────────────────────────────────────
  # 6. 边界测试：half_size = {0,0,0}，item 恰在 center 处
  # ──────────────────────────────────────────────────────────

  describe "边界测试：zero half_size" do
    test "item 恰在查询 center 处，zero half_size 命中（边界包含）" do
      tree = big_tree()
      item = Octree.new_item(200, {1.0, 1.0, 1.0})
      Octree.add_item(tree, item)

      result = Octree.get_in_bound(tree, {1.0, 1.0, 1.0}, {0.0, 0.0, 0.0})

      # 观察 Rust 边界行为：假设边界包含（即精确命中），若 Rust 不命中则调整为 == []
      assert 200 in result
    end
  end

  # ──────────────────────────────────────────────────────────
  # 7. get_tree_raw/1
  # ──────────────────────────────────────────────────────────

  describe "get_tree_raw/1" do
    test "返回可检查的调试结构（map 或 struct）" do
      tree = big_tree()
      item = Octree.new_item(1, {0.0, 0.0, 0.0})
      Octree.add_item(tree, item)

      raw = Octree.get_tree_raw(tree)

      assert is_map(raw) or is_tuple(raw)
    end
  end
end
