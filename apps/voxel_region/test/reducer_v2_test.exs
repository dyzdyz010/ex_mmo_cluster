defmodule VoxelRegion.ReducerV2Test do
  @moduledoc "只测试：F2a 手算冻结样本，证伪薄片丢失、错误轴向、排除材质漏判及旧优先级改变。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{Reducer, World, TestSupport}
  alias MmoContracts.Voxel.{Payload, Skins}

  defp cells(ids), do: Enum.map(ids, &{&1, Skins.uniform(&1)})

  test "ReduceCellV2 frozen octants and original majority" do
    samples = [
      {[0,0,1,1,0,0,1,1], 1}, {[1,1,0,0,1,1,0,0], 1},
      {[11,7,0,0,11,7,0,0], 7}, {[11,7,0,0,11,11,0,0], 11},
      {[1,0,0,1,0,1,1,0], 0}, {[1,0,1,0,1,0,1,0], 0},
      {[1,1,0,0,1,0,0,0], 0}, {[19,1,0,0,1,1,0,0], 0},
      {[1,0,0,0,0,0,0,0], 0}, {List.duplicate(0,8), 0},
      {List.duplicate(11,8), 11}, {[1,1,1,1,19,0,19,0], 1}
    ]
    for level <- 1..5, {ids, expected} <- samples do
      assert {^expected, _} = Reducer.reduce_cell(cells(ids), level)
    end
    assert {19, _} = Reducer.reduce_cell(cells([19,19,0,0,19,19,0,0]), 1)
    assert {0, _} = Reducer.reduce_cell(cells([19,19,0,0,19,19,0,0]), 2)
  end

  test "every excluded material and every sheet corner is checked after L1 flora filtering" do
    # 冻结自客户端目录语义，不能用被测分类函数生成期望。
    excluded = [20,21,22,44,50,74,87] ++ Enum.to_list(28..39) ++ Enum.to_list(57..73) ++ [19,25,26,27]
    for level <- [1,2], material <- excluded, corner <- [0,1,4,5] do
      ids = List.replace_at([1,1,0,0,1,1,0,0],corner,material)
      assert {0, _} = Reducer.reduce_cell(cells(ids),level)
      expected = if level == 1 and material in [19,25,26,27,57,59,61,63], do: material, else: 0
      assert {^expected, _} = Reducer.reduce_cell(cells([material,material,0,0,material,material,0,0]),level)
    end
    {1, skins} = Reducer.reduce_cell(cells([1,1,32,32,1,1,32,32]),1)
    for face <- 0..5, i <- 0..1, j <- 0..1, do: assert(Reducer.texel(skins,face,i,j) in [0,1])
    {1, upper_skins} = Reducer.reduce_cell(cells([1,1,32,32,1,1,32,32]),2)
    assert Reducer.texel(upper_skins,3,0,0) == 32
    {1, skins} = Reducer.reduce_cell(cells([0,0,1,1,0,0,1,1]),1)
    for face <- [2,3], i <- 0..1, j <- 0..1, do: assert(Reducer.texel(skins,face,i,j) == 1)
    # 不从 skins 推导主体。
    assert {0, _} = Reducer.reduce_cell(List.duplicate({0,Skins.uniform(1)},8),1)
  end

  test "World edits preserve the 16 square metre sheet recursively at all phases and negative XYZ" do
    # 既有空气来源替身只替代 baseline；正式 World 编辑、归约、payload、文件恢复均为真实实现。
    for {x0,y,z0} <- [{12,504,0},{12,505,0},{12,506,0},{12,507,0},{-4,-3,-4}] do
      root = Path.join(System.tmp_dir!(), "f2b_#{System.pid()}_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      opts = [root: root, source: TestSupport.Source, observer: self(), log: VoxelRegion.OverlayLog.File, name: nil]
      world = start_supervised!({World,opts})
      edits = for z <- z0..(z0+3), x <- x0..(x0+3), do: {{x,y,z},1}
      assert {:ok,1} = World.apply_edits(world,edits)
      for level <- [0,1,2] do
        scale = Bitwise.bsl(1,level)
        {px,py,pz} = {Integer.floor_div(x0,scale),Integer.floor_div(y,scale),Integer.floor_div(z0,scale)}
        region = {Integer.floor_div(px,64),Integer.floor_div(py,64),Integer.floor_div(pz,64)}
        p = TestSupport.payload(world,level,region)
        side = div(4,scale)
        for z <- pz..(pz+side-1), x <- px..(px+side-1) do
          assert Payload.material(p,Payload.local(region,{x,py,z})) == 1
          for dy <- [-1,1], do: assert(Payload.material(p,Payload.local(region,{x,py+dy,z})) == 0)
        end
        assert side*side*scale*scale == 16
      end
      before = for level <- 0..2 do
        scale = 64*Bitwise.bsl(1,level)
        region = {Integer.floor_div(x0,scale),Integer.floor_div(y,scale),Integer.floor_div(z0,scale)}
        {level,region,TestSupport.payload(world,level,region)}
      end
      stop_supervised!(World)
      recovered = start_supervised!({World,opts})
      for {level,region,p} <- before, do: assert(TestSupport.payload(recovered,level,region) == p)
      stop_supervised!(World)
    end
  end
end
