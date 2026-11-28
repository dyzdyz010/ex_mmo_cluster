defmodule SceneServer.Movement.CastWaitLifecycleTest do
  @moduledoc """
  只测试：真实Player→World异步施法等待。World经作者编辑、File压实和重启形成冷页；
  Player经正常构造、权威快照anchor和Ready启动。Scene时间线与网络Sink是静止依赖，
  身体存储为本例Agent；不验证移动、鉴权、PG或QUIC。读闸只延迟真实File页读取。

  魔法目录是 v5 发布物 `voxel_region/priv/magic/<sha256>.json`，程序是 IR v2 样本字节（魔法 v2 切片 3，决策稿 S-1：
  Player 对程序内容不敏感，换目录后原断言不变）。出生点脚下 (40,8,8) 是蓄能石，作者初态 10 MJ 经持久化边界安装一次，
  使〈取〉的前摇没有预判中断（否则 World 会让 Player 在第 1 步时刻检查并结算，抢在取消之前）。
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
  @catalog Path.expand("../../../../voxel_region/priv/magic", __DIR__)
           |> Path.join("*.json")
           |> Path.wildcard()
           |> then(fn [path] -> path end)
  @ir Path.expand("../../../../voxel_region/test/fixtures/magic/ir-v2-samples.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
  @external_resource @catalog
  @battery {40, 8, 8}
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

    File.cp!(@catalog, Path.join(root, "magic.json"))

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

    floor =
      for x <- 38..42, z <- 6..10, do: {{x, 8, z}, if({x, 8, z} == @battery, do: 42, else: 11)}

    assert {:ok, _} = World.apply_edits(world, floor)
    stored = battery_row(world)
    assert :ok = World.compact(world)
    seq = World.seq(world)
    stop_supervised!(World)

    VoxelRegion.OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(stored, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

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

  # 作者初态用的蓄能石属性行：经正式工具查询取得（查询者在石上方 1.5 m 向下看）。
  defp battery_row(world) do
    scout = %{
      cid: 9,
      gate: self(),
      identity: make_ref(),
      refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {40.5, 10.5, 8.5},
      feet: {40.5, 9.0, 8.5},
      tick_us: 16_667
    }

    scout =
      Map.put(
        scout,
        :player,
        start_supervised!({VoxelRegion.TestSupport.Actor, scout}, id: :scout)
      )

    query = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {0.0, -1.0, 0.0},
      micro: {320, 64, 64},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    {:ok, row} = World.tool_intent(world, scout, query)
    row
  end

  defp program(id),
    do:
      Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

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

  # 0x82 解码形；程序取合法的灯（〈握〉，报价与施放都不求射线）。冷页用例里读闸挂起在解码之前。
  defp request(action \\ 1),
    do: %{
      action: action,
      client_intent_seq: 1,
      request_id: 1,
      logical_scene_id: 1,
      direction: {1.0, 0.0, 0.0},
      catalog_digest: :crypto.hash(:sha256, File.read!(@catalog)),
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0,
      program: program("lamp")
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

    assert {:ok, %{outcome: nil}} =
             Player.spell(
               c.player,
               c.identity,
               request(0),
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

    # 主动取消的原因串（魔法 v2 切片 6，决策稿 Q6-4）；World 尚未接纳前摇，k = 0 免费。
    assert_receive {^tag, {:error, :interrupted_cancelled}}, 1_000
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

    # 脚下蓄能石取能 1 MJ：可用资金 = 余额 0 + η·1 MJ，足够付构型损耗，前摇没有预判中断。
    request =
      request()
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.merge(%{direction: {0.0, -1.0, 0.0}, program: program("draw_1mj")})

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

    # 已接纳前摇后的取消由 World 结账并给出唯一回复（魔法 v2 切片 6，决策稿 §6.1）：取消通常落在第 1 步调整段（0.13 s）内，
    # k = 0 免费回 interrupted_cancelled；机器很慢、越过调整段时 k = 1，按第 1 步中断结账（余额 0，扣 0）回同一原因的结算。
    assert_receive {^tag, result}, 1_000

    assert match?({:error, :interrupted_cancelled}, result) or
             match?({:ok, %{outcome: :interrupted_cancelled, fail_step: 1}}, result)

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
  # 照常前摇并交 World 结算（切片 4c 起结构建成回 {:ok, outcome nil}，取能回 :ok 并按整数 mJ 入账）。
  @bolt_hex "020101000700010002000032000000000000010010006401001b06ce01001e7530010001002201002c00"
  test "战斗范围关闭（combat_scope nil）时法杖光弹与取能照常前摇：真实 Player 按成本模型前摇并交 World 结算", c do
    assert c.config.combat_scope == nil
    refute MmoContracts.Harm.open?(c.config.combat_scope)
    # 开户（玩家接纳同一出口）：497 084 850 mJ。
    assert {:ok, %{energy_j: 497_084.85}} =
             World.send_caster_state(c.world, 1001, 0, {self(), c.identity})

    bolt_bytes = Base.decode16!(@bolt_hex, case: :lower)

    # 朝下投向脚下地面石（准星方向与客户端同一表示）；无 holdables 表，前摇按成本模型 1.1840 s。
    request = %{
      request()
      | direction: {0.0, -1.0, 0.0},
        program: bolt_bytes
    }

    ingress = %{
      caster_recipient: {self(), make_ref()},
      received_us: System.monotonic_time(:microsecond),
      clock_node: node()
    }

    tag = make_ref()
    started = System.monotonic_time(:millisecond)
    Player.cast_spell(c.player, c.identity, request, ingress, {self(), tag})

    # 同一程序、本夹具没有持物表：World 判定不是持物普攻，Player 的前摇仍受移动打断（用户 2026-11-26 裁定只豁免持物普攻）。
    await(fn ->
      match?(%{phase: :windup, basic_attack: false}, :sys.get_state(c.player).action)
    end)

    # 本夹具没有持物表：前摇按 v2 成本模型 1.1840 s 由 Player 真实定时器推进；切片 4c 起结构建成。
    assert_receive {^tag, {:ok, %{outcome: nil}}}, 10_000
    assert System.monotonic_time(:millisecond) - started >= 1_180
  end

  # 法杖普攻固定前摇（Voxim 交互设计"2026-11-20 修订"，用户定；魔法 v2 切片 3 迁至 IR v2）：属性目录持物表声明
  # IR v2 光弹为 basic_spell、basic_windup_s 0.3，同一程序经真实 Player 施放时 World 给 0.3 s，Player 定时器
  # ceil(0.3 × 1000) = 300 ms 后交 World 结算。上界 1 000 ms 低于成本模型前摇 1 184 ms，旧规则会红。
  # 光弹为切片 5b 的无质量程序（〈蓄〉1742 J）；物品目录夹具在客户端重新发布前仍是旧程序，所以这里用测试内持物表。
  @tag holdables: [
         %{
           "id" => "staff",
           "display_name" => "法杖",
           "basic_windup_s" => 0.3,
           "skill_tool_ids" => [],
           "basic_spell" =>
             "020101000700010002000032000000000000010010006401001b06ce01001e7530010001002201002c00"
         }
       ]
  test "法杖普攻固定前摇：真实 Player 按 basic_windup_s 0.3 s 完成 IR v2 光弹前摇", c do
    assert {:ok, %{energy_j: 497_084.85}} =
             World.send_caster_state(c.world, 1001, 0, {self(), c.identity})

    [%{"basic_spell" => hex}] = c.holdables

    request = %{
      request()
      | direction: {0.0, -1.0, 0.0},
        program: Base.decode16!(hex, case: :lower)
    }

    ingress = %{
      caster_recipient: {self(), make_ref()},
      received_us: System.monotonic_time(:microsecond),
      clock_node: node()
    }

    tag = make_ref()
    started = System.monotonic_time(:millisecond)
    Player.cast_spell(c.player, c.identity, request, ingress, {self(), tag})

    # 真实 World 按持物表判定为持物普攻，经前摇计划交给真实 Player（免除移动打断，用户 2026-11-26 裁定）。
    await(fn ->
      match?(%{phase: :windup, basic_attack: true}, :sys.get_state(c.player).action)
    end)

    assert_receive {^tag, {:ok, %{outcome: nil}}}, 10_000
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 300 and elapsed < 1_000
  end

  # S7-1（魔法 v2 切片 7，决策稿 Q7-1）：在场只由 Scene 推送。真实 Player 在会话就绪（setup 里的 `Player.ready/4`）时经公共 API
  # `World.caster_presence/3` 推 :present，会话解除（`Player.stop/1` → 身体解除）时推 :absent；World 只读自己的在场集合。
  test "S7-1 Player 会话就绪 → World 在场集合含该角色；会话解除 → 在场集合缩小", c do
    present = fn -> World.stats(c.world).magic_admission.present end
    await(fn -> present.() == [1001] end)
    assert :ok = Player.stop(c.player)
    await(fn -> present.() == [] end)
  end
end
