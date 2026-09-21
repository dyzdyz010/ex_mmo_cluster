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

  defp brain(%{builder: true}) do
    {GateServer.Npc.Brain.Llm,
     %{
       goal:
         "你在 x=4, z=10 附近的平地上。x=16, z=10 处立着一根石柱。去把它整根挖下来，" <>
           "再用挖到的材料在 z=13 这一排、x=10 到 x=11 砌一段一格高的墙。砌完以后每次都调用 wait 等 300 秒。",
       tools: %{1 => "镐：挖掘固体，射程 6 米"},
       endpoint: %{
         url: System.fetch_env!("NPC_LLM_URL"),
         key: System.fetch_env!("NPC_LLM_KEY"),
         model: System.fetch_env!("NPC_LLM_MODEL")
       }
     }}
  end

  defp brain(%{live_llm: true}) do
    {GateServer.Npc.Brain.Llm,
     %{
       goal:
         "你在 (4, 10) 附近。先走到 x=14, z=10。到了以后朝 +X 方向探测；如果探测到目标，就反复使用工具，" <>
           "每次使用后重新探测，直到探测不到原来那个目标为止。然后走回 x=4, z=10 并停下，之后一直停着。",
       tools: %{1 => "镐：挖掘固体，射程 6 米"},
       endpoint: %{
         url: System.fetch_env!("NPC_LLM_URL"),
         key: System.fetch_env!("NPC_LLM_KEY"),
         model: System.fetch_env!("NPC_LLM_MODEL")
       }
     }}
  end

  # 决策树侧的动词调用方：作者写死的一串命令，覆盖余额、放置、探测 / 使用工具、看地形、附件、prefab、液体动词。
  defp brain(%{routine: true}) do
    hit = %{verb: :use_tool, direction: {1.0, 0.0, 0.0}, tool_id: 1, target: :probe}
    # 眼睛在上格高度：压低一点的射线穿过挖空的上格，从顶面进入石柱下格。
    down = {1 / :math.sqrt(1.09), -0.3 / :math.sqrt(1.09), 0.0}
    low = %{hit | direction: down}
    face = face()

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
         %{verb: :probe_toward, direction: down, tool_id: 1},
         low,
         low,
         low,
         low,
         %{verb: :look, min: {15, 63, 9}, max: {17, 66, 11}},
         Map.put(face, :verb, :attach),
         %{verb: :inspect},
         Map.merge(face, %{verb: :detach, attachment_id: 0}),
         %{verb: :say, text: "墙砌好了"},
         %{verb: :prefab_place, definition_id: :binary.copy(<<42>>, 32), anchor: {15, 64, 12}, orientation: 0},
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

  # 地面（y ≤ 63 实心）顶面上的一个 micro 面片：法线轴 Y，micro 坐标 = macro × 8。
  defp face, do: %{kind: 0, axis: 1, size: 1, anchor: {120, 512, 80}, material: @stone, tool_id: 1}

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
          if length(outcomes) == 22, do: Enum.reverse(outcomes)
        end,
        System.monotonic_time(:millisecond) + 60_000
      )

    assert [balances, broke, _move, _probe, _, _, _, _, lower, _, _, _, last_hit, look, attach, inspect, detach, say, prefab, placed, scoop, far] =
             outcomes

    # 起步背包为空：余额读得到，放置被权威以余额不足拒绝，世界没变。
    assert %{verb: :query_balances, status: :done, data: %{balances: [%{material: @stone, balance: 0, cost: 512}]}} =
             balances

    assert %{verb: :place, status: :rejected, reason: :insufficient_material} = broke

    # 各 4 击挖掉石柱上、下两格 → 1024 单位；look 看到的是挖掉之后的世界：石柱没了，地面还在。
    assert %{verb: :probe_toward, status: :done, data: %{micro: {128, _, 80}, material: @stone}} = lower
    assert %{verb: :use_tool, status: :done} = last_hit
    assert %{verb: :look, status: :done, data: %{probe_occupancy: cells}} = look
    assert 36 == length(cells)
    at = fn coord -> Enum.find(cells, &(&1.cell == Tuple.to_list(coord))).material end
    assert {0, 0, @stone, @stone} == {at.(@pillar), at.({16, 64, 10}), at.({16, 63, 10}), at.({15, 63, 10})}

    # 附件：一个 micro 面片花 1 单位；拆除要带对那件附件的 id，错的被权威拒绝。
    assert %{verb: :attach, status: :done} = attach
    assert %{verb: :detach, status: :rejected, reason: :stale_target} = detach
    # 正式栈还没有聊天：say 只占位。
    assert %{verb: :say, status: :rejected, reason: :chat_unavailable} = say

    # inspect 给出那件附件的权威身份；拿它就能对附件用工具、再把它拆下来（材料退回）。
    assert %{verb: :inspect, status: :done, data: %{property_states: [thing]}} = inspect
    assert %{granularity: 3, micro: {120, 512, 80}, material: @stone, incarnation: id, owner: {id, 1}} = thing
    # Prefab 与玩家同一道建造者门：这个 cid 不在名单里。
    assert %{verb: :prefab_place, status: :rejected, reason: :builder_permission_required} = prefab

    # 用挖到的材料把上格放回去：世界格恢复，余额 1024 − 1 − 512，Observation 里的余额随事务刷新。
    assert %{verb: :place, status: :done, data: %{seq: seq}} = placed
    assert is_integer(seq)
    assert @stone == cell(world)
    assert 511 == balance(world)
    assert [%{material: @stone, balance: 511}] = Body.observe(body).balances

    # 测试进程充当进程外 Brain：用 inspect 到的身份打附件一下，再带对的 id 拆掉。
    Body.command(body, %{id: 101, verb: :use_tool, direction: {1.0, 0.0, 0.0}, tool_id: 1, target: thing})
    Body.command(body, Map.merge(face(), %{id: 102, verb: :detach, attachment_id: id}))

    [hit, detached] =
      await(
        fn ->
          found = Enum.filter(Body.observe(body).outcomes, &(&1.id in [101, 102]))
          if length(found) == 2, do: Enum.sort_by(found, & &1.id)
        end,
        System.monotonic_time(:millisecond) + 10_000
      )

    assert %{verb: :use_tool, status: :done} = hit
    assert %{verb: :detach, status: :done} = detached
    assert 512 == balance(world)

    # 液体动词走同一个 production 入口；这个世界没有液体，权威原样拒绝。
    assert %{verb: :scoop, status: :rejected, reason: :invalid_liquid_operation} = scoop
    # 超出 512 格 / 32 m 的 look 不到 World。
    assert %{verb: :look, status: :rejected, reason: :invalid_command} = far
  end

  @tag :live_llm
  @tag :builder
  @tag timeout: 900_000
  test "a real LLM, given only a goal with coordinates, mines the pillar and builds a wall from what it mined",
       %{world: world, body: body} do
    wall = [{10, 64, 13}, {11, 64, 13}]
    materials = fn cells -> Enum.map(World.material_snapshot(world, [@npc], cells).probe_occupancy, & &1.material) end

    try do
      await(fn -> if materials.(wall) == [@stone, @stone], do: true end, System.monotonic_time(:millisecond) + 780_000)
    after
      IO.inspect(Enum.reverse(for o <- Body.observe(body).outcomes, do: {o.id, o.verb, o.status, o.reason}),
        label: "llm_builder_outcomes",
        limit: :infinity
      )
    end

    # 墙的两格正好是石柱的两格：材料来自挖掘，背包清零，石柱不在了。
    assert [0, 0] == materials.([{16, 64, 10}, @pillar])
    assert 0 == balance(world)
  end

  @tag :live_llm
  @tag timeout: 600_000
  test "the same world driven by a real LLM from one sentence of goal: it mines the pillar and walks back",
       %{world: world, body: body} do
    try do
      await(fn -> if cell(world) == 0, do: true end, System.monotonic_time(:millisecond) + 300_000)
      assert 512 == balance(world)

      await(
        fn -> if elem(Body.observe(body).position, 0) < 5.0, do: true end,
        System.monotonic_time(:millisecond) + 120_000
      )
    after
      IO.inspect(Enum.reverse(for o <- Body.observe(body).outcomes, do: {o.id, o.verb, o.status, o.reason}),
        label: "llm_outcomes",
        limit: :infinity
      )
    end
  end

end
