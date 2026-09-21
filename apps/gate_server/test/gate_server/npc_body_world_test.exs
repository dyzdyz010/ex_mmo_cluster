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

    # 有限样本：经服务端授权供给入口一次记账，之后只经正常玩法消费 / 退回。
    if edits = context[:edits], do: {:ok, _} = World.apply_edits(world, edits)
    if supply = context[:supply], do: {:ok, _} = World.material_supply(world, @npc, "npc-test-supply", supply)

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

  # 空脑：测试进程用 Body.command/2 充当进程外 Brain。
  defp brain(%{idle: true}), do: {GateServer.Npc.Brain.Routine, %{steps: []}}

  defp brain(%{climber: true}) do
    {GateServer.Npc.Brain.Llm,
     %{
       goal:
         "你站在 x=4, z=10 附近的平地上，地面最上一层实心格是 y=63（所以你站在 y=64 这一层）。" <>
           "格 (20, 64, 10)、(20, 65, 10)、(20, 66, 10) 是一根三格高的石柱，背包里有石料（material 11）。" <>
           "目标：站到石柱顶上，也就是 x=20.5, z=10.5、站立格 y=67。到了以后每次都调用 wait 等 300 秒。",
       tools: %{1 => "镐：挖掘固体、放置方块，射程 6 米"},
       endpoint: %{
         url: System.fetch_env!("NPC_LLM_URL"),
         key: System.fetch_env!("NPC_LLM_KEY"),
         model: System.fetch_env!("NPC_LLM_MODEL")
       }
     }}
  end

  defp brain(%{inspector: true}) do
    {GateServer.Npc.Brain.Llm,
     %{
       goal:
         "你站在 x=4, z=10 附近的平地上，地面最上一层实心格是 y=63，背包里有一点石料（material 11）。" <>
           "在格 (6, 63, 10) 的顶面贴一件最小的面片附件；然后用 inspect 找到它，用镐对这件附件敲一下，" <>
           "再按它的 id 把它拆下来，拆完说一句“拆好了”。之后每次都调用 wait 等 300 秒。",
       tools: %{1 => "镐：挖掘固体、贴 / 拆附件，射程 6 米"},
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

  defp outcome(body, id, timeout) do
    await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end, System.monotonic_time(:millisecond) + timeout)
  end

  defp ready(body), do: await(fn -> Body.observe(body).position end, System.monotonic_time(:millisecond) + 10_000)

  # 调用层（Body + 真实 World / Scene / 碰撞）：寻路经 World 的只读快照取地形，Body 沿路点送输入，权威照常裁决位置。
  # 出生在 (4, 10)；x=8 处一堵两格高、z 7..13 的墙挡在去 (12.5, 10.5) 的直线上。
  @tag :idle
  @tag edits: for(z <- 7..13, y <- 64..65, do: {{8, y, z}, 11})
  test "move_to walks around a wall the straight line runs into", %{body: body} do
    ready(body)
    Body.command(body, %{id: 1, verb: :move_to, position: {12.5, 10.5}, tolerance: 0.5})
    assert %{status: :done, data: %{within_tolerance: true, position: {x, y, z}}} = outcome(body, 1, 30_000)
    assert abs(x - 12.5) <= 0.5 and abs(z - 10.5) <= 0.5
    # 仍站在地面上（顶面 y=64，胶囊半高 0.9）：没有翻墙。
    assert_in_delta 64.9, y, 0.05
  end

  # 一格一级的台阶上到三格高的平台；平台另一侧同一列没有别的站立层。
  @tag :idle
  @tag edits: for(z <- 9..11, {x, top} <- [{8, 64}, {9, 65}, {10, 66}, {11, 66}, {12, 66}], y <- 64..top, do: {{x, y, z}, 11})
  test "move_to climbs one-cell stairs onto a platform and reports the authoritative height", %{body: body} do
    ready(body)
    Body.command(body, %{id: 1, verb: :move_to, position: {11.5, 10.5}, tolerance: 0.5})
    assert %{status: :done, data: %{within_tolerance: true, position: {_, y, _}}} = outcome(body, 1, 30_000)
    assert_in_delta 67.9, y, 0.05
  end

  # 三格高的孤柱顶上不去（step_height 1 m、不起跳）；超出取盒范围的目标不去问 World。
  @tag :idle
  @tag edits: for(y <- 64..66, do: {{20, y, 10}, 11})
  test "move_to is rejected with :no_path / :too_far instead of walking into the obstacle", %{body: body} do
    {x0, _, z0} = ready(body)
    Body.command(body, %{id: 1, verb: :move_to, position: {20.5, 10.5}, tolerance: 0.5})
    assert %{status: :rejected, reason: :no_path} = outcome(body, 1, 10_000)
    Body.command(body, %{id: 2, verb: :move_to, position: {104.5, 10.5}, tolerance: 0.5})
    assert %{status: :rejected, reason: :too_far} = outcome(body, 2, 10_000)
    {x, _, z} = Body.observe(body).position
    assert abs(x - x0) < 0.5 and abs(z - z0) < 0.5
  end

  # 路是起步时那一刻的世界算的：走到一半前面被砌死，Body 不重试，回报 :stuck；Brain 再发一次 move_to 就按新世界重算。
  @tag :idle
  test "a wall raised across the planned path ends the move as :stuck; asking again plans around it", %{world: world, body: body} do
    ready(body)
    Body.command(body, %{id: 1, verb: :move_to, position: {30.5, 10.5}, tolerance: 0.5})
    await(fn -> if elem(Body.observe(body).position, 0) > 6.0, do: true end, System.monotonic_time(:millisecond) + 10_000)
    {:ok, _} = World.apply_edits(world, for(z <- 7..13, y <- 64..65, do: {{22, y, z}, 11}))

    assert %{status: :rejected, reason: :stuck} = outcome(body, 1, 20_000)
    {x, _, _} = Body.observe(body).position
    assert x < 22.0

    Body.command(body, %{id: 2, verb: :move_to, position: {30.5, 10.5}, tolerance: 0.5})
    assert %{status: :done, data: %{within_tolerance: true}} = outcome(body, 2, 30_000)
  end

  # 同一列两层：y 选层。地面层（64）直接可达；柱顶（67）不可达。
  @tag :idle
  @tag edits: for(y <- 64..66, do: {{20, y, 10}, 11})
  test "move_to with y only accepts that standing level", %{body: body} do
    ready(body)
    Body.command(body, %{id: 1, verb: :move_to, position: {19.5, 10.5}, y: 67, tolerance: 0.5})
    assert %{status: :rejected, reason: :no_path} = outcome(body, 1, 10_000)
    Body.command(body, %{id: 2, verb: :move_to, position: {19.5, 10.5}, y: 64, tolerance: 0.5})
    assert %{status: :done, data: %{within_tolerance: true}} = outcome(body, 2, 30_000)
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

  # 建设者的核心情形：高差超过一格，寻路回报 no_path，模型得自己想到砌台阶再走上去。
  @tag :live_llm
  @tag :climber
  @tag edits: for(y <- 64..66, do: {{20, y, 10}, 11})
  @tag supply: %{11 => 8 * 512}
  @tag timeout: 900_000
  test "a real LLM told only where to stand builds its own stairs and walks up them", %{world: world, body: body} do
    try do
      # 权威位置：胶囊中心 = 站立格底 67 + 半高 0.9，水平在柱顶那一格内。
      await(
        fn ->
          case Body.observe(body).position do
            {x, y, z} when x >= 20.0 and x < 21.0 and z >= 10.0 and z < 11.0 and abs(y - 67.9) < 0.05 -> true
            _ -> nil
          end
        end,
        System.monotonic_time(:millisecond) + 780_000
      )
    after
      IO.inspect(Enum.reverse(for o <- Body.observe(body).outcomes, do: {o.id, o.verb, o.status, o.reason}),
        label: "llm_climber_outcomes",
        limit: :infinity
      )
    end

    # 石柱还在（没有靠挖掉它来“到达”），花掉的石料就是世界里多出来的格数。
    assert [11, 11, 11] ==
             Enum.map(World.material_snapshot(world, [@npc], for(y <- 64..66, do: {20, y, 10})).probe_occupancy, & &1.material)

    spent = div(8 * 512 - balance(world), 512)
    assert spent >= 3
    IO.inspect(spent, label: "llm_climber_cells_placed")
  end

  @tag :live_llm
  @tag :inspector
  @tag supply: %{11 => 8}
  @tag timeout: 600_000
  test "a real LLM attaches a face, finds it with inspect and detaches it by id: world and balance checked through World",
       %{world: world, body: body} do
    attachments = fn ->
      Enum.filter(World.simulation_snapshot(world, [@npc], {{-1, 0, -1}, {2, 2, 2}}).property_states, &(&1.granularity == 3))
    end

    assert [] == attachments.()
    assert 8 == balance(world)

    try do
      # 贴上：世界里恰好一件附件，在格 (6,63,10) 的顶面（micro = macro × 8，顶面 y = 64 × 8），花 1 单位。
      [thing] = await(fn -> if (rows = attachments.()) != [], do: rows end, System.monotonic_time(:millisecond) + 240_000)
      assert %{micro: {x, 512, z}, material: @stone, owner: {_, 1}} = thing
      assert x in 48..55 and z in 80..87
      assert 7 == balance(world)

      # 拆掉：附件不在了，材料全额退回。
      await(fn -> if attachments.() == [], do: true end, System.monotonic_time(:millisecond) + 300_000)
      assert 8 == balance(world)
    after
      IO.inspect(Enum.reverse(for o <- Body.observe(body).outcomes, do: {o.id, o.verb, o.status, o.reason}),
        label: "llm_inspector_outcomes",
        limit: :infinity
      )
    end

    # 模型确实走了 inspect → 按 id 对附件用工具 → 按 id 拆：权威确认的 Outcome 里都有；say 在正式栈接入聊天前恒被拒。
    outcomes =
      await(
        fn -> if Enum.any?(o = Body.observe(body).outcomes, &(&1.verb == :say)), do: o end,
        System.monotonic_time(:millisecond) + 60_000
      )

    done = for %{status: :done, verb: verb} <- outcomes, do: verb
    assert :inspect in done and :use_tool in done and :detach in done
    assert %{status: :rejected, reason: :chat_unavailable} = Enum.find(outcomes, &(&1.verb == :say))
    IO.inspect(Enum.reverse(for o <- outcomes, do: {o.id, o.verb, o.status, o.reason}), label: "llm_inspector_final")
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
