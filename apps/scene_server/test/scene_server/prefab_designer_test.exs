Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule SceneServer.PrefabDesignerTest do
  @moduledoc "只测试：真实 World/Scene 的读取边界；source/actor/clock 夹具仅替代外围运行环境。"
  use ExUnit.Case, async: false
  alias SceneServer.{PrefabDesigner,Movement.Scene}
  alias VoxelRegion.{World,Prefab}
  alias VoxelRegion.TestSupport.{Source,Actor}

  defmodule Clock do
    def now(_), do: 0
    def schedule(_,_,_), do: :ok
  end

  defmodule ReadBoundary do
    @moduledoc "只测试：转发全部请求到真实 World，在 snapshot 与 payload 读取之间执行正常移除意图。"
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__,state)
    def init(state), do: {:ok,state}
    def handle_call({:material_snapshot,_,_}=request,_,state) do
      snapshot = GenServer.call(state.world,request)
      assert_result = World.prefab_intent(state.world,state.actor,:voxel_prefab_remove_v1,
        %{instance_id: state.instance,client_intent_seq: 2})
      {:ok,_} = assert_result
      {:reply,snapshot,state}
    end
    def handle_call(request,_,state), do: {:reply,GenServer.call(state.world,request,300_000),state}
  end

  setup do
    root = Path.join(System.tmp_dir!(),"prefab_designer_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root,"prefabs"))
    catalog = Path.join(root,"properties.json")
    File.write!(catalog,Jason.encode!(%{schema_version: 1,tags: [%{id: "damage"}],
      materials: for(m<-0..23,do: %{material_id: m,max_hp_per_macro: if(m==0,do: 0,else: 100),
        defense: 2,tags: [],responses: [%{action: "damage",multiplier: 1}]}),
      tools: [%{id: "pick",tool_id: 1,action: "damage",power: 30,range_macro: 8,interval_seconds: 0.5}],definitions: []}))
    world = start_supervised!({World,[source: Source,root: root,observer: self(),name: nil,
      property_catalog_path: catalog,prefab_catalog_path: Path.join(root,"prefabs"),production_materials: [11,19]]})
    fixture = Path.expand("../../../../../Voxim/Docs/M0/fixtures/suite.json",__DIR__)
    profile = Jason.decode!(File.read!(fixture))["profile"] |> Map.put("fixed_hz",60)
    config = %{"schema"=>"voxim-m1-demo-v1","profile"=>profile,
      "l0_min"=>[0,0,0],"l0_max_exclusive"=>[1,1,1],
      "travel_min_m"=>[0.5,0.5,0.5],"travel_max_exclusive_m"=>[63.0,63.0,63.0],
      "spawn_probes_m"=>[[2.5,4.0,2.5]],"spawn_min_y_m"=>0.5}
    scene = start_supervised!({Scene,[scene_id: 1,scene_epoch: 1,world_ref: world,config: config,clock: {Clock,nil}]})
    actor = %{cid: 1001,gate: self(),identity: :designer,refresh: &Actor.tool_context/2,
      eye: {1.0625,1.0625,0.0625},tick_us: 16_667}
    actor = Map.put(actor,:player,start_supervised!({Actor,actor}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world,scene: scene,actor: actor,root: root,profile: profile}
  end

  defp draft(macros,micro \\ []),do: %{macro_cells: macros,cells: micro,children: [],attachments: []}
  defp options(extra \\ []),do: Keyword.merge([entry: {8,8,8},inside: {16,8,16},ground_y: 8,
    interiors: [%{name: "room",floor_y: 8,min: {8,8},max: {24,24}}]],extra)

  @tag :prefab_designer
  test "scene design context exposes actual profile and spawn configuration only", c do
    context = Scene.design_context(c.scene)
    assert Map.keys(context) |> Enum.sort() == [:probes,:profile,:spawn_min_y]
    assert context.profile.radius == c.profile["radius"]
    assert context.profile.half_height == c.profile["half_height"]
    assert context.probes == [{2.5,4.0,2.5}] and context.spawn_min_y == 0.5
  end

  @tag :prefab_designer
  test "check reports real occupied material and balance shortage without publishing or editing", c do
    assert {:ok,_} = World.apply_edit(c.world,{1,1,2},19)
    assert {:ok,_} = World.material_supply(c.world,1001,"designer-budget",%{11=>511})
    before = World.seq(c.world)
    assert {:ok,report} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([{{1,1,2},11}]),options())
    assert report.world_seq == before
    assert [%{cell: {1,1,2},reason: :occupied,material: 19}] = report.placement.conflicts
    assert report.materials.units == %{11=>512}
    assert report.materials.balances == %{11=>511}
    assert report.materials.shortages == %{11=>1}
    refute report.materials.affordable
    assert World.seq(c.world) == before
    assert World.stats(c.world).instances == 0
  end

  @tag :prefab_designer
  test "refined coexistence checks actual slots and macro placement reports the refined conflict", c do
    bytes = <<"VXPD",1::32-little,1::32-little,0::signed-little-32,0::signed-little-32,
      0::signed-little-32,19::16-little,0::32-little>>
    File.write!(Path.join([c.root,"prefabs","existing.vxpd"]),bytes)
    assert :ok = World.publish_prefabs(c.world,Path.join(c.root,"prefabs"))
    assert {:ok,_} = World.place_prefab(c.world,:crypto.hash(:sha256,bytes),{9,8,16},0)
    assert {:ok,free} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([],[{{8,8,16},11}]),options())
    assert free.placement.conflicts == []
    assert {:ok,occupied} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([],[{{9,8,16},11}]),options())
    assert [%{cell: {1,1,2},reason: :occupied_micro,slots: [1]}] = occupied.placement.conflicts
    assert {:ok,macro} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([{{1,1,2},11}]),options())
    assert [%{cell: {1,1,2},reason: :refined}] = macro.placement.conflicts
  end

  @tag :prefab_designer
  test "publication stays distinct from placement and spawn/provenance are diagnostics", c do
    design = draft([{{2,1,2},11}])
    assert {:ok,id} = PrefabDesigner.publish(c.world,c.actor,design)
    assert id == :crypto.hash(:sha256,Prefab.encode(design))
    assert World.seq(c.world) == 0 and World.stats(c.world).instances == 0
    assert {:ok,_} = World.material_supply(c.world,1001,"designer-place",%{11=>512})
    assert {:ok,_} = World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {0,0,0},orientation: 0,client_intent_seq: 1})
    assert {:ok,report} = PrefabDesigner.check(c.world,c.scene,c.actor,design,options())
    assert [%{placed_by: 1001,cell: {2,1,2}}] = report.placement.conflicts
    assert [%{probe: {2.5,4.0,2.5},status: :affected}] = report.placement.spawn_probes
    assert {:ok,[{2,1,2}]} = World.instance_cells(c.world,{World.seq(c.world),0})
  end

  @tag :prefab_designer
  @tag :world_geometry_bounds
  test "placement rotation uses world XYZ and distant explicit rooms reject before sampling", c do
    assert {:ok,_} = World.apply_edit(c.world,{2,1,3},19)
    assert {:ok,report} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([{{0,0,0},11}]),
      options(anchor: {24,8,24},orientation: 1))
    assert [%{cell: {2,1,3},reason: :occupied}] = report.placement.conflicts
    # 旋转 1 将 [0,8)³ 变成 X[-8,0)、Y[0,8)、Z[0,8)，再加锚点。
    assert report.geometry_bounds == {{16,8,24},{24,16,32}}
    before = World.seq(c.world)
    assert {:error,:check_budget} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([{{0,0,0},11}]),
      options(inside: {100_000,8,8}))
    assert World.seq(c.world) == before
    assert {:error,:missing_check_points} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([{{0,0,0},11}]),[])
    assert {:error,:misaligned} = PrefabDesigner.check(c.world,c.scene,c.actor,draft([{{0,0,0},11}]),options(anchor: {1,0,0}))
  end

  @tag :prefab_designer
  test "explicit rooms reject empty and reversed ranges and fractional floors", c do
    for room <- [%{name: "zero",floor_y: 8,min: {8,8},max: {8,16}},
                 %{name: "reverse",floor_y: 8,min: {8,16},max: {16,8}},
                 %{name: "fraction",floor_y: 8.5,min: {8,8},max: {16,16}}] do
      assert {:error,:invalid_interior} = PrefabDesigner.check(c.world,c.scene,c.actor,
        draft([{{0,0,0},11}]),options(interiors: [room]))
    end
  end

  @tag :prefab_designer
  test "opposite free support micro still reports the occupied attachment slot", c do
    attachment = %{slot: 0,kind: 0,axis: 0,anchor: {9,8,16},size: 1,material: 19}
    old = Map.put(draft([],[{{8,8,16},11}]),:attachments,[attachment])
    assert {:ok,id} = PrefabDesigner.publish(c.world,c.actor,old)
    assert {:ok,_} = World.place_prefab(c.world,id,{0,0,0},0)
    fresh = Map.put(draft([],[{{9,8,16},11}]),:attachments,[attachment])
    assert {:ok,report} = PrefabDesigner.check(c.world,c.scene,c.actor,fresh,options())
    assert [%{reason: :occupied_attachment,slot: {0,0,{9,8,16}}}] = report.placement.conflicts
    assert report.materials.units == %{11=>1,19=>1}
  end

  @tag :prefab_designer
  test "a real removal between snapshot and payload returns world_changed", c do
    design = draft([],[{{8,8,16},11}])
    assert {:ok,id} = PrefabDesigner.publish(c.world,c.actor,design)
    assert {:ok,_} = World.material_supply(c.world,1001,"read-boundary",%{11=>1})
    assert {:ok,_} = World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {0,0,0},orientation: 0,client_intent_seq: 1})
    proxy = start_supervised!({ReadBoundary,%{world: c.world,actor: c.actor,instance: {World.seq(c.world),0}}})
    assert {:error,:world_changed} = PrefabDesigner.check(proxy,c.scene,c.actor,design,options())
    assert World.stats(c.world).instances == 0
    assert [%{units: 1}] = World.material_snapshot(c.world,[1001],[]).material_balances
  end
end
