defmodule MmoContracts.CellIdTest do
  use ExUnit.Case, async: true

  alias MmoContracts.CellId

  describe "morton/2(CELL-2)" do
    test "构造并校验" do
      cid = CellId.morton(0, 1234)
      assert %CellId{kind: :morton, level: 0, morton: 1234} = cid
      assert CellId.valid?(cid)
      assert CellId.kind(cid) == :morton
    end
  end

  describe "region/4(v2.0.2 聚合等价, 3D AABB)" do
    test "构造并校验" do
      cid = CellId.region("r1", "scene1", {0, 0, 0}, {16, 4, 16})
      assert %CellId{kind: :region, region_id: "r1"} = cid
      assert CellId.valid?(cid)
    end

    test "max 必须各轴大于 min" do
      assert_raise FunctionClauseError, fn ->
        CellId.region("r1", "scene1", {0, 0, 0}, {16, 0, 16})
      end
    end
  end

  describe "contains_chunk?/2(3D AABB 半开区间, 含 Y, D-2)" do
    setup do
      %{cid: CellId.region("r1", "scene1", {0, 0, 0}, {16, 4, 16})}
    end

    test "覆盖范围内", %{cid: cid} do
      assert CellId.contains_chunk?(cid, {0, 0, 0})
      assert CellId.contains_chunk?(cid, {15, 3, 15})
    end

    test "Y 参与所有权(D-2):超出 Y 上界不覆盖", %{cid: cid} do
      refute CellId.contains_chunk?(cid, {0, 4, 0})
      assert CellId.contains_chunk?(cid, {0, 3, 0})
    end

    test "半开区间:max 边界不含", %{cid: cid} do
      refute CellId.contains_chunk?(cid, {16, 0, 0})
    end

    test "morton Cell 无显式 bounds 抛出" do
      assert_raise ArgumentError, fn ->
        CellId.contains_chunk?(CellId.morton(0, 1), {0, 0, 0})
      end
    end
  end

  describe "valid?/1" do
    test "非 CellId 为假" do
      refute CellId.valid?(:not_a_cell)
      refute CellId.valid?(%CellId{kind: :region, region_id: nil})
    end
  end

  describe "D-2 映射接缝(未实现占位)" do
    test "region_to_morton / morton_to_region 返回未实现" do
      assert {:error, :mapping_not_implemented} =
               CellId.region_to_morton(CellId.region("r1", "s", {0, 0, 0}, {1, 1, 1}))

      assert {:error, :mapping_not_implemented} =
               CellId.morton_to_region(CellId.morton(0, 1))
    end
  end
end
