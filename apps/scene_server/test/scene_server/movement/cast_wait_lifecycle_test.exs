defmodule SceneServer.Movement.CastWaitLifecycleTest do
  @moduledoc """
  只测试：真实Player→World异步施法等待。World经作者编辑、File压实和重启形成冷页；
  Player经正常构造、权威快照anchor和Ready启动。Scene时间线与网络Sink是静止依赖，
  身体存储为本例Agent；不验证移动、鉴权、PG或QUIC。读闸只延迟真实File页读取。
  """
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Player, Scene, CollisionUpdates, Replication}
  alias MmoContracts.Session
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, SimulationIoLog}
  Code.require_file("../../../../voxel_region/test/support/world_fixtures.exs", __DIR__)
  Code.require_file("../../../../voxel_region/test/support/simulation_io_log.exs", __DIR__)

  @fixtures Path.expand("../../../../voxel_region/test/fixtures", __DIR__)
  @material "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "41d668f375b795ce9129dd3bbc1f9c70ce70278ded49f39c2441ccc540386bde"
  @cold {0, {2, 0, 0}}
  @box {{0, 0, 0}, {1, 1, 1}}

  defmodule Clock do
    def now(_), do: 0
    def schedule(_, _, _), do: :ok
  end

  defmodule Sink do
    def reliable(pid, _, _, event), do: send(pid, {:wire, event})
    def datagram(_, _, _), do: :ok
    def close(_, _, _), do: :ok
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "cast_wait_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "prefabs"))

    material = Path.join([@fixtures, "combustion", @material <> ".json"])

    # 用例可用 `@tag holdables:` 给材料夹具加持物表（法杖普攻 basic_spell + basic_windup_s）；默认原字节。
    case context do
      %{holdables: rows} ->
        properties = Map.put(Jason.decode!(File.read!(material)), "holdables", rows)
        File.write!(Path.join(root, "properties.json"), Jason.encode!(properties))

      _ ->
        File.cp!(material, Path.join(root, "properties.json"))
    end

    File.cp!(
      Path.join([@fixtures, "combustion", "environment-radiation.json"]),
      Path.join(root, "environment.json")
    )

    # 用例可用 `@tag magic:` 换魔法目录（光弹需要含拟态的现行目录）；默认增量 1 目录。
    File.cp!(
      Path.join([@fixtures, "magic", Map.get(context, :magic, @magic) <> ".json"]),
      Path.join(root, "magic.json")
    )

    opts = [
      name: nil,
      root: root,
      observer: self(),
      source: Source,
      log: SimulationIoLog,
      property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"),
      magic_catalog_path: Path.join(root, "magic.json"),
      prefab_catalog_path: Path.join(root, "prefabs")
    ]

    world = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edits(world, for(x <- 38..42, z <- 6..10, do: {{x, 8, z}, 11}))
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    parent = self()

    spawn(fn ->
      ref = make_ref()
      :ok = World.canonical_snapshot_and_subscribe(world, @box, self(), ref)

      receive do
        {:canonical_snapshot, ^ref, snapshot} -> send(parent, {:fixture_snapshot, snapshot})
      end
    end)

    assert_receive {:fixture_snapshot, snapshot}, 10_000

    profile =
      File.read!(Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__))
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    config_path = Path.join(root, "movement.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        schema: "voxim-m1-demo-v1",
        l0_min: [0, 0, 0],
        l0_max_exclusive: [1, 1, 1],
        travel_min_m: [1, 1, 1],
        travel_max_exclusive_m: [63, 20, 20],
        spawn_probes_m: [[40.5, 12, 8.5]],
        spawn_min_y_m: 6,
        profile: profile
      })
    )

    config = Scene.load_config!(config_path)

    updates =
      CollisionUpdates.new(SceneServer.Native.VoximMovement)
      |> CollisionUpdates.initialize(snapshot)

    store = start_supervised!({MmoTest.BodyStore, []})
    replication = start_supervised!({Replication, [sink: Sink]})
    identity = %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 1}

    player =
      start_supervised!(
        {Player,
         [
           scene: self(),
           gate: self(),
           replication: replication,
           identity: identity,
           id: 1001,
           epoch: 1,
           kind: 0,
           slot: 0,
           probe: hd(config.probes),
           config: config,
           updates: updates,
           clock: {Clock, nil},
           time_origin: 0,
           time_mono_origin: 0,
           mono_origin: 0,
           sink: Sink,
           body_store: {MmoTest.BodyStore, store: store},
           scene_id: 1,
           scene_epoch: 1,
           content_version: snapshot.content_version,
           authority_ref: world
         ]}
      )

    send(player, {:anchor, 0, updates, snapshot.content_version, snapshot})
    assert_receive {:wire, %Session.SessionStart{} = session}, 2_000
    Player.ready(player, identity, session.baseline_transaction_seq, session.collision_revision)
    assert {:ok, _} = Player.tool_context(player, identity)
    refute VoxelRegion.World.Pages.resident?(:sys.get_state(world), @cold)

    on_exit(fn ->
      SimulationIoLog.clear()
      File.rm_rf!(root)
    end)

    %{world: world, player: player, identity: identity, root: root, config: config}
  end

  defp await(fun, left \\ 100)

  defp await(fun, left) when left > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, left - 1)
        )
  end

  defp await(_fun, 0), do: flunk("请求生命周期没有达到应有终态")

  defp request(action \\ 1),
    do: %{
      action: action,
      client_intent_seq: 1,
      request_id: 1,
      direction: {1.0, 0.0, 0.0},
      catalog_digest: Base.decode16!(@magic, case: :lower),
      program: "{}"
    }

  test "冷页cast的waiter退出释放Player动作，另一公共请求共享reader继续", c do
    SimulationIoLog.mode(:hold, self(), @cold)

    waiter =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Player.cast_spell(
      c.player,
      c.identity,
      request(),
      %{caster_recipient: {self(), make_ref()}},
      {waiter, make_ref()}
    )

    assert_receive {:simulation_io_read, reader, @cold}, 2_000
    reader_ref = Process.monitor(reader)
    assert {:error, :casting} = Player.tool_context(c.player, c.identity)
    query = Task.async(fn -> World.material_snapshot(c.world, [], [{64, 0, 0}]) end)
    await(fn -> World.stats(c.world).page_waiters == 2 end)
    Process.exit(waiter, :kill)
    await(fn -> match?({:ok, _}, Player.tool_context(c.player, c.identity)) end)
    refute_receive {:DOWN, ^reader_ref, :process, ^reader, _}, 0
    SimulationIoLog.clear()
    send(reader, :continue)
    assert %{probe_occupancy: [%{cell: [64, 0, 0], material: 0}]} = Task.await(query, 5_000)

    await(fn ->
      World.stats(c.world).page_loads == 0 and World.admission_status(c.world).held_sequences == 0
    end)
  end

  test "Player在begin_cast前退出时终止无其他需求的冷页reader", c do
    SimulationIoLog.mode(:hold, self(), @cold)

    Player.cast_spell(
      c.player,
      c.identity,
      request(),
      %{caster_recipient: {self(), make_ref()}},
      {self(), make_ref()}
    )

    assert_receive {:simulation_io_read, reader, @cold}, 2_000
    ref = Process.monitor(reader)
    Process.exit(c.player, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reader, _}, 2_000

    await(fn ->
      World.stats(c.world).page_loads == 0 and World.admission_status(c.world).held_sequences == 0
    end)
  end

  test "无动作槽的quote等待者退出也退休冷页需求", c do
    SimulationIoLog.mode(:hold, self(), @cold)
    waiter = spawn(fn -> Player.spell(c.player, c.identity, request(0), %{}) end)
    assert_receive {:simulation_io_read, reader, @cold}, 2_000
    ref = Process.monitor(reader)
    assert {:ok, _} = Player.tool_context(c.player, c.identity)
    assert Player.observe(c.player).pending_spell_requests == 1
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^ref, :process, ^reader, _}, 2_000

    await(fn ->
      Player.observe(c.player).pending_spell_requests == 0 and
        World.stats(c.world).page_waiters == 0
    end)
  end

  test "公共spell显式等待超时后caller仍活，原请求取消且后续quote正常回到caller", c do
    SimulationIoLog.mode(:hold, self(), @cold)
    parent = self()

    waiter =
      spawn(fn ->
        result =
          try do
            Player.spell(c.player, c.identity, request(0), %{}, 100)
          catch
            :exit, {:timeout, _} -> :timed_out
          end

        send(parent, {:quote_timeout, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:simulation_io_read, reader, @cold}, 2_000
    ref = Process.monitor(reader)
    assert_receive {:quote_timeout, ^waiter, :timed_out}, 2_000
    assert Process.alive?(waiter)
    assert_receive {:DOWN, ^ref, :process, ^reader, _}, 2_000

    await(fn ->
      Player.observe(c.player).pending_spell_requests == 0 and
        World.stats(c.world).page_waiters == 0
    end)

    SimulationIoLog.clear()

    program =
      Jason.encode!(%{
        v: 1,
        target: %{kind: "aim"},
        emit: "at_target",
        steps: [%{sym: "energy.draw", args: %{energy_j: 1000}}]
      })

    assert {:ok, %{outcome: nil}} =
             Player.spell(
               c.player,
               c.identity,
               %{request(0) | program: program},
               %{caster_recipient: {self(), make_ref()}},
               5_000
             )

    assert Player.observe(c.player).pending_spell_requests == 0
    send(waiter, :stop)
  end

  test "准备前正常取消也释放读闸，并只给原施放一次取消结果", c do
    SimulationIoLog.mode(:hold, self(), @cold)
    tag = make_ref()

    Player.cast_spell(
      c.player,
      c.identity,
      request(),
      %{caster_recipient: {self(), make_ref()}},
      {self(), tag}
    )

    assert_receive {:simulation_io_read, reader, @cold}, 2_000
    ref = Process.monitor(reader)
    assert {:ok, :controlled} = Player.spell(c.player, c.identity, request(2), %{})
    assert_receive {^tag, {:error, :cast_cancelled}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^reader, _}, 1_000

    await(fn ->
      Player.observe(c.player).pending_spell_requests == 0 and
        World.admission_status(c.world).held_sequences == 0
    end)

    refute_receive {^tag, _}, 0
  end

  test "已接纳前摇的取消保留原开始事务，仅提交原业务终态并回复一次", c do
    {:ok, actor} = Player.tool_context(c.player, c.identity)

    query = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {0.0, -1.0, 0.0},
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    assert {:ok, target} = World.tool_intent(c.world, actor, query)

    program =
      Jason.encode!(%{
        v: 1,
        target: %{kind: "aim"},
        emit: "at_target",
        steps: [%{sym: "act.heat", args: %{energy_j: 400_000, power_w: 200_000}}]
      })

    request =
      request()
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{direction: {0.0, -1.0, 0.0}, program: program})

    before = World.seq(c.world)
    tag = make_ref()

    ingress = %{
      caster_recipient: {self(), make_ref()},
      received_us: System.monotonic_time(:microsecond),
      clock_node: node()
    }

    Player.cast_spell(c.player, c.identity, request, ingress, {self(), tag})
    await(fn -> Map.has_key?(World.simulation_snapshot(c.world, [1001], @box).casts, 1001) end)
    accepted = World.seq(c.world)
    assert accepted > before
    assert World.stats(c.world).page_waiters == 0

    assert {:ok, :controlled} =
             Player.spell(c.player, c.identity, %{request | action: 2}, ingress)

    assert_receive {^tag, {:error, :cast_cancelled}}, 1_000
    await(fn -> World.simulation_snapshot(c.world, [1001], @box).casts == %{} end)
    assert World.seq(c.world) > accepted
    assert Player.observe(c.player).pending_spell_requests == 0
    entries = World.entries_after(c.world, before)
    assert Enum.any?(entries, fn entry -> entry.seq == accepted end)
    refute_receive {^tag, _}, 0
  end

  # 法杖光弹不受战斗范围限制：本夹具的 Scene 配置没有 test_combat_bounds_m，`Scene.load_config!` 给出
  # combat_scope = nil，即战斗处处关闭（工具 22/23 的候选在 Scene.tool_candidates 被拒、人物受击在
  # Player.receive_effect 被拒）。施法链路 Player.cast_spell → World 没有战斗范围判定，所以同一个 Player
  # 照常前摇、结算并扣整数 cost_mj。光弹命中人物仍归投射物链路的 Harm 判定，不在本例范围。
  @bolt_magic "71ca543b42db5ca5b1b8fea62771aa0c256399b2fa00c0525eccb4d9953860a7"
  @tag magic: @bolt_magic
  test "战斗范围关闭（combat_scope nil）时法杖光弹照常施放：真实 Player 前摇后 World 结算并扣 cost_mj", c do
    assert c.config.combat_scope == nil
    refute SceneServer.Movement.Harm.open?(c.config.combat_scope)
    # 开户（玩家接纳同一出口）：497 084 850 mJ。
    assert {:ok, %{energy_j: 497_084.85}} =
             World.send_caster_state(c.world, 1001, 0, {self(), c.identity})

    program =
      Jason.encode!(%{
        v: 1,
        target: %{kind: "aim"},
        emit: "hand",
        steps: [
          %{
            sym: "form.semblance",
            args: %{
              shape: 0,
              radius_m: 0.05,
              mass_kg: 0.01,
              temperature_k: 293.15,
              glow_w: 100,
              lifetime_s: 1
            }
          },
          %{sym: "act.throw", args: %{speed_mps: 30}},
          %{sym: "act.break_on_hit", args: %{}}
        ]
      })

    # 朝下投向脚下地面石（准星方向与客户端同一表示）。
    request = %{
      request()
      | catalog_digest: Base.decode16!(@bolt_magic, case: :lower),
        direction: {0.0, -1.0, 0.0},
        program: program
    }

    ingress = %{
      caster_recipient: {self(), make_ref()},
      received_us: System.monotonic_time(:microsecond),
      clock_node: node()
    }

    tag = make_ref()
    started = System.monotonic_time(:millisecond)
    Player.cast_spell(c.player, c.identity, request, ingress, {self(), tag})

    # 本夹具没有持物表：前摇按成本模型 1.9299 s（独立复算）由 Player 的真实定时器推进。
    assert_receive {^tag, {:ok, %{outcome: nil, caster: caster}}}, 10_000
    assert System.monotonic_time(:millisecond) - started >= 1_930
    # 独立复算的光弹扣款 9 941 697 mJ：497 084 850 − 9 941 697 = 487 143 153 mJ。
    assert caster.spent_j == 9941.697
    assert caster.energy_j == 487_143.153
  end

  # 法杖普攻固定前摇（Voxim 交互设计"2026-11-20 修订"，用户定）：属性目录持物表声明光弹为 basic_spell、
  # basic_windup_s 0.3，同一程序经真实 Player 施放时 World 给 0.3 s，Player 定时器 ceil(0.3 × 1000) = 300 ms 后结算；
  # 扣款仍是成本模型的 9 941 697 mJ。上界 1 500 ms 远低于成本模型前摇 1 930 ms，旧规则会红。
  @tag magic: @bolt_magic
  @tag holdables: [
         %{
           "id" => "staff",
           "display_name" => "法杖",
           "basic_windup_s" => 0.3,
           "skill_tool_ids" => [],
           "basic_spell" => %{
             "v" => 1,
             "target" => %{"kind" => "aim"},
             "emit" => "hand",
             "steps" => [
               %{
                 "sym" => "form.semblance",
                 "args" => %{
                   "shape" => 0,
                   "radius_m" => 0.05,
                   "mass_kg" => 0.01,
                   "temperature_k" => 293.15,
                   "glow_w" => 100,
                   "lifetime_s" => 1
                 }
               },
               %{"sym" => "act.throw", "args" => %{"speed_mps" => 30}},
               %{"sym" => "act.break_on_hit", "args" => %{}}
             ]
           }
         }
       ]
  test "法杖普攻固定前摇：真实 Player 按 basic_windup_s 0.3 s 结算光弹，扣款仍 cost_mj", c do
    assert {:ok, %{energy_j: 497_084.85}} =
             World.send_caster_state(c.world, 1001, 0, {self(), c.identity})

    [%{"basic_spell" => spell}] = c.holdables

    request = %{
      request()
      | catalog_digest: Base.decode16!(@bolt_magic, case: :lower),
        direction: {0.0, -1.0, 0.0},
        program: Jason.encode!(spell)
    }

    ingress = %{
      caster_recipient: {self(), make_ref()},
      received_us: System.monotonic_time(:microsecond),
      clock_node: node()
    }

    tag = make_ref()
    started = System.monotonic_time(:millisecond)
    Player.cast_spell(c.player, c.identity, request, ingress, {self(), tag})
    assert_receive {^tag, {:ok, %{outcome: nil, caster: caster}}}, 10_000
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 300 and elapsed < 1_500
    assert caster.spent_j == 9941.697
    assert caster.energy_j == 487_143.153
  end
end
