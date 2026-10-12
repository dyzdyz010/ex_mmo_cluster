# 只测试：另一角色（发布者、邻居）用 World 单元测试的角色替身（VoxelRegion.TestSupport.Actor）。
Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule NpcServer.NpcWorld do
  @moduledoc """
  只测试：gather 与 Settler 的集成 / 浸泡用例共用的真实世界夹具（npc_gather_test、npc_settler_test、
  npc_settler_soak_test）。真实 `VoxelRegion.World`（文件世界 + 属性目录 + prefab 结构 LOD）、真实 Scene / Player /
  P1 NIF、真实 `Session.Claims`；NPC 的 Body 起在测试自己的 DynamicSupervisor 下（崩溃即按 transient 重启）。

  世界是作者写入的平地（世界 y ≤ 63 实心，石料 11），x、z 各 −64..127。属性目录：材料 0..23 同一组基础属性
  （HP 100、防御 2），一把镐（tool 1：伤害 30 − 2 = 28，一格石料 4 击；射程 6 米、间隔 0.5 秒）；生产材料只有石料。
  有限样本（采石堆、余额）只经作者入口（`World.apply_edits/2`、`World.material_supply/4`）一次写入并记账。
  `start/1` 断言采石前提（设计稿 §11 I3 第 7 步）：石料是本世界的生产材料、目录里没有 drop_table（否则挖掉不入账）。
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]
  import ExUnit.Assertions, only: [assert: 1]
  alias MmoContracts.Voxel.Codec
  alias SceneServer.Movement.Scene
  alias VoxelRegion.{FileStore, World}
  alias VoxelRegion.TestSupport.Actor

  @cv 0x2233_4455_6677_8899
  @stone 11

  defmodule Route do
    @moduledoc "只测试：唯一 Scene 1 的路由。"
    def route(1),
      do:
        {:ok,
         %{
           scene_ref: Process.whereis(:npc_fixture_scene),
           world_ref: Process.whereis(:npc_fixture_world),
           scene_epoch: 7
         }}
  end

  defmodule Memory do
    @moduledoc "只测试：长期记忆替身；Runtime 给每个技能终态记一笔经历，这里只收下。"
    def journal(_cid, _text, _place), do: :ok
  end

  @doc """
  起 World、Scene、Claims。opts：`prefab_access: true` 写入 L1–L5 结构 LOD（prefab 放置要读）；
  `prefabs: [字节]` 作为作者目录（World 启动时载入）。返回 `%{world, scene, claims, root}`。
  """
  def start(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "npc_fixture_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    write_levels(root, if(opts[:prefab_access], do: 0..5, else: 0..0))

    for bytes <- Keyword.get(opts, :prefabs, []),
        do: File.write!(Path.join([root, "prefabs", hex(bytes) <> ".vxpd"]), bytes)

    catalog = Path.join(root, "properties.json")

    File.write!(
      catalog,
      Jason.encode!(%{
        schema_version: 1,
        tags: [%{id: "damage"}],
        materials:
          for(
            id <- 0..23,
            do: %{
              material_id: id,
              max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0),
              defense: 2.0,
              tags: [],
              responses: [%{action: "damage", multiplier: 1.0}]
            }
          ),
        tools: [
          %{
            id: "pickaxe",
            tool_id: 1,
            action: "damage",
            power: 30.0,
            range_macro: 6.0,
            interval_seconds: 0.5
          }
        ],
        definitions: []
      })
    )

    world =
      start_supervised!(
        {World,
         root: root,
         name: :npc_fixture_world,
         property_catalog_path: catalog,
         prefab_catalog_path: Path.join(root, "prefabs"),
         production_materials: [@stone]}
      )

    profile =
      Path.expand("../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    body_store = start_supervised!({MmoTest.BodyStore, []})

    scene =
      start_supervised!(
        {Scene,
         [
           name: :npc_fixture_scene,
           scene_id: 1,
           scene_epoch: 7,
           world_ref: world,
           body_store: {MmoTest.BodyStore, store: body_store},
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

    claims = start_supervised!({WorldServer.Session, route_module: Route})

    # 采石前提：挖掉的格只有生产材料、且没有 drop_table 时才按 cost 入账（voxel_region world/tools.ex 的结算分支）。
    assert(Enum.any?(World.material_balances(world, 1), &(&1.material == @stone)))
    assert(Map.fetch!(World.material_catalog(world).materials, @stone)["drops"] == nil)

    %{world: world, scene: scene, claims: claims, root: root}
  end

  @doc """
  作者保证（设计稿 §8.2 移动范围）：各工地站位与各采石盒站位（`Blueprint.stands/2`）两两水平距离不超过
  `Perception.reach()`。Settler 的多轮与浸泡用例共用。
  """
  def assert_stands_within_reach(sites, quarries) do
    quarry_stands =
      for {material, %{box: [lo, hi]}} <- quarries,
          stand <-
            NpcServer.Blueprint.stands(
              %{List.to_tuple(lo) => material, List.to_tuple(hi) => material},
              {0, 0, 0}
            ),
          do: stand

    stands = Enum.map(sites, fn %{stand: [x, z]} -> {x, z} end) ++ quarry_stands

    for {x0, z0} <- stands, {x1, z1} <- stands do
      assert(:math.sqrt((x1 - x0) ** 2 + (z1 - z0) ** 2) <= NpcServer.Perception.reach())
    end
  end

  @doc "在测试自己的 DynamicSupervisor 下起一个 NPC Body；返回 `%{sup, body}`。opts 覆盖默认的 cid / spawn。"
  def body(fixture, brain, opts \\ []) do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, body} =
      DynamicSupervisor.start_child(
        sup,
        {NpcServer.Body,
         claims: fixture.claims,
         route_module: Route,
         scene_id: 1,
         cid: Keyword.get(opts, :cid, 9101),
         bounds: {{-60, 40, -60}, {60, 120, 60}},
         spawn: Keyword.get(opts, :spawn, {4.0, 66.0, 10.0}),
         brain: brain}
      )

    %{sup: sup, body: body}
  end

  @doc "监督者下当前的 Body（重启后是新进程）。"
  def current_body(sup) do
    [{_, body, _, _}] = DynamicSupervisor.which_children(sup)
    body
  end

  @doc "World 单元测试的角色替身（不是被测主体）：发布 prefab、放置邻居的格时用。"
  def actor(cid, eye) do
    actor = %{
      cid: cid,
      gate: self(),
      identity: {:stand_in, cid},
      refresh: &Actor.tool_context/2,
      eye: eye,
      tick_us: 16_667
    }

    Map.put(
      actor,
      :player,
      start_supervised!(Supervisor.child_spec({Actor, actor}, id: {:actor, cid}))
    )
  end

  @doc "VXPD 定义的内容寻址 id（十六进制，World 目录同一键）。"
  def hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes))

  @doc "条件成立前每 100 ms 再查一次；超时断言失败。"
  def await(fun, timeout_ms \\ 10_000),
    do: await_until(fun, System.monotonic_time(:millisecond) + timeout_ms)

  defp await_until(fun, deadline) do
    case fun.() do
      value when value in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: ExUnit.Assertions.flunk("condition not reached")

        Process.sleep(100)
        await_until(fun, deadline)

      value ->
        value
    end
  end

  @doc "World 的逐格只读投影（material_snapshot 的 probe_occupancy 行，按格索引）。"
  def cells(world, cells),
    do:
      Map.new(
        World.material_snapshot(world, [], cells).probe_occupancy,
        &{List.to_tuple(&1.cell), &1}
      )

  @doc "角色某材料的 World 余额。"
  def balance(world, cid, material \\ @stone),
    do: Enum.find(World.material_balances(world, cid), &(&1.material == material)).balance

  # 本地索引含一圈 ring（索引 0 是 region 下方一格）。L0 两层 region：下层世界 y −1..63 实心，上层只有 ring（世界 y 63）；
  # L1–L5 按各层尺度给出同一 y < 64 平地（同 npc_body_world_test 的 prefab_access 基线）。
  defp write_levels(root, levels) do
    for level <- levels, y <- if(level == 0, do: 0..1, else: -1..1) do
      scale = Integer.pow(2, level)

      # 同一层、同一 region y 的格内容相同，算一次写 9 个 region。
      cells =
        for _ <- 0..65,
            ly <- 0..65,
            _ <- 0..65,
            into: <<>>,
            do: <<if((y * 64 + ly - 1) * scale < 64, do: @stone, else: 0)::16-little>>

      for x <- -1..1, z <- -1..1 do
        path = FileStore.path(root, @cv, level, {x, y, z})
        File.mkdir_p!(Path.dirname(path))

        bytes =
          if level == 0,
            do: Codec.encode_payload(0, {x, y, z}, 0, @cv, l0_body(cells)),
            else:
              MmoContracts.Voxel.Payload.encode(
                %MmoContracts.Voxel.Payload{level: level, region: {x, y, z}, cells: cells},
                %{},
                0,
                @cv
              )

        File.write!(path, bytes)
      end
    end
  end

  defp l0_body(cells) do
    skins =
      <<66::32-little, 66::32-little, 66::32-little, 1::32-little, 0::32-little, 0::32-little,
        0::32-little, 0::32-little, 0::32-little>>

    <<66 * 66 * 66::32-little, cells::binary, skins::binary>>
  end
end

defmodule NpcServer.NpcWorld.LogTap do
  @moduledoc """
  只测试：把 NPC 运行日志里指定前缀的行原样转给测试进程（`{:npc_log, 行}`），供多轮与浸泡用例按行计数；
  不改变被测进程的行为。
  """
  @prefixes ~w(npc_settler_idle character_intent npc_skill_outcome npc_session_lost npc_intent_rejected npc_move_rejected npc_claim_failed)

  def log(%{msg: {:string, text}}, %{config: %{owner: owner}}) do
    text = IO.chardata_to_string(text)
    if String.starts_with?(text, @prefixes), do: send(owner, {:npc_log, text})
    :ok
  end

  def log(_event, _config), do: :ok

  @doc "开 info 级日志并挂上转发；控制台默认 handler 仍只打 warning 以上。测试结束时还原。"
  def attach do
    level = Logger.level()
    {:ok, %{level: console}} = :logger.get_handler_config(:default)
    Logger.configure(level: :info)
    :ok = :logger.update_handler_config(:default, :level, :warning)
    :ok = :logger.add_handler(:npc_log_tap, __MODULE__, %{level: :info, config: %{owner: self()}})

    ExUnit.Callbacks.on_exit(fn ->
      :logger.remove_handler(:npc_log_tap)
      :logger.update_handler_config(:default, :level, console)
      Logger.configure(level: level)
    end)
  end
end
