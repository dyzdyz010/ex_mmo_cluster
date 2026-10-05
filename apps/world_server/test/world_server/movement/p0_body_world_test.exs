Code.require_file("../../support/movement_fixture.exs", __DIR__)
Code.require_file("../../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule WorldServer.Movement.P0BodyWorldTest do
  @moduledoc """
  只测试：真实 World、CollisionStream、Scene、Player、Native 与 PostgreSQL 的身体接缝。
  空白 Source 仅替代地形生成；地板/水槽经作者入口一次安装、食物经记账供给后走正式 production_intent。
  不注入在线身体、余额或营养结果，不证明地形生成、QUIC 或真实双客户端验收。
  """
  use ExUnit.Case, async: false
  alias MmoContracts.{Session, Movement}
  alias SceneServer.Movement.{Scene, Player}
  alias SceneServer.Body
  alias VoxelRegion.World

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @units 262_144
  @energy 75_362.4
  @box {{0, 0, 0}, {1, 1, 1}}

  setup context do
    MmoTest.Database.start!()
    DataService.Voxel.OverlayLogStore.reset()
    base = WorldServer.MovementFixture.prepare()
    root = Path.join(base, "body-world")
    File.mkdir_p!(root)

    catalog =
      Path.expand("../../../../voxel_region/test/fixtures/combustion/#{@catalog}.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    # 有限作者食物样本：沿用已验证的 40 g 蒲公英份额（1.08 g 蛋白、18 kcal）。
    catalog =
      Map.update!(catalog, "materials", fn rows ->
        Enum.map(rows, fn row ->
          if row["material_id"] == 36,
            do: Map.put(row, "food", %{"protein_g" => 1.08, "energy_j" => @energy}),
            else: row
        end)
      end)

    path = Path.join(root, "properties.json")
    File.write!(path, Jason.encode!(catalog))

    opts = [
      name: nil,
      source: VoxelRegion.TestSupport.Source,
      observer: self(),
      root: root,
      log: VoxelRegion.OverlayLog.Db,
      property_catalog_path: path,
      production_materials: [36],
      liquid_bounds: {{0, 0, 0}, {16, 16, 16}}
    ]

    opts =
      if context[:thermal] do
        environment = Path.join(root, "environment.json")

        File.write!(
          environment,
          Jason.encode!(%{
            ambient_kelvin: 293.15,
            environment_w_per_m2_k: 0.0,
            tolerance_kelvin: 0.01,
            emissivity: 0.0,
            view_range_cells: 8,
            circuit_min_power_w: 1.0
          })
        )

        Keyword.put(opts, :thermal_environment_path, environment)
      else
        opts
      end

    world = start_supervised!({World, opts})
    floor = for x <- 0..15, z <- 0..15, do: {{x, 3, z}, 11}

    walls =
      if context[:thermal] do
        for(x <- 3..12, z <- [5, 7], y <- 4..5, do: {{x, y, z}, 11}) ++
          for x <- [3, 12], y <- 4..5, do: {{x, y, 6}, 11}
      else
        []
      end

    {:ok, _} = World.apply_edits(world, floor ++ walls)

    if context[:thermal] do
      water = Path.join(root, "basin.json")

      File.write!(
        water,
        Jason.encode!(%{
          classification: "Test-only",
          deposits: for(x <- 4..11, y <- 4..5, do: %{macro: [x, y, 6], material: 21})
        })
      )

      {:ok, _} = World.liquid_experiment(world, water)
    end

    cid = System.unique_integer([:positive]) + 800_000
    {:ok, _} = World.material_supply(world, cid, "p0-body-food-author", %{36 => @units})
    raw = File.read!(base <> "/Voxim/Docs/M1/fixtures/demo-config.json") |> Jason.decode!()

    config =
      Map.merge(raw, %{
        "l0_min" => [0, 0, 0],
        "l0_max_exclusive" => [1, 1, 1],
        "travel_min_m" => [2, 2, 2],
        "travel_max_exclusive_m" => [14, 14, 14],
        "spawn_probes_m" => [[6.5, 10, 6.5]],
        "spawn_min_y_m" => 3
      })

    %{world: world, cid: cid, config: config}
  end

  defp scenes(ctx, streaming) do
    origin = System.system_time(:microsecond)

    for id <- 1..if(streaming, do: 2, else: 1) do
      config =
        if streaming do
          ctx.config
          |> Map.put("collision_window_radius_tiles", 1)
          |> Map.put("spawn_probes_m", [[if(id == 1, do: 6.5, else: 9.5), 10, 6.5]])
          |> Map.update!(
            if(id == 1, do: "travel_max_exclusive_m", else: "travel_min_m"),
            fn [_, y, z] -> [8, y, z] end
          )
        else
          ctx.config
        end

      replica =
        start_supervised!(
          Supervisor.child_spec(
            {VoxelRegion.Replica, [authority_ref: ctx.world, l0_box: @box, name: nil]},
            id: {:replica, id}
          )
        )

      scene =
        start_supervised!(
          Supervisor.child_spec(
            {Scene,
             [
               scene_id: id,
               scene_epoch: 1,
               world_ref: replica,
               world_api: VoxelRegion.Replica,
               config: config,
               timeline_origin_us: origin
             ]},
            id: {:scene, id}
          )
        )

      await(fn -> Scene.observe(scene).initialized end)
      scene
    end
  end

  defp join(scene, cid, epoch, scene_id \\ 1) do
    identity = %Session.Identity{session_epoch: epoch, scene_id: scene_id, scene_epoch: 1}
    {:ok, player} = Scene.join(scene, identity, %{id: cid}, self())
    assert_receive {:mmo_reliable, ^identity, 1, %Session.SessionStart{} = start}, 10_000
    assert_receive {:mmo_reliable, ^identity, 2, %MmoContracts.Voxel.CanonicalBootstrap{}}, 10_000
    Player.time_probe(player, identity, %Session.TimeProbe{request_id: 1, client_send_us: 1})
    Player.ready(player, identity, start.baseline_transaction_seq, start.collision_revision)
    assert_receive {:mmo_reliable, ^identity, 1, %Session.InputStart{}}, 3_000
    {player, identity}
  end

  defp eat(world, player, identity) do
    {:ok, actor} = Player.tool_context(player, identity)

    World.production_intent(world, actor, %{
      request_id: 10,
      client_intent_seq: 10,
      logical_scene_id: identity.scene_id,
      action: 5,
      coord: {0, 0, 0},
      tool_id: 1,
      material: 36
    })
  end

  @tag :thermal
  @tag timeout: 60_000
  test "真实进食与水接触后正常越界：seal/activate 原样移交身体、收据游标和待吸收热", ctx do
    [a, b] = scenes(ctx, true)
    previous = Application.get_env(:world_server, :movement_routes)

    Application.put_env(:world_server, :movement_routes, %{
      1 => %{scene_ref: a, world_ref: ctx.world, scene_epoch: 1},
      2 => %{scene_ref: b, world_ref: ctx.world, scene_epoch: 1}
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:world_server, :movement_routes, previous),
        else: Application.delete_env(:world_server, :movement_routes)
    end)

    :ok = WorldServer.Movement.connect_neighbours(1, 2)
    {source, old} = join(a, ctx.cid, 10)
    {:ok, food_seq} = eat(ctx.world, source, old)
    await(fn -> Player.body_snapshot(source).food_cursors[123] == food_seq end)

    frames =
      for seq <- 1..120,
          do: %Movement.InputFrame{
            input_seq: seq,
            axis_x: if(seq <= 60, do: 32767, else: 0),
            axis_z: 0,
            yaw: 0,
            jump_pressed: 0
          }

    Player.input(source, old, %Movement.InputBatch{identity: old, frames: frames})
    assert_receive {:mmo_transfer_request, ^old, ^source, 2}, 5_000

    # 源进入 requested 后身体不再按秒演进；真实 World 再走一段，seal 必须等该段热消息后的 fence。
    send(ctx.world, :thermal_commit)
    World.seq(ctx.world)
    assert {:ok, cut} = Player.seal(source, old)
    assert cut.body_heat.q_j < 0
    assert cut.food_cursors == %{123 => food_seq}

    assert cut.body_exchange_j ==
             World.simulation_snapshot(ctx.world, [ctx.cid], @box).thermal_accounting.body_exchange_j

    saved = Body.Snapshot.take(cut)
    next = %Session.Identity{session_epoch: 11, scene_id: 2, scene_epoch: 1}

    # 暂停 World 仅控制消息时序：prepared/activate 不得同步反调 World，也不得提前推进身体。
    :ok = :sys.suspend(ctx.world)

    try do
      assert {:ok, target} = WorldServer.Movement.prepare_transfer(old, next, cut, self())
      assert Player.body_snapshot(target) == saved
      refute Player.observe(target).active
      assert :ok = WorldServer.Movement.commit_transfer(old, next)
      assert Player.body_snapshot(target) == saved
      refute Process.alive?(source)
      assert Scene.observe(a).character_count == 0
      assert Scene.observe(b).character_count == 1
      :ok = :sys.resume(ctx.world)
      send(ctx.world, :thermal_commit)
      World.seq(ctx.world)
      await(fn -> Player.body_snapshot(target).body_exchange_j < saved.body_exchange_j end)
      assert Player.body_snapshot(target).food_cursors == %{123 => food_seq}
    after
      if Process.alive?(ctx.world), do: :sys.resume(ctx.world)
    end
  end

  @tag timeout: 60_000
  test "真实扣料已commit但Scene尚未投递时Player退出，重新入场从World快照吸收且只吸收一次", ctx do
    [scene] = scenes(ctx, false)
    {player, old} = join(scene, ctx.cid, 20)
    before = Player.body_snapshot(player)
    :ok = :sys.suspend(scene)

    try do
      assert {:ok, food_seq} = eat(ctx.world, player, old)
      assert [%{balance: 0}] = World.material_balances(ctx.world, ctx.cid)
      assert Player.body_snapshot(player) == before
      monitor = Process.monitor(player)
      Process.exit(player, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^player, :killed}
      :ok = :sys.resume(scene)
      await(fn -> Scene.observe(scene).character_count == 0 end)
      {restored, current} = join(scene, ctx.cid, 21)
      saved = Player.body_snapshot(restored)
      assert saved.food_cursors == %{123 => food_seq}

      # 初始蛋白与糖原已满，目录这一份食物的全部能量进入脂肪；无热环境，无离线推进。
      assert saved.body == %{before.body | fat_reserve_j: before.body.fat_reserve_j + @energy}
      :ok = Scene.leave(scene, current)
      :ok = World.compact(ctx.world)
      {again, _} = join(scene, ctx.cid, 22)
      assert Player.body_snapshot(again) == saved
    after
      if Process.alive?(scene), do: :sys.resume(scene)
    end
  end

  defp await(fun, left \\ 5_000) do
    unless fun.() do
      assert left > 0
      Process.sleep(10)
      await(fun, left - 10)
    end
  end
end
