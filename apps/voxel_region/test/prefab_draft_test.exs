defmodule VoxelRegion.PrefabDraftTest do
  @moduledoc "只测试：草稿编辑的手算几何与内容寻址。"
  use ExUnit.Case, async: true
  alias VoxelRegion.Prefab.Draft

  test "walls have no floor or ceiling and ordered edits leave a two-high doorway" do
    assert {:ok, draft} = Draft.edit(Draft.new(), [
      %{"op" => "walls", "min" => [0,0,0], "max" => [3,2,3], "material" => 11},
      %{"op" => "fill", "min" => [0,3,0], "max" => [3,3,3], "material" => 19},
      %{"op" => "clear", "min" => [1,0,0], "max" => [1,1,0]}
    ])
    # 四面墙 12×3，扣门 2；屋顶 4×4；室内没有地板或额外天花板。
    assert Enum.frequencies_by(draft.macro_cells, &elem(&1,1)) == %{11 => 34, 19 => 16}
    cells = Map.new(draft.macro_cells)
    for y <- 0..2, do: refute(Map.has_key?(cells,{1,y,1}))
    refute Map.has_key?(cells,{1,0,0})
    assert draft.cells == [] and draft.children == [] and draft.attachments == []
    assert {:ok, empty} = Draft.edit(draft,[%{"op"=>"clear","min"=>[0,0,0],"max"=>[3,3,3]}])
    assert empty == Draft.new()
  end

  test "component slots upsert and remove without flattening catalog geometry" do
    id = String.duplicate("12",32)
    op = %{"op"=>"prefab","slot"=>3,"id"=>id,"anchor_micro"=>[8,0,-8],"orientation"=>1}
    assert {:ok, d} = Draft.edit(Draft.new(),[op])
    assert [%{slot: 3, definition_id: binary, anchor: {8,0,-8},orientation: 1}] = d.children
    assert binary == :binary.copy(<<0x12>>,32)
    assert {:ok, moved} = Draft.edit(d,[%{op|"anchor_micro"=>[16,0,0],"orientation"=>2}])
    assert length(moved.children) == 1
    assert hd(moved.children).anchor == {16,0,0}
    assert {:ok, d} = Draft.edit(moved,[%{"op"=>"remove_prefab","slot"=>3}])
    assert d == Draft.new()
    assert {:error,:component_not_found} = Draft.edit(d,[%{"op"=>"remove_prefab","slot"=>3}])
  end

  test "edits are atomic, bounded and canonical; invalid material and fractional coordinates reject" do
    d = Draft.new()
    fill = %{"op"=>"fill","min"=>[0,0,0],"max"=>[0,0,0],"material"=>11}
    assert {:error,:invalid_edit} = Draft.edit(d,[fill,%{"op"=>"explode"}])
    assert {:error,:invalid_edit} = Draft.edit(d,[%{fill|"max"=>[100,100,100]}])
    assert {:error,:invalid_edit} = Draft.edit(d,[%{fill|"min"=>[0.5,0,0]}])
    assert {:error,:invalid_edit} = Draft.edit(d,[%{fill|"material"=>65535}])
    assert d == %{cells: [],macro_cells: [],children: [],attachments: []}
    a = %{"op"=>"micro","cell"=>[2,0,0],"material"=>11}
    b = %{"op"=>"micro","cell"=>[1,0,0],"material"=>19}
    assert {:ok,d1} = Draft.edit(d,[a,b])
    assert {:ok,d2} = Draft.edit(d,[b,a])
    assert d1 == d2
    assert {:ok, deleted} = Draft.edit(d1,[%{a|"material"=>0}])
    assert deleted.cells == [{{1,0,0},19}]
  end
end
