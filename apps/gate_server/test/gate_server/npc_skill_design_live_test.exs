Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.NpcSkillDesignLiveTest do
  @moduledoc """
  只测试：真实模型经正式 Skills→Design 发布，再走 World 付费 prefab 放置。
  外围 source/actor/clock 是声明的夹具，World/Scene、发布、裁决和余额均为真实实现。
  每次命令只运行 DESIGN_LIVE_CASE 指定的一项目标，缺省 cottage；不代表父脑调度或真实玩家移动验收。
  完整模型请求体不含 endpoint/key，写入 Voxim/Saved 下独立证据目录；不调用 live Jev。
  """
  use ExUnit.Case, async: false
  require Logger
  alias GateServer.Npc.{Skills, Brain.Llm}
  alias VoxelRegion.{World, Prefab, Spatial}
  alias VoxelRegion.TestSupport.{Source, Actor}
  alias SceneServer.Movement.Scene
  alias MmoContracts.Voxel.Payload

  @moduletag :live_llm
  @moduletag :design_live
  @moduletag timeout: 900_000
  @cid 1001
  @anchor {80,8,80}
  @goals %{
    "cottage" => "Build a small accessible stone-and-wood cottage using macro walls and a roof together with the catalogue DoorFrame, Window and Stairs.",
    "floor_ceiling" => "Build a small cottage with macro walls, a raised solid floor and a ceiling, using the catalogue DoorFrame, Window and Stairs while keeping at least two metres of clear interior height above the floor.",
    "two_storey" => "Build a compact two-storey cottage using macro walls, floors and roofs plus the catalogue DoorFrame, Window and Stairs, with a walkable route from outside into a covered upstairs room."
  }

  defmodule Clock do
    def now(_), do: 0
    def schedule(_, _, _), do: :ok
  end

  test "one real model designs, repairs, publishes and pays for the selected house" do
    MmoTest.Database.start!()
    Logger.configure(level: :info)
    selected = System.get_env("DESIGN_LIVE_CASE", "cottage")
    goal = Map.fetch!(@goals, selected)
    voxim = Path.expand("../../../../../Voxim", __DIR__)
    base = System.get_env("DESIGN_LIVE_OUT", Path.join(voxim,"Saved/Gameplay/prefab-designer-20260922"))
    out = Path.join(base,"d2-live-#{selected}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(out)
    root = Path.join(out,"world")
    File.mkdir_p!(root)
    author = Path.join(voxim,"Saved/Gameplay/Server/physical-prefabs")
    properties = VoxelRegion.TestSupport.catalog()
    raw = Jason.decode!(File.read!(properties))
    labels = Path.expand("../fixtures/npc_design_labels.json",__DIR__) |> File.read!() |> Jason.decode!() |> Map.fetch!("labels")
    for id <- Map.keys(labels), do: assert(File.regular?(Path.join(author,id<>".vxpd")))
    world = start_supervised!({World,[source: Source,root: root,observer: self(),name: nil,
      property_catalog_path: properties,prefab_catalog_path: author,production_materials: [11,19]]})

    # 一次有限作者场地与一次记账供给；之后仅通过正式意图改变几何或余额。
    ground = for x <- 8..27,z <- 8..27, do: {{x,0,z},11}
    assert {:ok,_} = World.apply_edits(world,ground)
    quantum = raw["attachments"]["material_units_per_micro"]
    resolution = Spatial.micro_resolution()
    assert resolution == 8
    supplied = %{11 => 256 * 512 * quantum,19 => 256 * 512 * quantum}
    assert {:ok,_} = World.material_supply(world,@cid,"design-live-#{selected}",supplied)
    fixture = Path.join(voxim,"Docs/M0/fixtures/suite.json")
    profile = Jason.decode!(File.read!(fixture))["profile"] |> Map.put("fixed_hz",60)
    scene = start_supervised!({Scene,[scene_id: 1,scene_epoch: 1,world_ref: world,clock: {Clock,nil},
      config: %{"schema" => "voxim-m1-demo-v1","profile" => profile,
        "l0_min" => [0,0,0],"l0_max_exclusive" => [1,1,1],
        "travel_min_m" => [0.5,0.5,0.5],"travel_max_exclusive_m" => [63.0,63.0,63.0],
        "spawn_probes_m" => [[8.5,4.0,8.5]],"spawn_min_y_m" => 0.5}]})
    actor = %{cid: @cid,gate: self(),identity: :design_live,refresh: &Actor.tool_context/2,
      eye: {10.5,2.0,9.0},position: {10.5,1.4,9.0},tick_us: 16_667}
    actor = Map.put(actor,:player,start_supervised!({Actor,actor}))
    {:ok,_} = Application.ensure_all_started(:inets)
    {:ok,_} = Application.ensure_all_started(:ssl)
    endpoint = %{url: System.fetch_env!("NPC_LLM_URL"),key: System.fetch_env!("NPC_LLM_KEY"),
      model: "gpt-5.6-terra",effort: "high"}
    # 两层与天然场地实测后段约20k/轮；保留12轮，按12×20k给足有界工作台预算。
    budget = %{rounds: 12,tokens: 240_000,max_output_tokens: 4096}
    {:ok, meter} = Agent.start_link(fn -> %{requests: 0,input_tokens: 0,output_tokens: 0,total_tokens: 0} end)
    request = fn endpoint,body -> recorded_request(endpoint,body,out,meter) end
    context = %{world: world,scene: scene,actor: actor,request: request,
      profile: %{endpoint: endpoint,skills: %{design: %{labels: labels,budget: budget}}}}
    before = World.material_snapshot(world,[@cid],Enum.map(ground,&elem(&1,0)))
    assert Enum.all?(before.probe_occupancy,&(&1.material == 11 and not &1.refined))
    write_json(out,"fixture.json",%{classification: "Test-only",case: selected,goal: goal,
      model: endpoint.model,effort: endpoint.effort,budget: budget,anchor_micro: @anchor,
      author_directory: author,author_definition_count: map_size(World.prefab_catalog(world)),
      properties_sha256: Base.encode16(:crypto.hash(:sha256,File.read!(properties)),case: :lower),
      observed_ground: before,labels: labels})
    IO.puts("design_live_evidence=#{out}")

    try do
      result = Skills.run(context,%{skill: :design,args: %{"goal" => goal,"anchor_micro" => Tuple.to_list(@anchor),"orientation" => 0}})
      write_json(out,"design-result.json",result)
      assert {:ok,result} = result
      assert result.metrics.request_count == Agent.get(meter,& &1.requests)
      assert result.metrics.usage_complete
      assert result.check.passed
      assert World.seq(world) == before.seq
      assert World.stats(world).instances == 0
      assert World.material_snapshot(world,[@cid],[]).material_balances == before.material_balances
      compiled = Map.fetch!(World.prefab_catalog(world),result.definition_id)
      references = MapSet.new(compiled.nodes,& &1.definition_id)
      for id <- Map.keys(labels), do: assert(MapSet.member?(references,Base.decode16!(id,case: :mixed)))
      assert Enum.sum(Enum.map(compiled.nodes,&length(cells(&1.macro_cells)))) > 0
      expected = material_units(compiled,raw)
      assert result.check.report.materials.units == expected
      bytes = File.read!(Path.join([root,"prefabs",Base.encode16(result.definition_id,case: :lower)<>".vxpd"]))
      assert :crypto.hash(:sha256,bytes) == result.definition_id
      assert {:ok,txn} = World.prefab_intent(world,actor,:voxel_prefab_place_v1,
        %{definition_id: result.definition_id,anchor: @anchor,orientation: 0,client_intent_seq: 1})
      File.write!(Path.join(out,"placement.etf"),:erlang.term_to_binary(txn))
      assert World.seq(world) == before.seq + 1
      after_state = World.material_snapshot(world,[@cid],[])
      balances = Map.new(after_state.material_balances,&{&1.material,&1.units})
      for {material,units} <- supplied, do: assert(balances[material] == units - Map.get(expected,material,0))
      assert_world_geometry(world,compiled)
      assert_inside_support(world,result,selected)
      write_json(out,"verified.json",%{passed: true,definition_id: result.definition_id,
        summary: result.summary,independent_material_units: expected,balances_after: after_state.material_balances,
        world_seq: after_state.seq,metrics: result.metrics})
    after
      write_json(out,"http-metrics.json",Agent.get(meter,& &1))
    end
  end

  defp recorded_request(endpoint,body,out,meter) do
    calls = for %{"type" => "function_call","name" => name,"arguments" => arguments} <- body.input,
      do: {name,Jason.decode!(arguments)}
    recent = Enum.take(calls,-3)
    if length(recent) == 3 and length(Enum.uniq(recent)) == 1 do
      File.write!(Path.join(out,"idle-stop.txt"),"连续三次相同工具与参数，未再请求模型。\n")
      {:error,:live_idle_limit}
    else
      round = Agent.get_and_update(meter,fn m -> {m.requests + 1,%{m | requests: m.requests + 1}} end)
      write_json(out,"request-#{round}.json",body)
      started = System.monotonic_time(:millisecond)
      Logger.info("design_live_request round=#{round} model=#{endpoint.model} status=start")
      response = Llm.request(endpoint,body)
      write_json(out,"response-#{round}.json",response)
      {tools,usage} = case response do
        {:ok,%{"output" => output} = value} ->
          {for(%{"type" => "function_call","name" => name} <- output,do: name),Map.get(value,"usage")}
        _ -> {[],nil}
      end
      if is_map(usage) do
        Agent.update(meter,fn m -> %{m | input_tokens: m.input_tokens + Map.get(usage,"input_tokens",0),
          output_tokens: m.output_tokens + Map.get(usage,"output_tokens",0),
          total_tokens: m.total_tokens + Map.get(usage,"total_tokens",0)} end)
      end
      previous = for %{"type" => "function_call_output","output" => output} <- body.input,do: Jason.decode!(output)
      row = %{round: round,tools: tools,usage: usage,elapsed_ms: System.monotonic_time(:millisecond)-started,
        previous_tool_result: List.last(previous),metrics: Agent.get(meter,& &1)}
      File.write!(Path.join(out,"rounds.jsonl"),Jason.encode!(plain(row))<>"\n",[:append])
      IO.puts("design_live_round=#{round} tools=#{inspect(tools)} usage=#{inspect(usage)}")
      Logger.info("npc_llm_decision skill=design round=#{round} tools=#{inspect(tools)}")
      response
    end
  end

  # 从已发布节点直接数格与槽位，并用冻结作者参数手算单位，不调用 Check.materials。
  defp material_units(compiled,raw) do
    q = raw["attachments"]["material_units_per_micro"]
    face = round(raw["attachments"]["face_thickness_m"] * 8 * q)
    edge = round(raw["attachments"]["line_section_m2"] * 64 * q)
    Enum.reduce(compiled.nodes,%{},fn node,total ->
      rows = Enum.map(cells(node.cells),fn {_,m} -> {m,q} end) ++
        Enum.map(cells(node.macro_cells),fn {_,m} -> {m,512*q} end) ++
        (for group <- node.attachments,{kind,_,_} <- group.slots,do: {group.material,if(kind == 0,do: face,else: edge)})
      Enum.reduce(rows,total,fn {m,n},acc -> Map.update(acc,m,n,&(&1+n)) end)
    end)
  end
  defp cells(binary) when is_binary(binary),do: :erlang.binary_to_term(binary,[:safe])
  defp cells(list),do: list

  defp assert_world_geometry(world,compiled) do
    macros = Map.new(Prefab.macro_footprint(compiled,@anchor,0))
    refined = Enum.reduce(Prefab.footprint(compiled,@anchor,0),%{},fn {micro,m},acc ->
      {cell,slot} = Prefab.macro_slot(micro)
      Map.update(acc,cell,%{slot => m},&Map.put(&1,slot,m))
    end)
    wanted = Enum.uniq(Map.keys(macros) ++ Map.keys(refined))
    observed = World.material_snapshot(world,[@cid],wanted).probe_occupancy |> Map.new(&{List.to_tuple(&1.cell),&1})
    for {cell,m} <- macros do
      assert observed[cell].material == m
      assert observed[cell].placed_by == @cid
      refute observed[cell].refined
    end
    payloads = wanted |> Enum.map(&region/1) |> Enum.uniq() |> Map.new(&{&1,VoxelRegion.TestSupport.payload(world,0,&1)})
    for {cell,slots} <- refined do
      assert observed[cell].refined and observed[cell].material == 0
      payload = payloads[region(cell)]
      actual = payload.refined |> Map.fetch!(Payload.cell_index(Payload.local(payload.region,cell))) |> Map.new(fn {slot,{m,_}} -> {slot,m} end)
      assert actual == slots
    end
    assert World.stats(world).instances == length(compiled.nodes)
  end

  defp assert_inside_support(world,result,selected) do
    {:ok,path} = result.check.report.route
    {x,y,z} = List.last(path)
    assert MmoContracts.VoxelMaterialCatalog.blocks_movement?(sample(world,{x,y-1,z}))
    for yy <- y..(y+14),do: assert(sample(world,{x,yy,z}) == 0)
    if selected in ["floor_ceiling","two_storey"] do
      assert y > 8
      floors = Enum.map(result.check.report.headroom.interiors,& &1.floor_y)
      if selected == "two_storey" do
        assert length(Enum.uniq(floors)) >= 2
        assert y == Enum.max(floors)
      end
    end
  end
  defp sample(world,micro) do
    {cell,slot} = Prefab.macro_slot(micro)
    payload = VoxelRegion.TestSupport.payload(world,0,region(cell))
    index = Payload.cell_index(Payload.local(payload.region,cell))
    case Map.get(payload.refined,index) do
      nil -> Payload.material(payload,Payload.local(payload.region,cell))
      slots -> case Map.get(slots,slot) do nil -> 0; {m,_} -> m end
    end
  end
  defp region(cell),do: cell |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1,Payload.extent()-2)) |> List.to_tuple()
  defp write_json(out,name,value),do: File.write!(Path.join(out,name),Jason.encode!(plain(value),pretty: true))
  defp plain(%{}=value),do: Map.new(value,fn
    {:definition_id,<<_::256>>=id} -> {:definition_id,Base.encode16(id,case: :lower)}
    {k,v} -> {k,plain(v)}
  end)
  defp plain(value) when is_tuple(value),do: value |> Tuple.to_list() |> Enum.map(&plain/1)
  defp plain(value) when is_list(value),do: Enum.map(value,&plain/1)
  defp plain(value),do: value
end
