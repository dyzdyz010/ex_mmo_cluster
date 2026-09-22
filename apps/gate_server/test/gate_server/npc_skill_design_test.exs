Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.NpcSkillDesignTest do
  @moduledoc "只测试：冻结模型应答验证会话预算与历史；真实 World/Scene 验证设计修复、正式发布和付费放置。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.Skills.Design
  alias SceneServer.Movement.Scene
  alias VoxelRegion.{World, Prefab}
  alias VoxelRegion.TestSupport.{Source, Actor}

  defmodule Clock do
    def now(_), do: 0
    def schedule(_, _, _), do: :ok
  end

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup context do
    import Ecto.Query, only: [from: 2]
    DataService.Repo.delete_all(from m in "npc_memories",where: m.cid == 1001)
    root = Path.join(System.tmp_dir!(), "npc_design_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}],
      materials: for(m <- 0..24, do: %{material_id: m, display_name: "fixture-#{m}", max_hp_per_macro: if(m == 0, do: 0, else: 100),
        defense: 2, tags: [], responses: [%{action: "damage", multiplier: 1}]}),
      tools: [%{id: "pick", tool_id: 1, action: "damage", power: 30, range_macro: 8, interval_seconds: 0.5}], definitions: []}))
    world = start_supervised!({World, [source: Source, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [11]]})
    # 在线检查不再使用模型假设的地面；需要可步行场地的用例一次安装真实作者地面。
    if context[:real_ground] do
      assert {:ok,_} = World.apply_edits(world,for(x <- 8..14,z <- 8..14,do: {{x,0,z},11}))
    end
    fixture = Path.expand("../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
    profile = Jason.decode!(File.read!(fixture))["profile"] |> Map.put("fixed_hz", 60)
    scene = start_supervised!({Scene, [scene_id: 1, scene_epoch: 1, world_ref: world, clock: {Clock,nil},
      config: %{"schema" => "voxim-m1-demo-v1", "profile" => profile,
        "l0_min" => [0,0,0], "l0_max_exclusive" => [1,1,1],
        "travel_min_m" => [0.5,0.5,0.5], "travel_max_exclusive_m" => [63.0,63.0,63.0],
        "spawn_probes_m" => [[30.5,4.0,30.5]], "spawn_min_y_m" => 0.5}]})
    actor = %{cid: 1001, gate: self(), identity: :designer, refresh: &Actor.tool_context/2,
      eye: {10.5,2.0,8.0},position: {10.5,1.4,8.0}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world, scene: scene, actor: actor, endpoint: %{model: "frozen", effort: "low"},
      labels: %{}, budget: %{rounds: 12, tokens: 48_000, max_output_tokens: 4096}}
  end

  defp args, do: %{goal: "A sheltered room with a complete roof", anchor: {80,8,80}, orientation: 0}

  @tag :context_contract
  test "designer receives explicit body dimensions and callable perception and memory", c do
    c = %{c | budget: %{rounds: 1,tokens: 100,max_output_tokens: 30}}
    assert {:error,:round_budget,_} = Design.run(script(c,[answer(1,"view",%{})]),args())
    assert_receive {:model_request,body}
    initial = hd(body.input)["content"] |> Jason.decode!()
    assert initial["self"]["body"]["height_m"] == 1.8
    assert initial["self"]["body"]["radius_m"] == 0.35
    assert initial["self"]["body"]["walk_speed_m_s"] == 8
    for tool <- ["look","inspect","remember","recall","search_memory"],
      do: assert(Enum.any?(body.tools, &(&1.name == tool)))
  end

  @tag :context_contract
  test "designer queries an obstacle outside initial site and receives the real version and exact micro", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"outside-perception",%{11 => 1})
    leaf = %{cells: [{{0,0,0},11}],macro_cells: [],children: [],attachments: []}
    assert {:ok,id} = World.publish_prefab(c.world,c.actor,Prefab.encode(leaf))
    assert {:ok,birth} = World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {76,24,72},orientation: 0,client_intent_seq: 1})
    c = %{c | budget: %{rounds: 3,tokens: 100,max_output_tokens: 30}}
    assert {:error,:round_budget,_} = Design.run(script(c,[
      answer(1,"look",%{x0: 9,y0: 2,z0: 9,x1: 9,y1: 4,z1: 9}),
      answer(2,"look",%{x0: 100,y0: 2,z0: 9,x1: 100,y1: 4,z1: 9}),answer(3,"view",%{})]),args())
    assert_receive {:model_request,first}
    assert Jason.decode!(hd(first.input)["content"])["site"]["bounds_macro"] == [[10,0,10],[26,2,26]]
    assert_receive {:model_request,second}
    result = tool_result(second,"c1")
    assert result["ok"]
    assert result["observation"]["seq"] == World.seq(c.world)
    assert result["observation"]["bounds_macro_inclusive"] == [[9,2,9],[9,4,9]]
    assert result["observation"]["outside"] == "unknown"
    assert [%{"micro_cells" => [%{"micro" => [76,24,72],"material" => 11,"instance" => [^birth,0]}]}] =
      result["observation"]["refined"]
    assert_receive {:model_request,third}
    assert tool_result(third,"c2")["error"] == "invalid_perception_bounds"
  end

  @tag :context_contract
  test "designer automatically retrieves old relevant memory and persists new information for next turn", c do
    store = DataService.NpcMemory
    :ok = store.put(1001,"note","old-roof",%{"text" => "sheltered room roof needs headroom"})
    for n <- 1..7,do: :ok = store.put(1001,"note","unrelated#{n}",%{"text" => "无关#{n}"})
    c = %{c | budget: %{rounds: 4,tokens: 100,max_output_tokens: 30}}
    assert {:error,:round_budget,_} = Design.run(script(c,[
      answer(1,"remember",%{key: "door",text: "西门头顶有横梁，先查净空"}),
      answer(2,"search_memory",%{query: "西门净空"}),answer(3,"recall",%{key: "door"}),answer(4,"view",%{})]),args())
    assert_receive {:model_request,first}
    memories = Jason.decode!(List.last(first.input)["content"])["current_memory"]["memories"]
    assert Enum.any?(memories,&(&1["key"] == "old-roof"))
    assert_receive {:model_request,second}
    memories = Jason.decode!(List.last(second.input)["content"])["current_memory"]["memories"]
    assert Enum.any?(memories,&(&1["key"] == "door"))
    assert_receive {:model_request,third}
    assert [%{"key" => "door"}] = tool_result(third,"c2")["memory"]["data"]["matches"]
    assert_receive {:model_request,fourth}
    assert tool_result(fourth,"c3")["memory"]["data"]["body"]["text"] == "西门头顶有横梁，先查净空"
    assert %{"text" => "西门头顶有横梁，先查净空"} = Task.async(fn -> store.get(1001,"note","door") end) |> Task.await()
  end
  defp answer(id, tool, arguments) do
    %{"output" => [%{"type" => "reasoning", "id" => "r#{id}", "summary" => []},
      %{"type" => "function_call", "call_id" => "c#{id}", "name" => tool, "arguments" => Jason.encode!(arguments)}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}}
  end
  defp script(context, responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    owner = self()
    Map.put(context, :request, fn _, body ->
      send(owner, {:model_request, body})
      Agent.get_and_update(agent, fn [response | rest] -> {{:ok, response}, rest} end)
    end)
  end
  defp roof_ops do
    [%{op: "fill", min: [0,3,0], max: [2,3,2], material: 11},
     %{op: "clear", min: [1,3,1], max: [1,3,1]},
     %{op: "fill", min: [0,0,0], max: [0,2,0], material: 11}]
  end
  defp checks, do: %{entry: [92,8,72], inside: [92,8,92], ground_y: 8,
    interiors: [%{name: "room", floor_y: 8, min: [88,88], max: [96,96]}]}
  defp tool_result(body, call_id) do
    body.input |> Enum.find(&(&1["type"] == "function_call_output" and &1["call_id"] == call_id)) |> Map.fetch!("output") |> Jason.decode!()
  end

  @tag :design_skill
  @tag :real_ground
  test "history preserves reasoning and call ids; a failed roof is repaired before formal publication", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"design-house",%{11 => 12*512})
    before = World.seq(c.world)
    responses = [answer(1,"edit",%{ops: roof_ops()}), answer(2,"view",%{}), answer(3,"check",checks()),
      answer(4,"publish",%{}), answer(5,"edit",%{ops: [%{op: "nonsense"}]}),
      answer(6,"edit",%{ops: [%{op: "fill", min: [1,3,1], max: [1,3,1], material: 11}]}),
      answer(7,"publish",%{}), answer(8,"check",checks()), answer(9,"publish",%{})]
    assert {:ok,result} = Design.run(script(c,responses),args())
    assert result.metrics == %{request_count: 9, rounds: 9, input_tokens: 90, output_tokens: 45,
      total_tokens: 135, failed_checks: 1, usage_complete: true}
    assert result.check.passed
    assert result.check.criteria.floating.observed == result.check.report.floating
    assert result.check.report.floating.macro_cells == []
    assert Enum.all?(result.check.criteria, fn {_, row} -> row.passed end)
    assert result.check.report.materials.units == %{11 => 6144}
    assert result.summary.macro_cells == 12
    assert World.seq(c.world) == before and World.stats(c.world).instances == 0
    assert [%{units: 6144}] = World.material_snapshot(c.world,[1001],[]).material_balances
    requests = for _ <- responses do assert_receive {:model_request,body}; body end
    second = Enum.at(requests,1)
    assert Enum.at(second.input,1) == hd(hd(responses)["output"])
    assert tool_result(second,"c1")["ok"]
    assert (hd(second.input)["content"] |> Jason.decode!())["session_budget"] ==
      %{"rounds" => 12,"tokens" => 48_000,"max_output_tokens" => 4096}
    assert tool_result(second,"c1")["remaining_budget"] == %{"rounds" => 11,"tokens" => 47_985}
    assert tool_result(Enum.at(requests,8),"c8")["remaining_budget"] == %{"rounds" => 4,"tokens" => 47_880}
    assert tool_result(Enum.at(requests,3),"c3")["check"]["criteria"]["roof"]["passed"] == false
    assert tool_result(Enum.at(requests,4),"c4")["error"] == "check_failed"
    assert tool_result(Enum.at(requests,5),"c5")["error"] == "invalid_edit"
    assert tool_result(Enum.at(requests,7),"c7")["error"] == "check_required"
    roof = tool_result(Enum.at(requests,2),"c2")["views"]["layers"] |> List.last()
    assert roof["text"] == "###\n#.#\n###"
    assert {:ok,_} = World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: result.definition_id,anchor: args().anchor,orientation: 0,client_intent_seq: 1})
    assert World.stats(c.world).instances == 1
    assert [%{units: 0}] = World.material_snapshot(c.world,[1001],[]).material_balances
  end

  @tag :design_skill
  test "round and cumulative usage budgets stop exactly without publishing", c do
    context = %{c | budget: %{rounds: 1,tokens: 100,max_output_tokens: 40}}
    assert {:error,:round_budget,m} = Design.run(script(context,[answer(1,"view",%{})]),args())
    assert m.request_count == 1 and m.total_tokens == 15
    assert_receive {:model_request,%{max_output_tokens: 40}}
    context = %{c | budget: %{rounds: 12,tokens: 14,max_output_tokens: 40}}
    assert {:error,:token_budget,m} = Design.run(script(context,[answer(1,"publish",%{})]),args())
    assert m.total_tokens == 15 and m.request_count == 1
    assert_receive {:model_request,%{max_output_tokens: 14}}
    assert World.prefab_catalog(c.world) == %{}
  end

  @tag :design_skill
  test "missing usage, invalid arguments, unknown tools and multiple calls stop explicitly", c do
    response = answer(1,"view",%{})
    cases = [{Map.delete(response,"usage"),:usage_unavailable},
      {put_in(response,["output",Access.at(1),"arguments"],"{bad"),:invalid_tool_arguments},
      {answer(1,"invented",%{}),{:unknown_tool,"invented"}},
      {Map.update!(response,"output", &(&1 ++ [List.last(&1)])),:expected_one_tool}]
    for {reply,reason} <- cases do
      assert {:error,^reason,m} = Design.run(script(c,[reply]),args())
      assert m.request_count == 1
      if reason == :usage_unavailable, do: refute(m.usage_complete)
    end
  end

  @tag :design_skill
  test "catalog labels are caller data; sizes and costs come from the actual published definition", c do
    bytes = Prefab.encode(%{cells: [{{0,0,0},19}],macro_cells: [],children: [],attachments: []})
    assert {:ok,id} = World.publish_prefab(c.world,c.actor,bytes)
    context = %{c | labels: %{Base.encode16(id,case: :lower) => "Wood detail"},budget: %{rounds: 1,tokens: 100,max_output_tokens: 30}}
    assert {:error,:round_budget,_} = Design.run(script(context,[answer(1,"view",%{})]),args())
    assert_receive {:model_request,body}
    initial = hd(body.input)["content"] |> Jason.decode!()
    assert [%{"label" => "Wood detail","size_m" => [0.125,0.125,0.125],"materials" => %{"units" => %{"19" => 1}}}] = initial["catalog"]
  end

  defp rejected_check(context, ops, check, arguments) do
    context = %{context | budget: %{rounds: 3,tokens: 100,max_output_tokens: 30}}
    responses = [answer(1,"edit",%{ops: ops}),answer(2,"check",check),answer(3,"publish",%{})]
    assert {:error,:round_budget,%{failed_checks: 1}} = Design.run(script(context,responses),arguments)
    assert_receive {:model_request,_}
    assert_receive {:model_request,_}
    assert_receive {:model_request,last}
    assert World.prefab_catalog(context.world) == %{}
    tool_result(last,"c2")["check"]
  end

  @tag :design_skill
  @tag :world_ground
  test "a model supplied ground cannot approve an unsupported house in the real World", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"unsupported-house",%{11 => 12*512})
    ops = roof_ops() ++ [%{op: "fill",min: [1,3,1],max: [1,3,1],material: 11}]
    checked = rejected_check(c,ops,checks(),args())
    refute checked["criteria"]["floating"]["passed"]
    refute checked["criteria"]["route"]["passed"]
    assert checked["report"]["scope"] == "draft_with_world"
    assert checked["report"]["floating"]["total_cells"] == 12
    assert World.stats(c.world).instances == 0
    assert [%{units: 6144}] = World.material_snapshot(c.world,[1001],[]).material_balances
  end

  @tag :design_skill
  @tag :real_ground
  test "low roof separately rejects route and headroom despite complete coverage", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"low-roof",%{11 => 12*512})
    ops = [%{op: "fill",min: [0,1,0],max: [2,1,2],material: 11},
      %{op: "fill",min: [0,0,0],max: [0,0,0],material: 11}]
    checked = rejected_check(c,ops,checks(),args())
    refute checked["criteria"]["route"]["passed"]
    refute checked["criteria"]["headroom"]["passed"]
    assert checked["criteria"]["roof"]["passed"]
    assert checked["report"]["headroom"]["inside"]["clear_micro"] == 8
  end

  @tag :design_skill
  @tag :floating_projection
  @tag :real_ground
  test "an unattached roof is rejected as floating even with a walkable covered room", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"floating-roof",%{11 => 12*512})
    checked = rejected_check(c,[%{op: "fill",min: [0,3,0],max: [2,3,2],material: 11}],checks(),args())
    refute checked["criteria"]["floating"]["passed"]
    assert checked["criteria"]["route"]["passed"] and checked["criteria"]["roof"]["passed"]
    floating = checked["report"]["floating"]
    assert floating["total_cells"] == 9
    assert floating["sample_scope"] == "partial_coordinates_not_full_geometry"
    assert floating["bounds_convention"] == "half_open_in_each_cell_resolution"
    assert %{"count" => 9,"bounds" => [[10,4,10],[13,5,13]],"sample" => samples} = floating["macro_cells"]
    assert length(samples) == 4
    assert Enum.all?(samples, fn [x,y,z] -> x in 10..12 and y == 4 and z in 10..12 end)
    assert floating["micro_cells"] == %{"count" => 0,"bounds" => nil,"sample" => []}
    assert Enum.all?(checked["criteria"], fn {_, row} -> not Map.has_key?(row,"observed") end)
    refute checked["passed"]
  end

  @tag :design_skill
  test "actual shortage, occupied macro and scene spawn column all prevent publication", c do
    assert {:ok,_} = World.apply_edit(c.world,{30,1,30},19)
    ops = [%{op: "fill",min: [0,3,0],max: [2,3,2],material: 11},
      %{op: "fill",min: [0,0,0],max: [0,2,0],material: 11}]
    check = %{entry: [252,8,232],inside: [252,8,252],ground_y: 8,
      interiors: [%{name: "room",floor_y: 8,min: [248,248],max: [256,256]}]}
    checked = rejected_check(c,ops,check,%{args() | anchor: {240,8,240}})
    for key <- ["materials","placement","spawn"], do: refute(checked["criteria"][key]["passed"])
    assert checked["report"]["materials"]["shortages"] == %{"11" => 6144}
    assert [%{"cell" => [30,1,30],"material" => 19}] = checked["report"]["placement"]["conflicts"]
  end

  @tag :design_skill
  @tag :outside_entry
  @tag :real_ground
  test "a sealed box cannot pass by putting both route endpoints inside", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"sealed-house",%{11 => 33*512})
    ops = [%{op: "walls",min: [0,0,0],max: [2,2,2],material: 11},
      %{op: "fill",min: [0,3,0],max: [2,3,2],material: 11}]
    checked = rejected_check(c,ops,%{checks() | entry: [91,8,92]},args())
    assert checked["criteria"]["route"]["passed"]
    refute checked["criteria"]["entry"]["passed"]
    assert checked["report"]["geometry_bounds"] == [[80,8,80],[104,40,104]]
    assert checked["reasons"] == ["entry"]
    opened = ops ++ [%{op: "clear",min: [1,0,0],max: [1,1,0]}]
    responses = [answer(1,"edit",%{ops: opened}),answer(2,"check",checks()),answer(3,"publish",%{})]
    assert {:ok,result} = Design.run(script(c,responses),args())
    assert result.check.criteria.entry.passed and result.check.criteria.route.passed
    assert result.summary.macro_cells == 31
  end

  @tag :design_skill
  test "inside must be on a declared room floor and within its half-open footprint", c do
    assert {:ok,_} = World.material_supply(c.world,1001,"inside-room",%{11 => 12*512})
    ops = [%{op: "fill",min: [0,3,0],max: [2,3,2],material: 11},
      %{op: "fill",min: [0,0,0],max: [0,2,0],material: 11}]
    context = %{c | budget: %{rounds: 3,tokens: 100,max_output_tokens: 30}}
    for inside <- [[92,8,112],[92,16,92],[96,8,92]] do
      responses = [answer(1,"edit",%{ops: ops}),answer(2,"check",%{checks() | inside: inside}),answer(3,"publish",%{})]
      assert {:error,:round_budget,%{failed_checks: 1}} = Design.run(script(context,responses),args())
      assert_receive {:model_request,_}
      assert_receive {:model_request,_}
      assert_receive {:model_request,last}
      assert tool_result(last,"c2")["error"] == "inside_outside_interiors"
      assert World.prefab_catalog(c.world) == %{}
    end
  end

  @tag :design_skill
  @tag :empty_initial_draft
  test "the official skill entry provides bounded actual site and material names without injected site", c do
    assert {:ok,_} = World.apply_edit(c.world,{10,0,10},11)
    assert {:ok,_} = World.material_supply(c.world,1001,"site-inventory",%{11 => 1024})
    context = script(c,[answer(1,"view",%{})])
    context = Map.put(context,:profile,%{endpoint: c.endpoint,
      skills: %{design: %{labels: %{},budget: %{rounds: 1,tokens: 100,max_output_tokens: 30}}}})
    assert {:error,:round_budget,_} = GateServer.Npc.Skills.run(context,
      %{skill: :design,args: %{"goal" => args().goal,"anchor_micro" => [80,8,80],"orientation" => 0}})
    assert_receive {:model_request,body}
    initial = hd(body.input)["content"] |> Jason.decode!()
    assert initial["draft"] == %{"macro_cells" => 0,"micro_cells" => 0,"child_slots" => []}
    assert Enum.take(initial["orientations"]["rows"],2) ==
      [[0,[1,0,0],[0,1,0],[0,0,1]],[1,[0,0,1],[0,1,0],[-1,0,0]]]
    assert initial["site"]["bounds_macro"] == [[10,0,10],[26,2,26]]
    assert initial["site"]["sampled_cells"] == 512
    assert initial["site"]["world_seq"] == World.seq(c.world)
    assert initial["site"]["attachments"] == "not_sampled"
    lower = hd(initial["site"]["layers"])
    assert lower["normal"] == [[10,10,11,nil]]
    assert List.last(initial["site"]["layers"])["uniform"]["material"] == 0
    assert [%{"material" => 11,"units" => 1024}] = initial["site"]["material_balances"]
    assert Enum.find(initial["materials"], &(&1["id"] == 11))["name"] == "fixture-11"
    refute Map.has_key?(initial["site"],"ground_y")
  end

  @tag :compact_site
  test "mixed site rows losslessly preserve natural, placed, refined and air facts", c do
    assert {:ok,1} = World.apply_edits(c.world,[{{10,0,10},11},{{12,0,10},19}])
    assert {:ok,_} = World.material_supply(c.world,1001,"mixed-site",%{11 => 1025})
    definition = %{macro_cells: [{{0,0,0},11}],cells: [{{8,0,0},11}],children: [],attachments: []}
    assert {:ok,id} = World.publish_prefab(c.world,c.actor,Prefab.encode(definition))
    assert {:ok,3} = World.prefab_intent(c.world,c.actor,:voxel_prefab_place_v1,
      %{definition_id: id,anchor: {80,8,80},orientation: 0,client_intent_seq: 1})
    cells = for y <- 0..1,x <- 10..25,z <- 10..25,do: {x,y,z}
    rows = World.material_snapshot(c.world,[1001],cells).probe_occupancy |> Jason.encode!() |> Jason.decode!()
    context = %{c | budget: %{rounds: 1,tokens: 100,max_output_tokens: 30}}
    assert {:error,:round_budget,_} = Design.run(script(context,[answer(1,"view",%{})]),args())
    assert_receive {:model_request,body}
    site = Jason.decode!(hd(body.input)["content"])["site"]
    [lower,upper] = site["layers"]
    assert lower["normal_columns"] == ["x","z","material","placed_by"]
    assert lower["normal"] == [[10,10,11,nil],[12,10,19,nil]]
    assert lower["refined"] == []
    assert upper["normal"] == [[10,10,11,1001]]
    refined = %{"cell" => [11,1,10],"material" => 0,"placed_by" => nil,"refined" => true,
      "slots" => [%{"material" => 11,"instance" => [3,0],"count" => 1}]}
    assert upper["refined"] == [Map.put(refined,"micro_cells",[%{"micro" => [88,8,80],"material" => 11,"instance" => [3,0]}])]
    expected = for {x,y,z} <- cells do
      empty = %{"cell" => [x,y,z],"material" => 0,"placed_by" => nil,"refined" => false,"slots" => []}
      case {x,y,z} do
        {10,0,10} -> %{empty | "material" => 11}
        {12,0,10} -> %{empty | "material" => 19}
        {10,1,10} -> %{empty | "material" => 11,"placed_by" => 1001}
        {11,1,10} -> refined
        _ -> empty
      end
    end
    assert rows == expected
    restored = for layer <- site["layers"],x <- 10..25,z <- 10..25 do
      assert layer["unlisted"] == "air_unowned_unrefined"
      y = layer["macro_y"]
      normal = Enum.find(layer["normal"],fn [xx,zz,_,_] -> xx == x and zz == z end)
      Enum.find(layer["refined"],&(&1["cell"] == [x,y,z])) || case normal do
        [_,_,material,placed_by] -> %{"cell" => [x,y,z],"material" => material,"placed_by" => placed_by,"refined" => false,"slots" => []}
        nil -> %{"cell" => [x,y,z],"material" => 0,"placed_by" => nil,"refined" => false,"slots" => []}
      end
    end
    assert Enum.map(restored,&Map.delete(&1,"micro_cells")) == expected
    legacy = for y <- 0..1,do: %{macro_y: y,cells: Enum.filter(rows,&(Enum.at(&1["cell"],1) == y))}
    assert byte_size(Jason.encode!(site["layers"])) < div(byte_size(Jason.encode!(legacy)),4)
  end

  @tag :invalid_draft_view
  test "overlapping drafts remain visible and catalog slices do not make them publishable", c do
    leaf = %{cells: [{{0,0,0},19}],macro_cells: [],children: [],attachments: []}
    assert {:ok,id} = World.publish_prefab(c.world,c.actor,Prefab.encode(leaf))
    hex = Base.encode16(id,case: :lower)
    ops = [%{op: "fill",min: [0,0,0],max: [0,0,0],material: 11},
      %{op: "prefab",slot: 7,id: hex,anchor_micro: [0,0,0],orientation: 0}]
    context = %{c|budget: %{rounds: 4,tokens: 100,max_output_tokens: 30}}
    replies = [answer(1,"edit",%{ops: ops}),answer(2,"view",%{}),
      answer(3,"slice",%{target: hex,axis: 2,at: 0}),answer(4,"publish",%{})]
    assert {:error,:round_budget,%{rounds: 4}} = Design.run(script(context,replies),args())
    requests = for _ <- replies do assert_receive {:model_request,body}; body end
    preview = tool_result(Enum.at(requests,2),"c2")
    assert preview["ok"]
    assert preview["diagnostics"]["publishable"] == false
    assert preview["diagnostics"]["error"] == "overlapping_definition"
    assert preview["diagnostics"]["overlaps"]["macro_micro"] ==
      %{"count"=>1,"bounds"=>[[0,0,0],[1,1,1]],"sample"=>[[0,0,0]]}
    assert preview["views"]["layers"] == [%{"macro_y"=>0,"text"=>"#"}]
    slice = tool_result(Enum.at(requests,3),"c3")
    assert slice["scope"] == "catalog_local" and slice["section"]["text"] == "+"
    assert slice["definition_id"] == hex
    assert Map.keys(World.prefab_catalog(c.world)) == [id]
    assert World.stats(c.world).instances == 0
  end
end
