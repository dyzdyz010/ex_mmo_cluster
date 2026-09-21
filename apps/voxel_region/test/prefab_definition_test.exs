defmodule VoxelRegion.PrefabDefinitionTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.Prefab

  # 只测试：纯定义契约，不启动 World，不覆盖持久化、网络或渲染。
  test "v3 adds macro cells after the v2 attachment segment without changing v1 or v2" do
    cell = <<0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little>>
    v1 = <<"VXPD", 1::32-little, 1::32-little, cell::binary, 0::32-little>>
    v2 = <<"VXPD", 2::32-little, 1::32-little, cell::binary, 0::32-little, 0::32-little>>
    macro = <<-1::signed-little-32, 2::signed-little-32, -3::signed-little-32, 19::16-little>>
    v3 = <<"VXPD", 3::32-little, 1::32-little, cell::binary, 0::32-little,
      0::32-little, 1::32-little, macro::binary>>
    for bytes <- [v1, v2] do
      assert {:ok, %{cells: [{{0,0,0},11}], macro_cells: [], children: [], attachments: []}} = Prefab.decode(bytes)
    end
    assert {:ok, %{cells: [{{0,0,0},11}], macro_cells: [{{-1,2,-3},19}]}} = Prefab.decode(v3)
    assert {:ok, %{macro_cells: [{{-1,2,-3},19}]}} =
      Prefab.decode(<<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little, 1::32-little, macro::binary>>)
    assert {:error, :invalid_definition} = Prefab.decode(binary_part(v3, 0, byte_size(v3)-1))
    assert {:error, :invalid_definition} = Prefab.decode(v3 <> <<0>>)
    assert {:error, :invalid_definition} =
      Prefab.decode(<<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little, 2::32-little, macro::binary, macro::binary>>)
    assert {:error, :invalid_definition} =
      Prefab.decode(<<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little, 1::32-little, 0::96, 0::16>>)
    attachment = <<7::32-little, 0, 1, 0::signed-little-32, 1::signed-little-32, 0::signed-little-32, 1, 19::16-little>>
    for version <- [2,3] do
      suffix = if version == 3, do: <<1::32-little, macro::binary>>, else: <<>>
      assert {:ok, %{attachments: [%{slot: 7, kind: 0, axis: 1, anchor: {0,1,0}, size: 1, material: 19}]}} =
        Prefab.decode(<<"VXPD", version::32-little, 1::32-little, cell::binary, 0::32-little,
          1::32-little, attachment::binary, suffix::binary>>)
    end
  end

  test "negative macro occupancy rejects contained micro but permits its adjacent cell" do
    definition = %{cells: [{{-1,7,-8},11}], macro_cells: [{{-1,0,-1},19}], children: []}
    assert {:error, :overlapping_definition} = Prefab.publish(%{root: definition})
    assert {:ok, catalog} = Prefab.publish(%{root: %{definition | cells: [{{0,7,-8},11}]}})
    assert catalog.root.has_macro_cells
    assert Prefab.footprint(catalog.root, {0,0,0}, 0) == [{{0,7,-8},11}]
    assert Prefab.macro_footprint(catalog.root, {0,0,0}, 0) == [{{-1,0,-1},19}]
  end

  test "publication rejects macro collisions across nodes and mixed precision children" do
    leaf = %{cells: [], macro_cells: [{{0,0,0},11}], children: []}
    ref = %{definition_id: :leaf, slot: 1, anchor: {0,0,0}, orientation: 0}
    root = %{cells: [], macro_cells: [{{0,0,0},19}], children: [ref]}
    assert {:error, :overlapping_definition} = Prefab.publish(%{root: root, leaf: leaf})
    assert {:error, :overlapping_definition} = Prefab.publish(%{root: %{root | cells: [{{7,7,7},19}], macro_cells: []}, leaf: leaf})
    assert {:ok, _} = Prefab.publish(%{root: %{root | children: [%{ref | anchor: {8,0,0}}]}, leaf: leaf})
  end

  test "alignment includes macro grandchildren even when the child has no own macro cells" do
    leaf = %{cells: [], macro_cells: [{{0,0,0},11}], children: []}
    ref = %{definition_id: :leaf, slot: 1, anchor: {0,0,0}, orientation: 0}
    middle = %{cells: [], children: [ref]}
    for anchor <- [{1,0,0}, {0,-1,0}, {0,0,7}] do
      root = %{cells: [], children: [%{ref | definition_id: :middle, anchor: anchor}]}
      assert {:error, :misaligned} = Prefab.publish(%{root: root, middle: middle, leaf: leaf})
    end
    root = %{cells: [], children: [%{ref | definition_id: :middle, anchor: {-8,16,-24}}]}
    assert {:ok, catalog} = Prefab.publish(%{root: root, middle: middle, leaf: leaf})
    assert catalog.root.has_macro_cells
    assert Prefab.macro_footprint(catalog.root, {0,0,0}, 0) == [{{-1,2,-3},11}]
    assert {:ok, old} = Prefab.publish(%{root: %{cells: [{{1,0,0},11}], children: []}})
    refute old.root.has_macro_cells
    assert Prefab.macro_footprint(old.root, {1,0,0}, 0) == []
  end

  test "all 24 macro rotations preserve volume corners at negative world coordinates" do
    definition = %{cells: [], macro_cells: [{{-2,1,3},11}], children: []}
    assert {:ok, catalog} = Prefab.publish(%{root: definition})
    # 手算 [-2,-1] × [1,2] × [3,4] 的 24 种带符号轴置换。
    rotated = [{-2,1,3},{-4,1,-2},{1,1,-4},{3,1,1},
      {-2,-2,-4},{-4,-2,1},{1,-2,3},{3,-2,-2},
      {1,1,3},{1,3,-2},{1,-2,-4},{1,-4,1},
      {-2,-2,3},{-2,-4,-2},{-2,1,-4},{-2,3,1},
      {-2,-4,1},{-4,1,1},{1,3,1},{3,-2,1},
      {-2,3,-2},{-4,-2,-2},{1,-4,-2},{3,1,-2}]
    for {{x,y,z}, orientation} <- Enum.with_index(rotated) do
      assert Prefab.macro_footprint(catalog.root, {-128,-8,128}, orientation) == [{{x-16,y-1,z+16},11}]
    end
  end

  test "macro occurrences share preorder identities and apply child and placement transforms once" do
    leaf = %{cells: [{{16,0,0},19}], macro_cells: [{{-2,1,3},11}], children: []}
    root = %{cells: [], children: [%{definition_id: :leaf, slot: 7, anchor: {-8,16,24}, orientation: 1}]}
    assert {:ok, catalog} = Prefab.publish(%{root: root, leaf: leaf})
    [{root_id, root_metadata, []}, {leaf_id, metadata, cells}] =
      Prefab.macro_occurrences(catalog.root, {-128,-8,128}, 1, 9, {3,2}, 5)
    assert root_id == {9,0}
    assert root_metadata.parent_id == {3,2}
    assert root_metadata.component_slot == 5
    assert leaf_id == {9,1}
    assert metadata == %{definition_id: :leaf, anchor: {-152,8,120}, orientation: 2, parent_id: {9,0}, component_slot: 7}
    assert cells == [{{-18,2,11},11}]
    assert [{^root_id, ^root_metadata, []}, {^leaf_id, ^metadata, [{{-169,8,119},19}]}] =
      Prefab.occurrences(catalog.root, {-128,-8,128}, 1, 9, {3,2}, 5)
    assert is_binary(hd(catalog.root.nodes).macro_cells)
  end

  test "initial attachments accept macro support without expanding it to micro cells" do
    attachment = %{slot: 1, kind: 0, axis: 1, anchor: {0,8,0}, size: 8, material: 11}
    definition = %{cells: [], macro_cells: [{{0,0,0},19}], children: [], attachments: [attachment]}
    assert {:ok, catalog} = Prefab.publish(%{root: definition})
    assert Prefab.footprint(catalog.root, {0,0,0}, 0) == []
    assert [%{owner: {4,0}, slots: slots}] = Prefab.attachments(catalog.root, {0,0,0}, 0, 4)
    assert length(slots) == 64
    unsupported = %{definition | attachments: [%{attachment | anchor: {8,8,0}}]}
    assert {:error, :unsupported_attachment} = Prefab.publish(%{root: unsupported})
  end

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
