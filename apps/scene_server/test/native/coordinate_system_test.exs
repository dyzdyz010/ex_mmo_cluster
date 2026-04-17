defmodule SceneServer.Native.CoordinateSystemTest do
  # 注意：update_item_from_system_new/3 对应的 Rust NIF 已被注释掉
  # （coordinate_system/src/lib.rs 第 305-328 行），Elixir 侧为空 stub，
  # 调用会触发 :nif_not_loaded panic，因此本文件不测试该函数。
  use ExUnit.Case, async: true

  alias SceneServer.Native.CoordinateSystem, as: CS

  # 辅助：创建标准 system（容量 1000，桶大小 50）
  defp fresh_system do
    {:ok, sys} = CS.new_system(1000, 50)
    sys
  end

  # ──────────────────────────────────────────────────────────
  # 1. new_item/2
  # ──────────────────────────────────────────────────────────

  describe "new_item/2" do
    test "返回 {:ok, reference}" do
      assert {:ok, ref} = CS.new_item(1, {0.0, 0.0, 0.0})
      assert is_reference(ref)
    end

    test "不同 cid 返回不同 reference" do
      {:ok, ref1} = CS.new_item(1, {0.0, 0.0, 0.0})
      {:ok, ref2} = CS.new_item(2, {1.0, 1.0, 1.0})
      refute ref1 == ref2
    end
  end

  # ──────────────────────────────────────────────────────────
  # 2. get_item_raw/1
  # ──────────────────────────────────────────────────────────

  describe "get_item_raw/1" do
    test "返回 {:ok, item}，且 item 包含 cid 字段" do
      {:ok, item_ref} = CS.new_item(42, {3.0, 4.0, 5.0})

      assert {:ok, item} = CS.get_item_raw(item_ref)
      assert item.cid == 42
    end
  end

  # ──────────────────────────────────────────────────────────
  # 3. new_bucket/0 → add_item_to_bucket/3 → get_bucket_raw/1
  # ──────────────────────────────────────────────────────────

  describe "bucket 操作" do
    test "new_bucket 返回 {:ok, ref}" do
      assert {:ok, bk} = CS.new_bucket()
      assert is_reference(bk)
    end

    test "插入几个 item 后 get_bucket_raw 可读" do
      {:ok, bk} = CS.new_bucket()

      assert {:ok, :ok} = CS.add_item_to_bucket(bk, 1, {0.0, 0.0, 0.0})
      assert {:ok, :ok} = CS.add_item_to_bucket(bk, 2, {1.0, 1.0, 1.0})
      assert {:ok, :ok} = CS.add_item_to_bucket(bk, 3, {2.0, 2.0, 2.0})

      assert {:ok, raw} = CS.get_bucket_raw(bk)
      assert is_map(raw) or is_struct(raw) or is_tuple(raw)
    end
  end

  # ──────────────────────────────────────────────────────────
  # 4. new_set/2 → add_item_to_set/3 → get_set_raw/1
  # ──────────────────────────────────────────────────────────

  describe "sorted_set 操作" do
    test "new_set 返回 {:ok, ref}" do
      assert {:ok, ss} = CS.new_set(1000, 50)
      assert is_reference(ss)
    end

    test "插入几个 item 后 get_set_raw 可读" do
      {:ok, ss} = CS.new_set(1000, 50)

      assert {:ok, :ok} = CS.add_item_to_set(ss, 10, {0.0, 0.0, 0.0})
      assert {:ok, :ok} = CS.add_item_to_set(ss, 11, {5.0, 5.0, 5.0})

      assert {:ok, raw} = CS.get_set_raw(ss)
      assert is_map(raw) or is_struct(raw) or is_tuple(raw)
    end
  end

  # ──────────────────────────────────────────────────────────
  # 5. new_system/2 + add_item_to_system/3
  # ──────────────────────────────────────────────────────────

  describe "new_system/2 + add_item_to_system/3" do
    test "正常添加 item 返回 {:ok, item_ref}" do
      sys = fresh_system()

      assert {:ok, item_ref} = CS.add_item_to_system(sys, 1, {0.0, 0.0, 0.0})
      assert is_reference(item_ref)
    end

    test "重复添加同一 cid 同坐标的 item 返回 {:error, :duplicate}" do
      sys = fresh_system()

      assert {:ok, _} = CS.add_item_to_system(sys, 1, {0.0, 0.0, 0.0})
      assert {:error, :duplicate} = CS.add_item_to_system(sys, 1, {0.0, 0.0, 0.0})
    end
  end

  # ──────────────────────────────────────────────────────────
  # 6. remove_item_from_system/2
  # ──────────────────────────────────────────────────────────

  describe "remove_item_from_system/2" do
    test "移除已添加的 item 返回 {:ok, {usize, usize, usize}}" do
      sys = fresh_system()
      {:ok, item_ref} = CS.add_item_to_system(sys, 1, {0.0, 0.0, 0.0})

      assert {:ok, {a, b, c}} = CS.remove_item_from_system(sys, item_ref)
      assert is_integer(a) and is_integer(b) and is_integer(c)
    end
  end

  # ──────────────────────────────────────────────────────────
  # 7. update_item_from_system/3
  # ──────────────────────────────────────────────────────────

  describe "update_item_from_system/3" do
    test "移动 item 到新位置返回 {:ok, {_, _, _}}" do
      sys = fresh_system()
      {:ok, item_ref} = CS.add_item_to_system(sys, 1, {0.0, 0.0, 0.0})

      assert {:ok, {a, b, c}} =
               CS.update_item_from_system(sys, item_ref, {10.0, 20.0, 30.0})

      assert is_integer(a) and is_integer(b) and is_integer(c)
    end
  end

  # ──────────────────────────────────────────────────────────
  # 8. get_cids_within_distance_from_system/3
  # ──────────────────────────────────────────────────────────

  describe "get_cids_within_distance_from_system/3" do
    test "查询锚点周围一定距离内的 cid 列表，包含预期 cid" do
      sys = fresh_system()

      # 锚点在原点
      {:ok, anchor} = CS.add_item_to_system(sys, 1, {0.0, 0.0, 0.0})
      # 近邻（距离 5）
      {:ok, _near} = CS.add_item_to_system(sys, 2, {5.0, 0.0, 0.0})
      # 远邻（距离 200，不在查询范围内）
      {:ok, _far} = CS.add_item_to_system(sys, 3, {200.0, 0.0, 0.0})

      assert {:ok, cids} = CS.get_cids_within_distance_from_system(sys, anchor, 10.0)

      # 近邻应在结果中
      assert 2 in cids
      # 远邻不应在结果中
      refute 3 in cids
    end
  end

  # ──────────────────────────────────────────────────────────
  # 9. get_items_within_distance_from_system/3
  # ──────────────────────────────────────────────────────────

  describe "get_items_within_distance_from_system/3" do
    test "返回范围内的 item 列表，包含预期 cid 的 item" do
      sys = fresh_system()

      {:ok, anchor} = CS.add_item_to_system(sys, 10, {0.0, 0.0, 0.0})
      {:ok, _near} = CS.add_item_to_system(sys, 11, {3.0, 0.0, 0.0})
      {:ok, _far} = CS.add_item_to_system(sys, 12, {500.0, 0.0, 0.0})

      assert {:ok, items} = CS.get_items_within_distance_from_system(sys, anchor, 10.0)

      cids = Enum.map(items, & &1.cid)
      assert 11 in cids
      refute 12 in cids
    end
  end

  # ──────────────────────────────────────────────────────────
  # 10. calculate_coordinate/4
  # ──────────────────────────────────────────────────────────

  describe "calculate_coordinate/4" do
    test "沿 +x 方向匀速 1 秒，x 坐标增大" do
      # 时间戳单位是毫秒：1000ms = 1 秒
      result = CS.calculate_coordinate(0, 1000, {0.0, 0.0, 0.0}, {1.0, 0.0, 0.0})

      assert is_tuple(result)
      {x, y, z} = result
      # x 应大于 0（向 +x 方向移动）
      assert x > 0.0
      assert_in_delta y, 0.0, 1.0e-9
      assert_in_delta z, 0.0, 1.0e-9
    end

    test "速度为零时返回原坐标" do
      result = CS.calculate_coordinate(0, 1000, {5.0, 6.0, 7.0}, {0.0, 0.0, 0.0})
      {x, y, z} = result
      assert_in_delta x, 5.0, 1.0e-9
      assert_in_delta y, 6.0, 1.0e-9
      assert_in_delta z, 7.0, 1.0e-9
    end

    test "沿 -z 方向 500ms，z 坐标减小" do
      result = CS.calculate_coordinate(0, 500, {0.0, 0.0, 0.0}, {0.0, 0.0, -2.0})
      {_x, _y, z} = result
      assert z < 0.0
    end
  end
end
