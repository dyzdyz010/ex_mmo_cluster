defmodule VoxelRegion.PrefabPreviewTest do
  @moduledoc "只测试：冲突草稿可查看，但预览不得改变发布规则或绕过运行时预算。"
  use ExUnit.Case, async: true
  alias VoxelRegion.Prefab

  defp definition(fields), do: Map.merge(%{cells: [],macro_cells: [],children: [],attachments: []},Map.new(fields))
  defp child(id,slot,anchor \\ {0,0,0}), do: %{definition_id: id,slot: slot,anchor: anchor,orientation: 0}
  defp leaf(fields) do
    {:ok,id,compiled}=Prefab.compile(Prefab.encode(definition(fields)),%{})
    {id,compiled}
  end
  defp cells(geometry,field), do: Enum.flat_map(geometry.nodes,&:erlang.binary_to_term(Map.fetch!(&1,field),[:safe]))

  test "repeated micro references retain both occurrences and report the one duplicate coordinate" do
    {id,leaf}=leaf(cells: [{{-1,2,3},19}])
    bytes=Prefab.encode(definition(children: [child(id,0),child(id,1),child(id,2,{1,0,0})]))
    catalog=%{id=>leaf}
    assert {:error,:overlapping_definition}=Prefab.compile(bytes,catalog)
    assert {:ok,_,geometry,diagnostics}=Prefab.preview(bytes,catalog)
    assert diagnostics==%{publishable: false,error: :overlapping_definition,
      overlaps: %{micro_cells: [{-1,2,3}],macro_cells: [],macro_micro: []}}
    assert cells(geometry,:cells)==[{{-1,2,3},19},{{-1,2,3},19},{{0,2,3},19}]
    assert geometry.summary.micro_cells==3
    assert geometry.summary.nodes==4
  end

  test "macro duplicate and macro micro collision use transformed coordinates across nodes" do
    {id,leaf}=leaf(macro_cells: [{{-1,0,0},11}])
    bytes=Prefab.encode(definition(cells: [{{7,7,7},19}],macro_cells: [{{0,0,0},11}],
      children: [child(id,0,{8,0,0})]))
    assert {:error,:overlapping_definition}=Prefab.compile(bytes,%{id=>leaf})
    assert {:ok,_,geometry,diagnostics}=Prefab.preview(bytes,%{id=>leaf})
    assert diagnostics==%{publishable: false,error: :overlapping_definition,
      overlaps: %{micro_cells: [],macro_cells: [{0,0,0}],macro_micro: [{0,0,0}]}}
    assert cells(geometry,:macro_cells)==[{{0,0,0},11},{{0,0,0},11}]
    assert cells(geometry,:cells)==[{{7,7,7},19}]
  end

  test "macro micro collision floors negative micro coordinates and deduplicates diagnostics" do
    bytes=Prefab.encode(definition(cells: [{{-8,0,0},19},{{-1,7,7},19}],macro_cells: [{{-1,0,0},11}]))
    assert {:error,:overlapping_definition}=Prefab.compile(bytes,%{})
    assert {:ok,_,_,%{overlaps: %{macro_micro: [{-1,0,0}],micro_cells: [],macro_cells: []}}}=Prefab.preview(bytes,%{})
  end

  test "valid tree preview geometry exactly matches the unchanged compile artifact" do
    {id,leaf}=leaf(cells: [{{0,0,0},19}])
    bytes=Prefab.encode(definition(macro_cells: [{{-1,0,0},11}],children: [child(id,0,{8,0,0})]))
    assert {:ok,compiled_id,compiled}=Prefab.compile(bytes,%{id=>leaf})
    assert {:ok,^compiled_id,^compiled,%{publishable: true,error: nil,
      overlaps: %{micro_cells: [],macro_cells: [],macro_micro: []}}}=Prefab.preview(bytes,%{id=>leaf})
  end

  test "unsupported and overlapping attachments remain visible and retain publish rejection" do
    face=%{slot: 0,kind: 0,axis: 1,anchor: {0,1,0},size: 1,material: 19}
    for {definition,error}<- [{definition(attachments: [face]),:unsupported_attachment},
      {definition(cells: [{{0,0,0},11}],attachments: [face,%{face|slot: 1}]),:overlapping_attachments}] do
      bytes=Prefab.encode(definition)
      assert {:error,^error}=Prefab.compile(bytes,%{})
      assert {:ok,_,geometry,%{publishable: false,error: ^error}}=Prefab.preview(bytes,%{})
      assert length(hd(geometry.nodes).attachments)==length(definition.attachments)
    end
  end

  test "invalid encoding missing references and macro alignment still reject preview" do
    {id,leaf}=leaf(macro_cells: [{{0,0,0},11}])
    for {bytes,catalog,error}<- [{<<1>>, %{},:invalid_definition},
      {Prefab.encode(definition(children: [child(<<0::256>>,0)])),%{},:definition_not_found},
      {Prefab.encode(definition(children: [child(id,0,{1,0,0})])),%{id=>leaf},:misaligned}] do
      assert {:error,^error}=Prefab.preview(bytes,catalog)
      assert {:error,^error}=Prefab.compile(bytes,catalog)
    end
  end

  test "preview rejects bytes cell counts nodes and span before giving an artifact" do
    {id,leaf}=leaf(cells: [{{0,0,0},19}])
    for {bytes,error}<- [
      {:binary.copy(<<0>>,Prefab.limits().bytes+1),:definition_bytes_limit},
      {Prefab.encode(definition(macro_cells: for(n<-0..512,do: {{rem(n,16),rem(div(n,16),16),div(n,256)},11}))),:macro_cell_limit},
      {Prefab.encode(definition(cells: for(n<-0..8192,do: {{rem(n,128),div(n,128),0},11}))),:micro_cell_limit},
      {Prefab.encode(definition(children: for(n<-0..63,do: child(id,n)))),:node_limit},
      {Prefab.encode(definition(cells: [{{0,0,0},11},{{128,0,0},11}])),:bounds_limit}] do
      assert {:error,^error}=Prefab.preview(bytes,%{id=>leaf})
      assert {:error,^error}=Prefab.compile(bytes,%{id=>leaf})
    end
  end

  test "shared reference expansion counts towards macro budget and depth" do
    {id,leaf}=leaf(macro_cells: for(x<-0..7,y<-0..7,z<-0..3,do: {{x,y,z},11}))
    bytes=Prefab.encode(definition(children: for(n<-0..2,do: child(id,n))))
    assert {:error,:macro_cell_limit}=Prefab.preview(bytes,%{id=>leaf})
    {id,catalog}=Enum.reduce(2..8,{id,%{id=>leaf}},fn _,{id,catalog}->
      {:ok,next,compiled}=Prefab.compile(Prefab.encode(definition(children: [child(id,0)])),catalog)
      {next,Map.put(catalog,next,compiled)}
    end)
    bytes=Prefab.encode(definition(children: [child(id,0)]))
    assert {:error,:depth_limit}=Prefab.preview(bytes,catalog)
    assert {:error,:depth_limit}=Prefab.compile(bytes,catalog)
  end
end
