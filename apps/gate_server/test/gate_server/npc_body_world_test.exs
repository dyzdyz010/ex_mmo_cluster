defmodule GateServer.NpcBodyWorldTest do
  @moduledoc """
  只测试：NPC Body 第二片。真实 VoxelRegion.World（文件世界 + 属性目录）、真实 Scene / Player / P1 NIF、真实 Session.Claims。
  世界是作者写入的平地（y ≤ 63 实心）加一根两格高的石柱；NPC 的余额与世界格只经 World 的公共只读入口观察。
  """
  use ExUnit.Case, async: false
  alias GateServer.Npc.Body
  alias MmoContracts.Voxel.Codec
  alias SceneServer.Movement.Scene
  alias VoxelRegion.{FileStore, World}

  @cv 0x1122_3344_5566_7788
  @npc 9101
  @stone 11
  @pillar {16, 65, 10}

  defmodule Route do
    def route(1),
      do:
        {:ok,
         %{
           scene_ref: Process.whereis(:npc_world_scene),
           world_ref: Process.whereis(:npc_world),
           scene_epoch: 7
         }}
  end

  defp write_world(root) do
    File.mkdir_p!(Path.join([root, FileStore.hex(@cv), "L0"]))
    cells = 66 * 66 * 66
    skins = <<66::32-little, 66::32-little, 66::32-little, 1::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little, 0::32-little>>
    # 本地索引含一圈 ring：索引 0 是世界 y−1。下层 region 世界 y 0..63 实心；上层只有 ring（世界 y 63）实心。
    lower = for _ <- 0..65, y <- 0..65, _ <- 0..65, into: <<>>, do: <<if(y < 65, do: @stone, else: 0)::16-little>>
    upper = for _ <- 0..65, y <- 0..65, _ <- 0..65, into: <<>>, do: <<if(y == 0, do: @stone, else: 0)::16-little>>

    for x <- -1..1, z <- -1..1, {y, body} <- [{0, lower}, {1, upper}] do
      File.write!(
        FileStore.path(root, @cv, 0, {x, y, z}),
        Codec.encode_payload(0, {x, y, z}, 0, @cv, <<cells::32-little, body::binary, skins::binary>>)
      )
    end
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "npc_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    write_world(root)

    materials =
      for id <- 0..23,
          do: %{
            material_id: id,
            max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0),
            defense: 2.0,
            tags: [],
            responses: [%{action: "damage", multiplier: 1.0}]
          }

    catalog = Path.join(root, "properties.json")

    File.write!(
      catalog,
      Jason.encode!(%{
        schema_version: 1,
        tags: [%{id: "damage"}],
        materials: materials,
        tools: [%{id: "pickaxe", tool_id: 1, action: "damage", power: 30.0, range_macro: 6.0, interval_seconds: 0.5}],
        definitions: []
      })
    )

    world =
      start_supervised!(
        {World,
         root: root,
         name: :npc_world,
         property_catalog_path: catalog,
         prefab_catalog_path: Path.join(root, "prefabs"),
         production_materials: [@stone]}
      )

    # 作者入口一次写入：地面上两格高的石柱，上面那格在 NPC 视线高度。
    {:ok, _} = World.apply_edits(world, [{{16, 64, 10}, @stone}, {@pillar, @stone}])

    profile =
      Path.expand("../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    scene =
      start_supervised!(
        {Scene,
         [
           name: :npc_world_scene,
           scene_id: 1,
           scene_epoch: 7,
           world_ref: world,
           config: %{
             "schema" => "voxim-m1-demo-v1",
             "l0_min" => [-1, 0, -1],
             "l0_max_exclusive" => [2, 2, 2],
             "travel_min_m" => [-60.0, 40.0, -60.0],
             "travel_max_exclusive_m" => [60.0, 120.0, 60.0],
             "spawn_probes_m" => [[0.0, 66.0, 0.0]],
             "spawn_min_y_m" => 60.0,
             "profile" => profile
           }
         ]}
      )

    claims = start_supervised!({GateServer.Session.Claims, route_module: Route})

    body =
      start_supervised!(
        {Body,
         claims: claims,
         route_module: Route,
         scene_id: 1,
         cid: @npc,
         spawn: {4.0, 66.0, 10.0},
         brain: brain(context)},
        restart: :temporary
      )

    %{world: world, scene: scene, body: body}
  end

  defp brain(%{live_llm: true}) do
    {GateServer.Npc.Brain.Llm,
     %{
       goal:
         "你在 (4, 10) 附近。先走到 x=14, z=10。到了以后朝 +X 方向探测；如果探测到目标，就反复使用工具，" <>
           "每次使用后重新探测，直到探测不到原来那个目标为止。然后走回 x=4, z=10 并停下，之后一直停着。",
       tool_id: 1,
       endpoint: %{
         url: System.fetch_env!("NPC_LLM_URL"),
         key: System.fetch_env!("NPC_LLM_KEY"),
         model: System.fetch_env!("NPC_LLM_MODEL")
       }
     }}
  end

  # 决策树侧的动词调用方：作者写死的一串命令，覆盖余额、放置、探测 / 使用工具、看地形、液体动词。
  defp brain(%{routine: true}) do
    hit = %{verb: :use_tool, direction: {1.0, 0.0, 0.0}, tool_id: 1, target: :probe}

    {GateServer.Npc.Brain.Routine,
     %{
       steps: [
         %{verb: :query_balances},
         %{verb: :place, coord: {6, 64, 10}, material: @stone, tool_id: 1},
         %{verb: :move_to, position: {14.0, 10.0}, tolerance: 0.5},
         %{verb: :probe_toward, direction: {1.0, 0.0, 0.0}, tool_id: 1},
         hit,
         hit,
         hit,
         hit,
         %{verb: :look, min: {15, 63, 9}, max: {17, 66, 11}},
         %{verb: :place, coord: @pillar, material: @stone, tool_id: 1},
         %{verb: :scoop, coord: @pillar, material: @stone, tool_id: 1},
         %{verb: :look, min: {0, 0, 0}, max: {100, 100, 100}}
       ]
     }}
  end

  defp brain(_),
    do:
      {GateServer.Npc.Brain.Patrol,
       %{route: [{4.0, 10.0}, {14.0, 10.0}], dig: %{direction: {1.0, 0.0, 0.0}, tool_id: 1}}}

  defp await(fun, deadline) do
    case fun.() do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "condition not reached"
        Process.sleep(100)
        await(fun, deadline)

      value ->
        value
    end
  end

  defp cell(world), do: hd(World.material_snapshot(world, [@npc], [@pillar]).probe_occupancy).material
  defp balance(world), do: Enum.find(World.material_balances(world, @npc), &(&1.material == @stone)).balance

  test "NPC probes and mines through the player adjudication: out of range is rejected, in range harvests into its own balance",
       %{world: world, body: body} do
    assert @stone == cell(world)
    assert 0 == balance(world)

    # 出生点 x=4：石柱在 12 m 外，镐射程 6 m → 权威拒绝，原因原样回到 Body。
    first =
      await(
        fn -> Enum.find(Enum.reverse(Body.observe(body).outcomes), &(&1.verb == :probe_toward)) end,
        System.monotonic_time(:millisecond) + 10_000
      )

    assert %{status: :rejected, reason: :no_target} = first

    # 走到 x≈14：同一方向探测命中石柱上格，攻击到它被挖掉。HP 100、每击 30−2=28 → 4 击。
    await(fn -> if cell(world) == 0, do: true end, System.monotonic_time(:millisecond) + 20_000)
    assert 512 == balance(world)

    hits = Enum.filter(Body.observe(body).outcomes, &(&1.verb == :use_tool))
    assert 4 == length(hits)
    assert Enum.all?(hits, &match?(%{status: :done, data: %{seq: seq}} when is_integer(seq), &1))

    # 挖完回到巡逻：位置离开 x≈14。
    await(
      fn -> if elem(Body.observe(body).position, 0) < 10.0, do: true end,
      System.monotonic_time(:millisecond) + 10_000
    )
  end

  @tag :routine
  test "NPC builds with what it mined: balance, place, look and liquid verbs all go through the player World APIs",
       %{world: world, body: body} do
    outcomes =
      await(
        fn ->
          outcomes = Body.observe(body).outcomes
          if length(outcomes) == 12, do: Enum.reverse(outcomes)
        end,
        System.monotonic_time(:millisecond) + 40_000
      )

    assert [balances, broke, _move, _probe, _, _, _, last_hit, look, placed, scoop, far] = outcomes

    # 起步背包为空：余额读得到，放置被权威以余额不足拒绝，世界没变。
    assert %{verb: :query_balances, status: :done, data: %{balances: [%{material: @stone, balance: 0, cost: 512}]}} =
             balances

    assert %{verb: :place, status: :rejected, reason: :insufficient_material} = broke

    # 4 击挖掉石柱上格 → 512 单位；look 看到的是挖掉之后的世界：上格空气、下格与地面仍是石头。
    assert %{verb: :use_tool, status: :done} = last_hit
    assert %{verb: :look, status: :done, data: %{probe_occupancy: cells}} = look
    assert 36 == length(cells)
    at = fn coord -> Enum.find(cells, &(&1.cell == Tuple.to_list(coord))).material end
    assert {0, @stone, @stone, 0} == {at.(@pillar), at.({16, 64, 10}), at.({15, 63, 10}), at.({15, 64, 10})}

    # 用挖到的材料把那一格放回去：世界格恢复、余额归零，Observation 里的余额随事务刷新。
    assert %{verb: :place, status: :done, data: %{seq: seq}} = placed
    assert is_integer(seq)
    assert @stone == cell(world)
    assert 0 == balance(world)
    assert [%{material: @stone, balance: 0}] = Body.observe(body).balances

    # 液体动词走同一个 production 入口；这个世界没有液体，权威原样拒绝。
    assert %{verb: :scoop, status: :rejected, reason: :invalid_liquid_operation} = scoop
    # 超出 512 格 / 32 m 的 look 不到 World。
    assert %{verb: :look, status: :rejected, reason: :invalid_command} = far
  end

  @tag :live_llm
  @tag timeout: 600_000
  test "the same world driven by a real LLM from one sentence of goal: it mines the pillar and walks back",
       %{world: world, body: body} do
    await(fn -> if cell(world) == 0, do: true end, System.monotonic_time(:millisecond) + 300_000)
    assert 512 == balance(world)

    await(
      fn -> if elem(Body.observe(body).position, 0) < 5.0, do: true end,
      System.monotonic_time(:millisecond) + 120_000
    )

    IO.inspect(Enum.reverse(for o <- Body.observe(body).outcomes, do: {o.id, o.verb, o.status, o.reason}),
      label: "llm_outcomes",
      limit: :infinity
    )
  end

end
