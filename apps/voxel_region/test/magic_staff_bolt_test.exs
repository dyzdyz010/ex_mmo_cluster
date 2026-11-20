defmodule VoxelRegion.MagicStaffBoltTest do
  @moduledoc """
  只测试：法杖光弹的服务端半边在真实 World 里的整数 mJ 施法者账、开户一次性充能、光弹扣款、走火、取能分账与旧浮点余额兼容。

  契约：施法者账 `caster_energy` 是整数 mJ；扣款 cost_mj = round(报价总支出 × 1000)；走火扣 min(cost_mj, 余额)；
  取能 taken_mj = min(round(请求 × 1000), trunc(石储能 × 1000), 容量_mj − 余额)、gained_mj = round(η × taken_mj)；
  `send_caster_state`（玩家接纳与显式请求）对没有键的角色提交一次开户充能 497 084 850 mJ（热账源项 `caster_granted_j`），
  已有键（含 0 与旧浮点）不充；旧浮点 J 余额读作 trunc(J × 1000) mJ。线上与只读状态仍是 f64 J（mJ / 1000）。
  不覆盖：客户端法杖左键、Gate／QUIC 真实连接（Gate 接纳只把请求排进 `send_caster_state`，由 gate_server 用例覆盖）、
  光弹命中人物（Harm／combat_scope 属于 Scene 与投射物链路）。

  目录：材料 `b1aca503…`（UE 发布字节）；魔法 `71ca543b…`（Voxim `Content/Voxel/Magic/Published` 的现行发布字节，
  原样复制到 `fixtures/magic/`，CI 的 Voxim 稀疏检出不含该目录）；热环境 293.15 K。
  期望数值来自独立复算（按 Voxim Docs/Magic.md §13.6 / `Magic.Cost` moduledoc 公式写的 Python 复算，不调被测代码）：
  光弹总支出 9941.697170433505 J（物理 104.5 J = 发光 100 W × 1 s + ½·0.01 kg·(30 m/s)²，拟态温度 = 环境故显热 0）、
  前摇 1.9299314814115767 s → cost_mj 9 941 697，充能 50 × 9 941 697 = 497 084 850 mJ；
  该目录取能（单步，物理 0）总支出 560.7500874331461 J → 560 750 mJ。
  场景（Y-up，1 宏格 = 1 m）：地面石 11 铺 y = 0；施法者脚 (0.5, 1.0, 0.5)、眼 (0.5, 2.5, 0.5)；蓄能石 (2,1,0)
  （作者初态 10 MJ，同 `MagicWorldTest` 经持久化边界安装一次）；光弹靶石格 (0,2,3)：自手边 (0.5, 2.5, 1.0) 以 30 m/s 沿 +z，
  t = 2/30 s 到 z = 3 面，y = 2.5 − ½·9.81·(1/15)² ≈ 2.478，落在靶格内。
  """
  use ExUnit.Case, async: false
  require Logger
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.Magic.{Catalog, Cost, Program}
  alias VoxelRegion.World.Casting
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "71ca543b42db5ca5b1b8fea62771aa0c256399b2fa00c0525eccb4d9953860a7"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @simulation_box {{-2, 0, -2}, {9, 3, 5}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @forward {0.0, 0.0, 1.0}

  # 独立复算的整数（见 moduledoc）。
  @cost_mj 9_941_697
  @grant_mj 497_084_850
  # 法杖普攻作者前摇（用户 2026-11-20 定）；与该魔法目录 release_lead_s 0.3 相等，故广播各步缩放为 0。
  @basic_windup_s 0.3

  @bolt %{"v" => 1, "target" => %{"kind" => "aim"}, "emit" => "hand",
    "steps" => [
      %{"sym" => "form.semblance",
        "args" => %{"shape" => 0, "radius_m" => 0.05, "mass_kg" => 0.01, "temperature_k" => 293.15, "glow_w" => 100, "lifetime_s" => 1}},
      %{"sym" => "act.throw", "args" => %{"speed_mps" => 30}},
      %{"sym" => "act.break_on_hit", "args" => %{}}
    ]}

  setup do
    root = Path.join(System.tmp_dir!(), "magic_staff_bolt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    # 属性目录 = 材料夹具 + 法杖持物（作者表同 Voxim Docs/Gameplay/author_actions.py：basic_spell = 光弹、basic_windup_s 0.3）。
    properties = Jason.decode!(File.read!(Path.join([@fixtures, "combustion", @catalog <> ".json"])))
    holdables = [%{"id" => "staff", "display_name" => "法杖", "basic_spell" => @bolt, "basic_windup_s" => @basic_windup_s, "skill_tool_ids" => []}]
    File.write!(Path.join(root, "properties.json"), Jason.encode!(Map.put(properties, "holdables", holdables)))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    File.cp!(Path.join([@fixtures, "magic", @magic <> ".json"]), Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @stone}])
    a = actor()
    # 作者初态：查询蓄能石的正式属性行，再经持久化边界写入 10 MJ 储能（同 MagicWorldTest）。
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)
    OverlayLog.File.append(log_path(root), %{seq: seq + 1, entries: [], coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]})
    w = start(root)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    %{w: w, root: root, a: a, digest: Base.decode16!(@magic, case: :lower)}
  end

  defp start(root, opts \\ []) do
    start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"),
      magic_catalog_path: Path.join(root, "magic.json")] ++ opts}, id: :world)
  end

  # 只测试：投射物采样后端替身（prod 为 WorldServer.Movement.Projectile）：每个活投射物报一次"前进 50 ms、没有人物、
  # 没有人物目标"的采样，形同真实后端的无命中结果；地形命中仍由 World 自己按飞行弦段判定。
  defmodule MissBackend do
    def poll(shots, _cv),
      do: for({id, s} <- shots, do: {id, s.age_s, {:sample, s.age_s + 0.05, nil, nil, System.system_time(:microsecond)}})

    def notify(_hit, _seq), do: :ok
  end

  defp restart(c), do: (:ok = stop_supervised(:world); %{c | w: start(c.root)})
  defp log_path(root), do: Path.join(root, "overlay.log")

  defp actor(cid \\ @cid) do
    a = %{cid: cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp energy(w, cid \\ @cid), do: elem(World.caster_state(w, cid), 1).energy_j
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)
  defp battery(s), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {16, 8, 0}))

  # 玩家施法者状态出口（Gate 接纳与显式请求共用）：本进程充当 Gate，收 0x83 字节。
  defp send_state(w, a), do: World.send_caster_state(w, a.cid, 0, {self(), a.identity})

  # 持久日志里写这个角色施法者账的事务（开户、结算）。
  defp ledger_txns(root, cid),
    do: for(txn <- OverlayLog.File.replay(log_path(root)), Map.has_key?(Map.get(txn, :caster_energy, %{}), cid), do: txn)

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 1,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  # 手边发出：目标字段按线格式填 0（同 MagicSemblanceWorldTest）。
  defp bolt(c, a, at, direction \\ @forward), do: aimed(c, a, @bolt, direction, at)

  defp aimed(c, a, program, direction, at) do
    seq = next()
    request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, catalog_digest: c.digest,
      direction: direction, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0,
      semblance: {0, 0}, program: Jason.encode!(program)}
    VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: at, clock_node: node()}), request)
  end

  defp draw(c, a, energy_j, at, micro \\ @stone_micro) do
    {:ok, target} = World.tool_intent(c.w, a, query(a, micro))
    seq = next()
    program = %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "energy.draw", args: %{energy_j: energy_j}}]}
    request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, catalog_digest: c.digest,
      direction: query(a, micro).direction, program: Jason.encode!(program), semblance: {0, 0}}
    request = Map.merge(request, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: at, clock_node: node()}), request)
  end

  test "光弹报价：真实 Cost.quote 与独立复算一致；开户充能 = 50 × cost_mj", c do
    catalog = Catalog.load(Path.join(c.root, "magic.json"))
    {:ok, program} = Program.parse(Jason.encode!(@bolt), catalog)
    q = Cost.quote(program, catalog, 293.15)
    assert q.physical_j == 104.5
    assert_in_delta q.total_j, 9941.697170433505, 1.0e-9
    assert_in_delta q.windup_s, 1.9299314814115767, 1.0e-12
    assert round(q.total_j * 1000) == @cost_mj
    assert Casting.initial_charge_mj() == @grant_mj
    assert @grant_mj == 50 * @cost_mj
  end

  # 报价（action 0）：只解析程序与报价，不校验目标；返回 0x83 视图。
  defp quote_reply(c, bytes) do
    seq = next()
    request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, catalog_digest: c.digest,
      direction: @forward, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0,
      semblance: {0, 0}, program: bytes}
    {:ok, %{caster: caster}} = VoxelRegion.TestSupport.spell(c.w, Map.merge(c.a, %{received_us: 0, clock_node: node()}), request)
    caster
  end

  test "普攻固定前摇：持物 basic_spell 报价与施放前摇 0.3 s、扣款仍 cost_mj；其余程序与差一字节的光弹照常按成本模型", c do
    {:ok, _} = send_state(c.w, c.a)
    bolt = Jason.encode!(@bolt)
    q = quote_reply(c, bolt)
    assert q.quote_windup_s == @basic_windup_s
    assert_in_delta q.quote_j, 9941.697170433505, 1.0e-9

    # 取能 1 MJ 预设（魔法目录 presets draw_1mj）：独立复算前摇 0.430375043716573 s（调整 0.130375 s + 出手 0.3 s）。
    draw = Jason.encode!(%{"v" => 1, "target" => %{"kind" => "aim"}, "emit" => "at_target",
      "steps" => [%{"sym" => "energy.draw", "args" => %{"energy_j" => 1_000_000}}]})
    assert_in_delta quote_reply(c, draw).quote_windup_s, 0.430375043716573, 1.0e-12

    # 与光弹只差一个字节（lifetime_s 1 → 2）：不是持物普攻，独立复算前摇 1.9299464613708297 s。
    other = String.replace(bolt, ~s("lifetime_s":1), ~s("lifetime_s":2))
    assert byte_size(other) == byte_size(bolt)
    assert Enum.count(Enum.zip(:binary.bin_to_list(bolt), :binary.bin_to_list(other)), fn {x, y} -> x != y end) == 1
    assert_in_delta quote_reply(c, other).quote_windup_s, 1.9299464613708297, 1.0e-12

    # 施放：前摇计时 = 0.3 s，广播各步缩放到 Σ + release_lead_s 0.3 = 0.3（每步 0）；扣款不变 9 941 697 mJ。
    log = ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{outcome: nil, caster: caster}} = bolt(c, c.a, 1_000_000)
      send(self(), {:bolt, caster})
    end)
    assert_received {:bolt, caster}
    assert caster.spent_j == 9941.697
    assert log =~ "windup_s=0.3 "
    assert log =~ "steps=[{0.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}]"
    assert log =~ "spent_mj=#{@cost_mj} energy_mj=487143153"
  end

  # 回归（2026-11-20 法杖光弹首次真实实跑，Voxim Saved/Tests/staff-20261120/aim-02/server.log）：prod 日志级别 info 下，
  # 投射物采样任务结果 `{任务引用, 结果}` 经输入闸门排队时日志 `kind=` 插入引用 → String.Chars 崩溃 → World 退出、
  # 场景 canonical_incomplete、玩家会话 reason 5。本例以 info 级别、采样后端替身发射光弹：World 存活，采样结果以
  # `kind=projectile_result` 排队提交，光弹撞靶石后从拟态表移除。
  test "投射物采样结果在 info 日志级别经输入闸门提交，World 不崩", c do
    :ok = stop_supervised(:world)
    w = start(c.root, projectile_backend: MissBackend)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    c = %{c | w: w}
    # 有人物生命代与位置的施法者（真实 Player 的 actor 形状，授权时刷新也带着）＋采样后端，光弹才走投射物采样
    # （Casting：projectile_source）。
    shooter = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667, life_generation: 1, position: {0.5, 1.0, 0.5}}
    shooter = Map.put(shooter, :player, start_supervised!({Actor, shooter}, id: make_ref()))
    {:ok, _} = send_state(w, shooter)
    monitor = Process.monitor(w)

    log = ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{outcome: nil, seq: seq}} = bolt(c, shooter, 1_000_000)
      # 光弹 2/30 s 到靶面；等它被采样推进、撞靶、移出拟态表（World 若崩，observe 即退出）。
      await = fn await, left ->
        if Map.has_key?(observe(w).semblances, {seq, 0}) and left > 0,
          do: (Process.sleep(20); await.(await, left - 1)),
          else: Map.has_key?(observe(w).semblances, {seq, 0})
      end
      refute await.(await, 250)
    end)

    refute_received {:DOWN, ^monitor, :process, _, _}
    assert log =~ "kind=projectile_result"
  end

  test "开户：send_caster_state 两次只充一次；冷重启与检查点后不再充，余额不变", c do
    seq = World.seq(c.w)
    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert log =~ "voxel_caster_grant seq=#{seq + 1} cid=#{@cid} granted_mj=#{@grant_mj}"
    # 本进程充当 Gate：0x83 带开户后的余额与开户事务的 seq。
    identity = c.a.identity
    assert_receive {:mmo_voxel_bytes, ^identity, <<0x83, 0::64, s::64, 497_084.85::float-64, 5.0e6::float-64, _::binary>>}
    assert s == seq + 1
    assert ledger(observe(c.w), :caster_granted_j) == 497_084.85

    # World 自身每 500 ms 墙钟热提交也会占 seq，所以"不再充"不看 seq，只看与提交次数无关的量：
    # 没有开户日志、持久日志里只有一笔写该角色账的事务、热账充能源项仍是一笔的 497 084.85 J、余额不变。
    no_grant = fn fun -> refute ExUnit.CaptureLog.capture_log(fun) =~ "voxel_caster_grant" end

    # 第二次（重连）：已有键，不再提交。
    no_grant.(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert [%{seq: grant_seq, caster_energy: %{@cid => @grant_mj}}] = ledger_txns(c.root, @cid)
    assert grant_seq == seq + 1

    # 冷重启：键随日志回放，不再充。
    c = restart(c)
    assert energy(c.w) == 497_084.85
    no_grant.(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert length(ledger_txns(c.root, @cid)) == 1
    # 压实成检查点后再冷重启：同样不充、余额不变、账上的充能源项仍只有一笔（再充一次会是 994 169.7 J）。
    assert :ok = World.compact(c.w)
    c = restart(c)
    no_grant.(fn -> assert {:ok, %{energy_j: 497_084.85}} = send_state(c.w, c.a) end)
    assert ledger(observe(c.w), :caster_granted_j) == 497_084.85
    # 只读查询不开户。
    no_grant.(fn -> assert {:ok, %{energy_j: +0.0}} = World.caster_state(c.w, 2002) end)
  end

  test "光弹施放扣恰好 cost_mj：497 084 850 → 487 143 153 mJ；扣款 = 拟态物理 + 废热", c do
    {:ok, _} = send_state(c.w, c.a)
    before = observe(c.w)

    log = ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{outcome: nil, seq: seq, caster: caster}} = bolt(c, c.a, 1_000_000)
      send(self(), {:bolt, seq, caster})
    end)

    assert_received {:bolt, seq, caster}
    # 497 084 850 − 9 941 697 = 487 143 153 mJ。
    assert caster.spent_j == 9941.697
    assert caster.energy_j == 487_143.153
    assert energy(c.w) == 487_143.153
    assert log =~ "spent_mj=#{@cost_mj} energy_mj=487143153"
    s = observe(c.w)
    # 射程内有落点：照旧落在靶石格 (0,2,3) 上、接触该格。
    assert %{caster: @cid, shape: 0, contact: %{cell: {0, 2, 3}}} = s.semblances[{seq, 0}]
    # 热账入账：拟态物理 104.5 J + 废热 (9 941 697 / 1000 − 104.5) J = 施法者扣款 9941.697 J。
    created = ledger(s, :semblance_created_j) - ledger(before, :semblance_created_j)
    waste = ledger(s, :cast_waste_j) - ledger(before, :cast_waste_j)
    assert created == 104.5
    assert_in_delta waste, 9837.197, 1.0e-9
    assert_in_delta created + waste, 9941.697, 1.0e-9
  end

  test "空账与余额不足走火 misfire_energy：扣 min(cost_mj, 余额)，原因在回复与日志；已有键（0）不开户", c do
    # 2002 从未开户（无键）：余额 0 < 9 941 697 → 走火，扣 min(9 941 697, 0) = 0，结算写入键 0。
    empty = actor(2002)

    log = ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{outcome: :misfire_energy, caster: %{spent_j: +0.0, energy_j: +0.0}}} = bolt(c, empty, 1_000_000)
    end)

    assert log =~ "cid=2002"
    assert log =~ "outcome=misfire_energy"
    assert log =~ "spent_mj=0 energy_mj=0"
    assert [%{caster_energy: %{2002 => 0}}] = ledger_txns(c.root, 2002)
    # 已有键 0：发状态不开户、不提交。
    seq = World.seq(c.w)
    assert {:ok, %{energy_j: +0.0}} = send_state(c.w, empty)
    assert World.seq(c.w) == seq
    assert length(ledger_txns(c.root, 2002)) == 1
  end

  test "旧浮点 J 余额读作 trunc(J × 1000) mJ、不开户；余额不足的光弹扣光余额并全部落脚下", c do
    # 迁移兼容样本：整数化之前持久化的浮点余额 1234.5678 J，经持久化边界写一次（同生产日志里的旧值）。
    seq = World.seq(c.w)
    :ok = stop_supervised(:world)
    OverlayLog.File.append(log_path(c.root), %{seq: seq + 1, entries: [], coarse: [], caster_energy: %{3003 => 1234.5678}})
    c = %{c | w: start(c.root)}
    :ok = VoxelRegion.TestSupport.activate_simulation(c.w, @simulation_box)
    legacy = actor(3003)
    # trunc(1 234 567.8) = 1 234 567 mJ。
    assert energy(c.w, 3003) == 1234.567
    assert {:ok, %{energy_j: 1234.567}} = send_state(c.w, legacy)
    assert World.seq(c.w) == seq + 1

    before = observe(c.w)
    assert {:ok, %{outcome: :misfire_energy, caster: caster}} = bolt(c, legacy, 1_000_000)
    # 1 234 567 < 9 941 697 → 扣 min = 1 234 567 mJ，余额 0；走火的热全部是脚下废热。
    assert caster.spent_j == 1234.567
    assert caster.energy_j == 0.0
    assert [_, %{caster_energy: %{3003 => 0}}] = ledger_txns(c.root, 3003)
    assert_in_delta ledger(observe(c.w), :cast_waste_j) - ledger(before, :cast_waste_j), 1234.567, 1.0e-9
  end

  test "取能整数分账：请求 12 345.6789 J → taken 12 345 679、gained 11 111 111、loss 1 234 568 mJ；石减 taken / 1000", c do
    {:ok, _} = send_state(c.w, c.a)
    before = observe(c.w)
    assert battery(before).stored_j == 1.0e7
    assert {:ok, %{outcome: nil, caster: caster}} = draw(c, c.a, 12_345.6789, 1_000_000)
    s = observe(c.w)
    # 请求 round(12 345 678.9) = 12 345 679 mJ；石 trunc(1e10)、容量余量 5e9 − 497 084 850 都更大 → taken 12 345 679；
    # gained = round(0.9 × 12 345 679) = round(11 111 111.1) = 11 111 111；loss = 1 234 568。
    # 余额 497 084 850 + 11 111 111 − 取能扣款 560 750 = 507 635 211 mJ。
    assert caster.energy_j == 507_635.211
    assert caster.spent_j == 560.75
    assert_in_delta battery(s).stored_j, 1.0e7 - 12_345.679, 1.0e-6
    assert_in_delta ledger(s, :caster_drawn_j) - ledger(before, :caster_drawn_j), 11_111.111, 1.0e-9
    assert_in_delta ledger(s, :draw_loss_j) - ledger(before, :draw_loss_j), 1234.568, 1.0e-9
    # 石减少 = 取得 + 损耗（同一整数 taken 的两端）。
    assert_in_delta battery(before).stored_j - battery(s).stored_j,
                    (ledger(s, :caster_drawn_j) - ledger(before, :caster_drawn_j)) + (ledger(s, :draw_loss_j) - ledger(before, :draw_loss_j)),
                    1.0e-6
  end

  # 射程内无落点（用户 2026-11-20 定；rclick-01 对空地瞄准被拒 out_of_domain）：照常接纳、扣款，弹道飞到射程端点或寿命
  # 散解。竖直向上：手边 (0.5, 3.0, 0.5)，眼→手 0.5 m 计入路程；上升段弦长之和 = 升高 30t − ½·9.81·t²，
  # 0.5 + 升高 ≥ 30 m 首次于 t = 1.25 s（升高 29.8359375 m；t = 1.20 s 时 28.9368 m 不足）→ 射程端点 y = 32.8359375。
  # 光弹寿命 1 s < 1.25 s：飞行中寿命到期散入空气。账（拟态温度 = 环境，显热 0）：发光 100 W × 1 s = 100 J，
  # 释放 = 飞行动能 ½·0.01·30² = 4.5 J，合计 = 物理 104.5 J。
  @up {0.0, 1.0, 0.0}

  defp commit(w), do: (send(w, :thermal_commit); observe(w))

  # 等可观察条件：拟态离开拟态表（投射物采样每 50 ms 一轮，有界 5 s）。
  defp await_gone(w, id),
    do: Enum.find_value(1..250, fn _ -> s = commit(w); if Map.has_key?(s.semblances, id), do: (Process.sleep(20); nil), else: s end)

  defp assert_bolt_dissipated(before, gone) do
    delta = fn key -> ledger(gone, key) - ledger(before, key) end
    assert delta.(:semblance_created_j) == 104.5
    assert_in_delta delta.(:semblance_light_j), 100.0, 1.0e-9
    assert_in_delta delta.(:semblance_released_j), 4.5, 1.0e-6
    assert_in_delta delta.(:semblance_light_j) + delta.(:semblance_released_j) + delta.(:semblance_exchanged_j), 104.5, 1.0e-6
  end

  test "射程内无落点的光弹（运动学拟态）：接纳并扣恰好 cost_mj，飞到寿命散入空气，账闭合", c do
    {:ok, _} = send_state(c.w, c.a)
    before = observe(c.w)
    assert {:ok, %{outcome: nil, seq: seq, caster: caster}} = bolt(c, c.a, 1_000_000, @up)
    assert caster.spent_j == 9941.697
    assert energy(c.w) == 487_143.153
    s = observe(c.w).semblances[{seq, 0}]
    assert s.contact == nil and s.origin == {0.5, 3.0, 0.5}
    assert_in_delta s.flight_s, 1.25, 1.0e-12
    assert_in_delta elem(s.rest, 1), 32.8359375, 1.0e-9
    assert gone = await_gone(c.w, {seq, 0})
    assert_bolt_dissipated(before, gone)
    assert ledger(gone, :projectile_body_j) == 0
  end

  test "射程内无落点的光弹（投射物实时采样）：接纳、按寿命 1 s 飞行后散入空气，账闭合", c do
    :ok = stop_supervised(:world)
    w = start(c.root, projectile_backend: MissBackend)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    c = %{c | w: w}
    shooter = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667, life_generation: 1, position: {0.5, 1.0, 0.5}}
    shooter = Map.put(shooter, :player, start_supervised!({Actor, shooter}, id: make_ref()))
    {:ok, _} = send_state(w, shooter)
    before = observe(w)
    assert {:ok, %{outcome: nil, seq: seq, caster: caster}} = bolt(c, shooter, 1_000_000, @up)
    assert caster.spent_j == 9941.697
    s = observe(w).semblances[{seq, 0}]
    assert Map.has_key?(s, :projectile_source) and s.contact == nil and s.flight_s == 1.0
    assert gone = await_gone(w, {seq, 0})
    assert_bolt_dissipated(before, gone)
  end

  test "作用于目标格的法术不放宽：加热瞄空仍 out_of_domain，取能指向普通石仍 invalid_target，均不扣能", c do
    {:ok, _} = send_state(c.w, c.a)
    energy = energy(c.w)
    heat = %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "act.heat", args: %{energy_j: 400_000, power_w: 200_000}}]}
    assert {:error, :out_of_domain} = aimed(c, c.a, heat, @up, 1_000_000)
    # 地面石宏格 (0,0,1) 顶面中心微格：眼睛射线首个命中即它，在本地施法域 6 m 内。
    assert {:error, :invalid_target} = draw(c, c.a, 1000, 2_000_000, {4, 7, 12})
    assert energy(c.w) == energy
  end
end
