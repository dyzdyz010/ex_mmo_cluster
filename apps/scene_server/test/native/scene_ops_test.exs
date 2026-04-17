defmodule SceneServer.Native.SceneOpsTest do
  use ExUnit.Case, async: true

  alias SceneServer.Native.SceneOps

  # 辅助：创建一套新的物理系统 + 角色数据
  defp fresh do
    {:ok, physys} = SceneOps.new_physics_system()

    {:ok, cdata} =
      SceneOps.new_character_data(
        1,
        "tester",
        {0.0, 0.0, 0.0},
        %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20},
        physys
      )

    {physys, cdata}
  end

  # ──────────────────────────────────────────────────────────
  # 1. new_physics_system/0
  # ──────────────────────────────────────────────────────────

  describe "new_physics_system/0" do
    test "返回 {:ok, reference}" do
      assert {:ok, ref} = SceneOps.new_physics_system()
      assert is_reference(ref)
    end

    test "多次调用返回不同的 reference" do
      {:ok, ref1} = SceneOps.new_physics_system()
      {:ok, ref2} = SceneOps.new_physics_system()
      refute ref1 == ref2
    end
  end

  # ──────────────────────────────────────────────────────────
  # 2. new_character_data/5
  # ──────────────────────────────────────────────────────────

  describe "new_character_data/5" do
    test "正常路径返回 {:ok, reference}" do
      {:ok, physys} = SceneOps.new_physics_system()

      assert {:ok, ref} =
               SceneOps.new_character_data(
                 42,
                 "hero",
                 {1.0, 2.0, 3.0},
                 %{"mmr" => 10, "cph" => 10, "cct" => 10, "pct" => 10, "rsl" => 10},
                 physys
               )

      assert is_reference(ref)
    end

    for missing_key <- ["mmr", "cph", "cct", "pct", "rsl"] do
      test "缺少 dev_attrs 键 '#{missing_key}' 时返回 {:error, :missing_dev_attr}" do
        {:ok, physys} = SceneOps.new_physics_system()
        full = %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}
        attrs = Map.delete(full, unquote(missing_key))

        assert {:error, :missing_dev_attr} =
                 SceneOps.new_character_data(1, "tester", {0.0, 0.0, 0.0}, attrs, physys)
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # 3. get_character_location/2
  # ──────────────────────────────────────────────────────────

  describe "get_character_location/2" do
    test "新建角色后读取位置，结果接近传入的初始 location" do
      {:ok, physys} = SceneOps.new_physics_system()
      loc = {5.0, 10.0, 15.0}

      {:ok, cdata} =
        SceneOps.new_character_data(
          1,
          "loc_tester",
          loc,
          %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20},
          physys
        )

      assert {:ok, {x, y, z}} = SceneOps.get_character_location(cdata, physys)
      assert_in_delta x, 5.0, 1.0
      assert_in_delta y, 10.0, 1.0
      assert_in_delta z, 15.0, 1.0
    end
  end

  # ──────────────────────────────────────────────────────────
  # 4. get_character_data_raw/2
  # ──────────────────────────────────────────────────────────

  describe "get_character_data_raw/2" do
    test "返回 {:ok, %CharacterDataDebug{}} 且字段与入参一致" do
      {:ok, physys} = SceneOps.new_physics_system()

      {:ok, cdata} =
        SceneOps.new_character_data(
          99,
          "raw_tester",
          {0.0, 0.0, 0.0},
          %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20},
          physys
        )

      assert {:ok, raw} = SceneOps.get_character_data_raw(cdata, physys)

      # 结构体存在且关键字段正确
      assert raw.cid == 99
      assert raw.nickname == "raw_tester"
      assert Map.has_key?(raw, :movement)
      assert Map.has_key?(raw, :dev_attrs)
    end
  end

  # ──────────────────────────────────────────────────────────
  # 5. update_character_movement/5 + movement_tick/2（有速度）
  # ──────────────────────────────────────────────────────────

  describe "update_character_movement/5 + movement_tick/2（有速度）" do
    test "设置正向 x 速度后连续 tick，x 坐标增大" do
      {physys, cdata} = fresh()

      # 设置 location=(0,0,0), velocity=(5,0,0), acceleration=(0,0,0)
      assert {:ok, :ok} =
               SceneOps.update_character_movement(
                 cdata,
                 {0.0, 0.0, 0.0},
                 {5.0, 0.0, 0.0},
                 {0.0, 0.0, 0.0},
                 physys
               )

      # make_move 使用系统时钟差计算位移，需要等待实际时间流逝
      Process.sleep(100)
      for _ <- 1..5, do: SceneOps.movement_tick(cdata, physys)

      assert {:ok, {x, _y, _z}} = SceneOps.get_character_location(cdata, physys)
      assert x > 0.0
    end

    test "设置负向 z 速度后 tick，z 坐标减小" do
      {physys, cdata} = fresh()

      assert {:ok, :ok} =
               SceneOps.update_character_movement(
                 cdata,
                 {0.0, 0.0, 0.0},
                 {0.0, 0.0, -3.0},
                 {0.0, 0.0, 0.0},
                 physys
               )

      Process.sleep(100)
      for _ <- 1..5, do: SceneOps.movement_tick(cdata, physys)

      assert {:ok, {_x, _y, z}} = SceneOps.get_character_location(cdata, physys)
      assert z < 0.0
    end
  end

  # ──────────────────────────────────────────────────────────
  # 6. movement_tick/2（速度为 0）
  # ──────────────────────────────────────────────────────────

  describe "movement_tick/2（速度为 0）" do
    test "零速度 tick 后位置几乎不变（允许 ≤ 0.1 漂移）" do
      {:ok, physys} = SceneOps.new_physics_system()

      {:ok, cdata} =
        SceneOps.new_character_data(
          1,
          "still",
          {10.0, 20.0, 30.0},
          %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20},
          physys
        )

      # 确保速度为 0
      SceneOps.update_character_movement(
        cdata,
        {10.0, 20.0, 30.0},
        {0.0, 0.0, 0.0},
        {0.0, 0.0, 0.0},
        physys
      )

      for _ <- 1..10, do: SceneOps.movement_tick(cdata, physys)

      assert {:ok, {x, y, z}} = SceneOps.get_character_location(cdata, physys)
      assert_in_delta x, 10.0, 0.1
      assert_in_delta y, 20.0, 0.1
      assert_in_delta z, 30.0, 0.1
    end
  end

  # ──────────────────────────────────────────────────────────
  # 7. 多个物理系统相互独立
  # ──────────────────────────────────────────────────────────

  describe "多个物理系统相互独立" do
    test "两套 physys 下的角色 reference 不同，行为不串扰" do
      {:ok, physys1} = SceneOps.new_physics_system()
      {:ok, physys2} = SceneOps.new_physics_system()

      # physys 的 reference 本身不同
      refute physys1 == physys2

      attrs = %{"mmr" => 20, "cph" => 20, "cct" => 20, "pct" => 20, "rsl" => 20}

      {:ok, cdata1} =
        SceneOps.new_character_data(1, "p1", {0.0, 0.0, 0.0}, attrs, physys1)

      {:ok, cdata2} =
        SceneOps.new_character_data(2, "p2", {0.0, 0.0, 0.0}, attrs, physys2)

      # cdata reference 不同
      refute cdata1 == cdata2

      # 在 physys1 中推进速度，physys2 中的角色不受影响
      SceneOps.update_character_movement(
        cdata1,
        {0.0, 0.0, 0.0},
        {10.0, 0.0, 0.0},
        {0.0, 0.0, 0.0},
        physys1
      )

      # make_move 使用系统时钟差，需等待实际时间流逝
      Process.sleep(100)
      for _ <- 1..5, do: SceneOps.movement_tick(cdata1, physys1)

      assert {:ok, {x1, _, _}} = SceneOps.get_character_location(cdata1, physys1)
      assert {:ok, {x2, _, _}} = SceneOps.get_character_location(cdata2, physys2)

      # physys1 角色移动，physys2 角色保持原位
      assert x1 > 0.0
      assert_in_delta x2, 0.0, 0.5
    end
  end
end
