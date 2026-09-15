defmodule VoxelRegion.B3PipelineTest do
  # 只测试：优化的载荷投影与日志恢复保持既有权威语义。
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.Payload
  alias VoxelRegion.{CollisionSource,OverlayLog}
  @moduletag :b3

  test "普通载荷连续行与世界读取器在负坐标、边界及全部材质上逐字节一致" do
    materials=MmoContracts.VoxelMaterialCatalog.table() |> Enum.map(& &1["id"])
    extent=Payload.extent()
    cells=for i<-0..(extent*extent*extent-1),into: <<>>,
      do: <<Enum.at(materials,rem(i,length(materials)))::little-16>>
    payload=%Payload{region: {-2,-1,1},cells: cells}
    for coord<-CollisionSource.chunk_coords(payload.region) do
      expected=CollisionSource.capture(coord,fn cell->
        {Payload.material(payload,Payload.local(payload.region,cell)),%{}}
      end)
      assert CollisionSource.capture(payload,coord)==expected
    end
  end

  test "同一载荷加入细化格后仍按实际微格覆盖宏格阻挡" do
    extent=Payload.extent()
    payload=%Payload{region: {-1,0,0},cells: :binary.copy(<<0::16>>,extent*extent*extent)}
    local=Payload.local(payload.region,{-1,0,0})
    payload=%{payload | refined: %{Payload.cell_index(local)=>%{0=>{11,{1,1}}}}}
    expected=CollisionSource.capture({-1,0,0},fn cell->
      local=Payload.local(payload.region,cell)
      {Payload.material(payload,local),Map.get(payload.refined,Payload.cell_index(local),%{})}
    end)
    assert CollisionSource.capture(payload,{-1,0,0})==expected
    assert expected.n==128
    assert :binary.at(expected.cells,120)==1
  end

  test "既有与压缩 ETF 元数据可混合重放且保留双精度及源身份" do
    states=for i<-1..300,do: %{micro: {i,4096,496},hp: 21.93819605336002,
      temperature_kelvin: 293.1599879087646,incarnation: 3354,owner: {0,0}}
    metadata=%{property_states: states,epochs: %{{41,512,62}=>3354},
      material_balances: %{{1001,19}=>512},thermal: %{sources: %{{41,512,62}=>%{remaining_j: 0.001}},elapsed_s: 0.05}}
    txn=Map.merge(%{seq: 42,entries: [],coarse: []},metadata)
    [compressed]=OverlayLog.rows(txn)
    old=%{compressed | seq: 41,payload: :erlang.term_to_binary(metadata)}
    assert byte_size(compressed.payload)<byte_size(old.payload)
    assert [Map.put(txn,:seq,41),txn]==OverlayLog.transactions([old,compressed])
    assert :erlang.binary_to_term(compressed.payload,[:safe])==metadata
  end
end
