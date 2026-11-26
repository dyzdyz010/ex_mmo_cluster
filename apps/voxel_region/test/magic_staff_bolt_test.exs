defmodule VoxelRegion.MagicStaffBoltTest do
  @moduledoc """
  只测试：法杖普攻光弹迁至魔法 v2（IR v2 + 目录 v5）后在真实 World 里的报价、0.3 s 固定前摇、服务器时间线
  `MmoContracts.ServerTime`、整数 mJ 施法者账、开户一次性充能、分阶段中断、旧浮点余额迁移兼容、取能整数分账
  与投射物结果日志标签回归。

  契约：
  - 持物 `holdables[].basic_spell` 为规范小写十六进制 IR v2 字节，在 `Damage.load/1` 加载边界解码；
    `World.Casting.basic_windup/3` 按规范字节相等覆盖前摇为 `basic_windup_s`（0.3 s）并等比缩放广播各步时长，
    成本（`total_mj`、`steps[].spent_mj`）不变；差 1 字节的非普攻程序照常按成本模型前摇。
  - 施法者账 `caster_energy` 为整数 mJ；`send_caster_state` 对无键角色一次性充能 `497_084_850 mJ`
    （热账源项 `caster_granted_j`），已有键（含 0 与旧浮点）不充；旧浮点 J 余额读作 `trunc(J × 1000) mJ`。
  - 切片 4c 起结构建成（扣报价 `total_mj`）。切片 5（Q5-1 与用户答复）：程序不写质量（无质量，直线匀速、无射程终点）。
    切片 5b（用户“保证够到 30 m”）：〈蓄〉1742 J 使它以 30 m/s 发射后在第 3 个热拍于飞行中衰竭；第一个热拍在出生后
    墙钟 (0, 0.5] s 内到来，所以任何发射相位下路程都在 (30, 45] m。飞行、〈遇〉与人物命中由
    `magic_structure_world_test.exs` 的 W5-3 覆盖。

  IR v2 法杖光弹（复用 v5 目录 `22c459f0…` 既有 14 符号，42 B）：
  `〈握〉〈形 球 0.05 m，无质量〉〈辉 100 W〉〈蓄 1742 J〉〈投 30 m/s〉｜当〈遇〉则〈散〉`
  hex = `020101000700010002000032000000000000010010006401001b06ce01001e7530010001002201002c00`
  （物品目录夹具 `fixtures/items/c9aa29e6…` 是客户端真实发布物，与此程序一致；`catalog_holdables_test.exs` 读它。本文件用测试内持物表。）
  """
  use ExUnit.Case, async: false
  require Logger
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Structure}
  alias VoxelRegion.World.{Admission, Casting}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @catalog Path.expand("../priv/magic", __DIR__)
           |> Path.join("*.json")
           |> Path.wildcard()
           |> then(fn [path] -> path end)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @catalog
  @external_resource Path.join(@fixtures, "magic/ir-v2-samples.json")

  @stone 11
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @simulation_box {{-2, 0, -2}, {9, 3, 5}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @forward {0.0, 0.0, 1.0}
  @up {0.0, 1.0, 0.0}

  # 法杖光弹 IR v2（42 B）：环境 293.15 K 下 total_mj = 10_235_708、physical_mj = 1_742_000（〈蓄〉，无质量无动能）、
  # 成本模型前摇 1.184316 s、life_s = 1.255153 s（报价的能量切片求积；`quote-v2-samples.json` 同值）、rejects = []。
  @bolt_hex "020101000700010002000032000000000000010010006401001b06ce01001e7530010001002201002c00"
  @bolt_bytes Base.decode16!(@bolt_hex, case: :lower)
  @bolt_total_mj 10_235_708
  @bolt_windup_s 1.184316
  @grant_mj 497_084_850
  @basic_windup_s 0.3

  setup do
    root = Path.join(System.tmp_dir!(), "magic_staff_bolt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    properties =
      Jason.decode!(File.read!(Path.join([@fixtures, "combustion", @properties <> ".json"])))

    holdables = [
      %{
        "id" => "staff",
        "display_name" => "法杖",
        "basic_spell" => @bolt_hex,
        "basic_windup_s" => @basic_windup_s,
        "skill_tool_ids" => []
      }
    ]

    File.write!(
      Path.join(root, "properties.json"),
      Jason.encode!(Map.put(properties, "holdables", holdables))
    )

    File.cp!(
      Path.join([@fixtures, "combustion", "environment-radiation.json"]),
      Path.join(root, "environment.json")
    )

    File.cp!(@catalog, Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @stone}])
    a = actor()
    # 作者初态：查询蓄能石的正式属性行，再经持久化边界写入 10 MJ 储能（同 MagicWorldTest）。
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(log_path(root), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    w = start(root)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    %{w: w, root: root, a: a, digest: :crypto.hash(:sha256, File.read!(@catalog))}
  end

  defp start(root, opts \\ []) do
    start_supervised!(
      {World,
       [
         source: Source,
         log: Log,
         root: root,
         observer: self(),
         name: nil,
         property_catalog_path: Path.join(root, "properties.json"),
         thermal_environment_path: Path.join(root, "environment.json"),
         magic_catalog_path: Path.join(root, "magic.json")
       ] ++ opts},
      id: :world
    )
  end

  defp restart(c), do: (:ok = stop_supervised(:world); %{c | w: start(c.root)})
  defp log_path(root), do: Path.join(root, "overlay.log")

  defp actor(cid \\ @cid) do
    a = %{
      cid: cid,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5},
      tick_us: 16_667,
      controller: :player
    }

    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp energy(w, cid \\ @cid), do: elem(World.caster_state(w, cid), 1).energy_j
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)

  defp battery(s),
    do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {16, 8, 0}))

  defp ir_program(id),
    do:
      Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  # 玩家施法者状态出口（Gate 接纳与显式请求共用）：本进程充当 Gate，收 0x83 v2 字节。
  defp send_state(w, a), do: World.send_caster_state(w, a.cid, 0, {self(), a.identity})

  defp ledger_txns(root, cid),
    do:
      for(
        txn <- OverlayLog.File.replay(log_path(root)),
        Map.has_key?(Map.get(txn, :caster_energy, %{}), cid),
        do: txn
      )

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()

    %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {dx / n, dy / n, dz / n},
      micro: micro,
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }
  end

  defp bolt(c, a, at, direction \\ @forward), do: aimed(c, a, @bolt_bytes, direction, at)

  defp aimed(c, a, program_bytes, direction, at) do
    seq = next()

    request = %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 1,
      catalog_digest: c.digest,
      direction: direction,
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0,
      program: program_bytes
    }

    VoxelRegion.TestSupport.spell(
      c.w,
      Map.merge(a, %{received_us: at, clock_node: node()}),
      request
    )
  end

  defp draw_cast(c, a, program_bytes, at, micro \\ @stone_micro) do
    {:ok, target} = World.tool_intent(c.w, a, query(a, micro))
    seq = next()

    request =
      %{
        request_id: seq,
        client_intent_seq: seq,
        logical_scene_id: 1,
        action: 1,
        catalog_digest: c.digest,
        direction: query(a, micro).direction,
        program: program_bytes
      }
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))

    VoxelRegion.TestSupport.spell(
      c.w,
      Map.merge(a, %{received_us: at, clock_node: node()}),
      request
    )
  end

  defp quote_reply(c, program_bytes, opts \\ []) do
    seq = next()

    base = %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      catalog_digest: c.digest,
      direction: @forward,
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0,
      program: program_bytes
    }

    request = Map.merge(base, Map.new(opts))

    {:ok, %{caster: caster}} =
      VoxelRegion.TestSupport.spell(
        c.w,
        Map.merge(c.a, %{received_us: 0, clock_node: node()}),
        request
      )

    caster
  end

  test "光弹 IR v2 报价：合法程序、0 rejects、物理 1742 J（无质量、无动能）、报价寿命 1.26 s；开户充能维持常量", c do
    catalog = Catalog.load(Path.join(c.root, "magic.json"))
    assert {:ok, program} = Program.diagnose_ir(@bolt_bytes, catalog)

    site = %{
      ambient_k: 293.15,
      formation_distance_m: 0.0,
      emissivity: 0.9,
      exchange_w_per_m2_k: 10.0
    }

    q = Cost.quote_structure(program, catalog, site)
    assert q.rejects == []
    assert q.units == 4 and q.precision == 1
    assert q.physical_mj == 1_742_000 and q.kinetic_mj == 0
    assert q.total_mj == @bolt_total_mj
    assert_in_delta q.windup_s, @bolt_windup_s, 1.0e-6
    assert q.life_s > 1.0 and q.life_s < 1.5
    assert Casting.initial_charge_mj() == @grant_mj
  end

  # 〈蓄〉选取（切片 5b，用户“保证够到 30 m”）：飞行中的读数（293.15 K 空气、无接触格、无净热、无邻居与干预场）下用真实
  # 报价 + `Structure.new/4` + 逐拍 `Structure.step/4` 求衰竭拍号 k。第一个热拍在出生后墙钟 (0, 0.5] s 内到来，第 k 拍
  # 衰竭的墙钟飞行时长在 ((k − 1)·0.5, k·0.5] s，以 30 m/s 计 k = 3 即路程 (30, 45] m——任何发射相位都够到 30 m。
  test "法杖〈蓄〉1742 J：第 3 个热拍在飞行中衰竭，是第 3 拍区间 1593–1891 J 的中点；区间外相邻值落在第 2、4 拍", c do
    catalog = Catalog.load(Path.join(c.root, "magic.json"))
    site = %{ambient_k: 293.15, formation_distance_m: 0.0, emissivity: 0.9, exchange_w_per_m2_k: 10.0}

    inputs = %{net_heat_j: 0, feed_w: 0, temperature_k: 293.15, cell_heat_capacity_j_per_k: 0.0, embedded: false,
      neighbors: [], fields: [], release_doses: [], contact: false}

    exhausted_at = fn energy_j ->
      bytes = binary_part(@bolt_bytes, 0, 26) <> <<0::4, energy_j::12>> <> binary_part(@bolt_bytes, 28, 14)
      {:ok, %Program{groups: [group]} = program} = Program.diagnose_ir(bytes, catalog)
      q = Cost.quote_structure(program, catalog, site)
      assert q.rejects == []

      Enum.reduce_while(1..20, Structure.new({1, 0}, group, q, 0), fn tick, s ->
        {s, _} = Structure.step(s, inputs, tick, catalog)
        if s.status == {:terminated, :exhausted}, do: {:halt, tick}, else: {:cont, s}
      end)
    end

    # 法杖程序字节里的〈蓄〉就是 1742 J。
    {:ok, %Program{groups: [group]}} = Program.diagnose_ir(@bolt_bytes, catalog)
    assert Enum.find(group.energy, &(&1.id == "energy.load")).params["energy_mj"] == 1_742_000
    assert exhausted_at.(1742) == 3
    assert exhausted_at.(1593) == 3 and exhausted_at.(1891) == 3
    assert exhausted_at.(1592) == 2 and exhausted_at.(1892) == 4
    assert (1593 + 1891) / 2 == 1742
  end

  test "普攻固定前摇：持物 IR v2 basic_spell 报价与施放前摇 0.3 s、成本不变；取能与差 1 字节程序照常按成本模型", c do
    {:ok, _} = send_state(c.w, c.a)
    q = quote_reply(c, @bolt_bytes)
    assert q.quote_windup_s == @basic_windup_s
    assert_in_delta q.quote_j, @bolt_total_mj / 1000, 1.0e-9
    assert q.rejects == []
    assert q.fail_step == 0

    # 取能 1 MJ：不是持物普攻，照常按成本模型前摇（≠ 0.3 s）。
    {:ok, target} = World.tool_intent(c.w, c.a, query(c.a, @stone_micro))

    q_draw =
      quote_reply(
        c,
        ir_program("draw_1mj"),
        Map.merge(
          %{direction: query(c.a, @stone_micro).direction},
          Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
        )
      )

    assert_in_delta q_draw.quote_windup_s, 0.430375043716573, 1.0e-9

    # 与光弹只差 1 字节（energy.load 1742 J 0x06ce → 1743 J 0x06cf）：不是持物普攻，照常按成本模型前摇。
    other =
      String.replace(@bolt_hex, "001b06ce", "001b06cf") |> Base.decode16!(case: :lower)

    assert byte_size(other) == byte_size(@bolt_bytes)

    assert Enum.count(
             Enum.zip(:binary.bin_to_list(@bolt_bytes), :binary.bin_to_list(other)),
             fn {x, y} -> x != y end
           ) == 1

    assert_in_delta quote_reply(c, other).quote_windup_s, @bolt_windup_s, 1.0e-3

    # 施放：前摇计时 = 0.3 s，广播 7 步时长全部缩放为 0（Σ + release_lead_s 0.3 = 0.3）；切片 4c 起结构建成，扣报价总价。
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{outcome: nil, caster: caster}} = bolt(c, c.a, 1_000_000)
        assert caster.spent_j == caster.quote_j
        send(self(), {:spent_j, caster.spent_j})
      end)

    assert log =~ "windup_s=0.3 "

    assert log =~
             "steps=[{0, 0.0, 0.0}, {1, 0.0, 0.0}, {2, 0.0, 0.0}, {3, 0.0, 0.0}, {4, 0.0, 0.0}, {5, 0.0, 0.0}, {6, 0.0, 0.0}]"

    assert_received {:spent_j, spent_j}
    assert_in_delta energy(c.w), @grant_mj / 1000 - spent_j, 1.0e-6
  end

  # 用户 2026-11-26 裁定：持物普攻不受移动打断。“是否普攻”只由 World 在前摇开始时判一次（与固定前摇同一 `match_basic_spell/2`），
  # 随前摇计划 `basic_attack` 交给前摇 owner（Player）。测试进程充当 Player：收到计划后以 k = 0 取消收尾。
  test "前摇计划带 World 判定的 basic_attack：持物普攻程序为真；差 1 字节的同形程序为假", c do
    {:ok, _} = send_state(c.w, c.a)
    other = String.replace(@bolt_hex, "001b06ce", "001b06cf") |> Base.decode16!(case: :lower)

    for {bytes, basic, at} <- [{@bolt_bytes, true, 1_000_000}, {other, false, 3_000_000}] do
      seq = next()

      request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, catalog_digest: c.digest,
        direction: @forward, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0, program: bytes}

      {:ok, current} = Actor.tool_context(c.a.player, c.a.identity)
      actor = Map.merge(current, %{received_us: at, clock_node: node(), player: self()})
      key = {actor.identity, seq}
      ref = make_ref()
      send(c.w, {:prepare_cast, key, actor, request, {self(), ref}})
      assert_receive {:cast_prepared, ^key, %{basic_attack: ^basic}}, 5_000
      send(c.w, {:cancel_cast, key, :interrupted_cancelled, 0})
      assert_receive {^ref, {:error, :interrupted_cancelled}}, 5_000
    end
  end

  test "异步任务结果标签回归：Admission.kind/1 对 {ref, results} 返回 :task_result（可插进 info 日志）" do
    assert Admission.kind({make_ref(), []}) == :task_result
  end

  # 只测试：单调时钟比墙钟走快的主机（2026-11-21 devenv 漂移 2 s）。
  defmodule AheadClock do
    def now(ref), do: System.monotonic_time(:microsecond) + :atomics.get(ref, 1)
  end

  test "单调与墙钟漂移 2 s：施放记录 t0 跟随 Scene 时间线（ServerTime），不跟墙钟", c do
    ahead = :atomics.new(1, signed: true)
    :ok = stop_supervised(:world)
    w = start(c.root, server_clock: {AheadClock, ahead})
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    c = %{c | w: w}
    {scene_origin, scene_mono} = {System.system_time(:microsecond), AheadClock.now(ahead)}
    scene_now = fn -> scene_origin + AheadClock.now(ahead) - scene_mono end
    :atomics.put(ahead, 1, 2_000_000)

    {:ok, _} = send_state(w, c.a)
    before = scene_now.()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{outcome: nil}} = bolt(c, c.a, 1_000_000, @up)
      end)

    later = scene_now.()
    [_, cast_t0] = Regex.run(~r/voxel_cast_begin .* t0_us=(\d+)/, log)
    t0 = String.to_integer(cast_t0)
    assert t0 >= before - 100_000 and t0 <= later + 100_000
  end

  test "开户：send_caster_state 两次只充一次；冷重启与检查点后不再充，余额不变", c do
    seq = World.seq(c.w)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a)
      end)

    assert log =~ "voxel_caster_grant seq=#{seq + 1} cid=#{@cid} granted_mj=#{@grant_mj}"
    identity = c.a.identity

    assert_receive {:mmo_voxel_bytes, ^identity,
                    <<0x83, 0::64, s::64, 497_084.85::float-64, 5.0e6::float-64, 16.0::float-64,
                      _::binary-size(120)>>}

    assert s == seq + 1
    assert ledger(observe(c.w), :caster_granted_j) == 497_084.85

    no_grant = fn fun -> refute ExUnit.CaptureLog.capture_log(fun) =~ "voxel_caster_grant" end

    no_grant.(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert [%{seq: grant_seq, caster_energy: %{@cid => @grant_mj}}] = ledger_txns(c.root, @cid)
    assert grant_seq == seq + 1

    c = restart(c)
    assert energy(c.w) == 497_084.85
    no_grant.(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert length(ledger_txns(c.root, @cid)) == 1
    assert :ok = World.compact(c.w)
    c = restart(c)
    no_grant.(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert ledger(observe(c.w), :caster_granted_j) == 497_084.85
    no_grant.(fn -> assert {:ok, %{energy_j: +0.0}} = World.caster_state(c.w, 2002) end)
  end

  test "空账中断 interrupted_energy：第 1 步中断扣 0 并写入键 0；已有键（0）不开户", c do
    empty = actor(2002)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{outcome: :interrupted_energy, caster: %{spent_j: +0.0, energy_j: +0.0}}} =
                 bolt(c, empty, 1_000_000)
      end)

    assert log =~ "cid=2002"
    assert log =~ "outcome=interrupted fail_step=1 cause=energy"
    assert log =~ "spent_mj=0 balance_before_mj=0 energy_mj=0"
    assert [%{caster_energy: %{2002 => 0}}] = ledger_txns(c.root, 2002)
    # 已有键 0：发状态不开户、不提交。
    refute ExUnit.CaptureLog.capture_log(fn ->
             assert {:ok, %{energy_j: +0.0}} = send_state(c.w, empty)
           end) =~ "voxel_caster_grant"

    assert length(ledger_txns(c.root, 2002)) == 1
  end

  test "旧浮点 J 余额读作 trunc(J × 1000) mJ、不开户；余额不足的光弹在第 3 步中断扣光并计辐射账", c do
    seq = World.seq(c.w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(log_path(c.root), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      caster_energy: %{3003 => 1234.5678}
    })

    c = %{c | w: start(c.root)}
    :ok = VoxelRegion.TestSupport.activate_simulation(c.w, @simulation_box)
    legacy = actor(3003)
    # trunc(1 234 567.8) = 1 234 567 mJ。
    assert energy(c.w, 3003) == 1234.567
    assert {:ok, %{energy_j: 1234.567}} = send_state(c.w, legacy)
    assert length(ledger_txns(c.root, 3003)) == 1

    before = observe(c.w)
    # 光弹前 3 步累计支出：286 787、775 022、1 366 735 mJ > 1 234 567 mJ → 第 3 步中断，扣光余额 1 234 567 mJ。
    # 手边点 (0.5, 2.5, 1.0) 是空气宏格，W7 中断支出全部记入 cast_interrupt_radiation_j。
    assert {:ok, %{outcome: :interrupted_energy, caster: caster}} = bolt(c, legacy, 1_000_000)
    assert caster.spent_j == 1234.567
    assert caster.energy_j == 0.0
    assert [_, %{caster_energy: %{3003 => 0}}] = ledger_txns(c.root, 3003)

    assert_in_delta ledger(observe(c.w), :cast_interrupt_radiation_j) -
                      ledger(before, :cast_interrupt_radiation_j),
                    1234.567,
                    1.0e-9
  end

  test "开户后〈取〉整数分账：石减 taken = gained + loss，施法者余额精确到 mJ", c do
    {:ok, _} = send_state(c.w, c.a)
    before = observe(c.w)
    assert battery(before).stored_j == 1.0e7

    assert {:ok, %{outcome: nil, caster: caster}} =
             draw_cast(c, c.a, ir_program("draw_1mj"), 1_000_000)

    s = observe(c.w)
    # 余额 497 084 850 + gained 900 000 000 − 取能构型损耗 560 750 = 1 396 524 100 mJ = 1 396 524.1 J。
    assert caster.energy_j == 1_396_524.1
    assert caster.spent_j == 560.75
    assert_in_delta battery(s).stored_j, 9.0e6, 1.0e-6
    assert_in_delta ledger(s, :caster_drawn_j) - ledger(before, :caster_drawn_j), 900_000.0, 1.0e-9
    assert_in_delta ledger(s, :draw_loss_j) - ledger(before, :draw_loss_j), 100_000.0, 1.0e-9
  end

  test "作用于目标格的法术不放宽：〈附〉瞄空回 :no_target，〈取〉指向普通石回 :invalid_target，均不扣能", c do
    {:ok, _} = send_state(c.w, c.a)
    bal = energy(c.w)
    assert {:error, :no_target} = aimed(c, c.a, ir_program("scorch"), @up, 1_000_000)
    # 地面石宏格 (0,0,1) 顶面中心微格：眼睛射线首个命中即它，在本地施法域 6 m 内。
    assert {:error, :invalid_target} =
             draw_cast(c, c.a, ir_program("draw_1mj"), 2_000_000, {4, 7, 12})

    assert energy(c.w) == bal
  end
end
