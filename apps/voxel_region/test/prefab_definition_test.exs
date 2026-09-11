defmodule VoxelRegion.PrefabDefinitionTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.Prefab

  test "publication rejects cycles, missing references and actual child overlap" do
    leaf = %{cells: [{{0,0,0},11}],children: []}
    ref = %{definition_id: :leaf,slot: 2,anchor: {0,0,0},orientation: 0}
    root = %{cells: [],children: [ref]}
    assert {:error,:definition_not_found} = Prefab.publish(%{root: root})
    assert {:error,:definition_cycle} = Prefab.publish(%{leaf: %{root | children: [%{ref | definition_id: :leaf}]}})
    assert {:error,:overlapping_definition} = Prefab.publish(%{leaf: leaf,root: %{root | children: [ref,%{ref | slot: 7}]}})
    assert {:ok,_} = Prefab.publish(%{leaf: leaf,root: %{root | children: [ref,%{ref | slot: 7,anchor: {1,0,0}}]}})
  end

  test "all composed rotations transform child anchors as points and cells as volumes" do
    leaf = %{cells: [{{-2,1,3},11},{{0,0,0},19}],children: []}
    for parent <- 0..23, child <- 0..23 do
      reference = %{definition_id: :leaf,slot: 7,anchor: {-5,8,13},orientation: child}
      assert {:ok,catalog} = Prefab.publish(%{leaf: leaf,root: %{cells: [],children: [reference]}})
      anchor = {-127,-1,127}
      [{_,_,[]},{_,node,cells}] = Prefab.occurrences(catalog.root,anchor,parent,9)
      assert node.anchor == Prefab.point(reference.anchor,anchor,parent)
      assert node.orientation == Prefab.compose(parent,child)
      assert cells == Prefab.footprint(leaf,node.anchor,node.orientation)
      assert cells == Prefab.footprint(catalog.root,anchor,parent)
    end
  end
end
