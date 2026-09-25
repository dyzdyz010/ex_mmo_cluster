defmodule VoxelRegion.MagicWindupWorldTest do
  @moduledoc """
  只测试：施放前摇在真实 World 里的待施放、广播与定时结算（Voxim Docs/Magic.md §13.6，前摇契约 §1、§4）。

  目录与场景同 `MagicWorldTest`：材料 `b1aca503…`，魔法 `ff15757b…`（Test-only 手写，版本 2）；地面石 11 铺 y = 0，
  施法者脚 (0.5, 1.0, 0.5)、眼 (0.5, 2.5, 0.5)，蓄能石 (2,1,0)（作者初态 10 MJ，经持久化边界安装一次），孤立叶 (0,2,3)。
  远程点火 0.4 MJ / 200 kW 的各步时长按契约 §2 手算表：构型调整 0.49198349 s、注能 0.4 s（前摇 0.89198349 s），
  E_loss 2292.5445548 J；取能 1 MJ 的 E_loss 1053.7222097 J → 取能后余额 898 946.2777903 J。
  第一个用例走真实定时器（前摇约 0.89 s，只断言下界）；其余用例在待施放出现后直接投递到期消息，不等墙钟。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "ff15757b8a7bfc20954ffde9370f04f0bc22b8a0b93fe31e03eb893165c7e9b1"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @leaf_micro {4, 20, 28}

  setup do
    root = Path.join(System.tmp_dir!(), "magic_windup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @catalog <> ".json"]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    File.cp!(Path.join([@fixtures, "magic", @magic <> ".json"]), Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}])
    a = actor()
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)
    OverlayLog.File.append(Path.join(root, "overlay.log"), %{seq: seq + 1, entries: [], coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]})
    %{w: start(root), root: root, a: a, digest: Base.decode16!(@magic, case: :lower)}
  end

  defp start(root) do
    start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"),
      magic_catalog_path: Path.join(root, "magic.json")]}, id: :world)
  end

  defp actor do
    a = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp energy(c), do: elem(World.caster_state(c.w, @cid), 1).energy_j
  defp rel(actual, expected), do: assert(abs(actual - expected) <= 1.0e-6 * abs(expected), "#{actual} vs #{expected}")

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 1,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  defp heat, do: %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "act.heat", args: %{energy_j: 400_000, power_w: 200_000}}]}
  defp draw, do: %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "energy.draw", args: %{energy_j: 1_000_000}}]}

  # 施法意图（目标身份先经工具查询取得，与客户端命中同一射线）与带入口时钟的施法者。
  defp request(c, micro, program, at, action \\ 1) do
    {:ok, target} = World.tool_intent(c.w, c.a, query(c.a, micro))
    seq = next()
    request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action, catalog_digest: c.digest,
      direction: query(c.a, micro).direction, program: Jason.encode!(program), semblance: {0, 0}}
    {Map.merge(c.a, %{received_us: at, clock_node: node()}),
     Map.merge(request, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))}
  end

  # 在调用方进程外发出施放（调用在结算后才返回），等到待施放出现在观察快照里再返回该记录。
  defp begin(c, micro, program, at) do
    {actor, request} = request(c, micro, program, at)
    task = Task.async(fn -> World.spell_intent(c.w, actor, request) end)
    record = Enum.find_value(1..2_000, fn _ -> observe(c.w).casts[@cid] end)
    assert record, "pending cast never appeared"
    {task, request, record}
  end

  defp settle(c, record), do: send(c.w, {:settle_cast, @cid, record.t0_us})

  test "前摇：点火通过校验后不结算，广播施放记录（各步时长同手算、出发点 = 手边、程序字节原样）；真实定时器到期后结算并广播 live=0", c do
    {a, r} = request(c, @stone_micro, draw(), 1_000_000)
    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(c.w, a, r)
    rel(energy(c), 898_946.2777903)
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, %{casts: casts}}, 5_000
    assert casts == %{}

    {actor, request} = request(c, @leaf_micro, heat(), 2_000_000)
    seq0 = World.seq(c.w)
    before_us = System.system_time(:microsecond)
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> World.spell_intent(c.w, actor, request) end)

    start_seq = seq0 + 1
    assert_receive {:canonical_delta, %{transaction_seq: ^start_seq, transaction: %{casts: %{@cid => record}}}}, 5_000
    assert record.live == 1
    assert record.program == request.program
    assert record.t0_us >= before_us and record.t0_us <= System.system_time(:microsecond)
    # 出发点 = 眼 + 0.5 m × 瞄准方向（与投掷拟态手边同一来源）。
    {dx, dy, dz} = request.direction
    for {a, e} <- Enum.zip(Tuple.to_list(record.origin), [0.5 + 0.5 * dx, 2.5 + 0.5 * dy, 0.5 + 0.5 * dz]),
        do: assert_in_delta(a, e, 1.0e-12)
    [{adjust, inject}] = record.steps
    rel(adjust, 0.49198349452)
    rel(inject, 0.4)

    # 前摇中：观察快照与新订阅的完整快照都带这条记录；未扣能、目标无热源。
    # （取能留下的热源使 World 自身每 500 ms 热提交，真实前摇期间 seq 另有推进，这里不断言 seq。）
    s = observe(c.w)
    assert s.casts == %{@cid => record}
    refute Map.has_key?(s.thermal.sources, {0, 2, 3})
    rel(energy(c), 898_946.2777903)
    ref2 = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref2)
    assert_receive {:canonical_snapshot, ^ref2, %{casts: %{@cid => ^record}}}, 5_000

    # 定时器按前摇 0.89198 s（向上取整到 892 ms）到期，走现有结算路径：点火成功，扣 402 292.5445548 J。
    assert {:ok, %{outcome: nil, seq: settle_seq, caster: caster}} = Task.await(task, 10_000)
    assert System.monotonic_time(:millisecond) - started >= 892
    assert settle_seq > start_seq
    rel(caster.spent_j, 402_292.5445548)
    rel(energy(c), 496_653.7332355)
    assert_receive {:canonical_delta, %{transaction_seq: ^settle_seq, transaction: %{casts: %{@cid => %{live: 0, outcome: 0}}}}}, 5_000
    s = observe(c.w)
    assert s.casts == %{}
    assert s.thermal.sources[{0, 2, 3}] == %{remaining_j: 400_000.0, power_w: 200_000.0}
  end

  test "前摇中再施放：立即 cast_too_soon、不扣能、不提交；报价不受影响；结算后照常", c do
    {a, r} = request(c, @stone_micro, draw(), 1_000_000)
    assert {:ok, _} = VoxelRegion.TestSupport.spell(c.w, a, r)
    {task, _request, record} = begin(c, @leaf_micro, heat(), 2_000_000)
    seq = World.seq(c.w)

    # 入口时钟晚于间隔 500 ms（不是 GCRA 过快），仍因前摇中被拒；同一 World 进程立即回复，不等前摇结束。
    {actor, again} = request(c, @leaf_micro, heat(), 9_000_000)
    assert {:error, :cast_too_soon} = World.spell_intent(c.w, actor, again)
    {actor, quote} = request(c, @leaf_micro, heat(), 9_000_001, 0)
    assert {:ok, %{caster: q}} = World.spell_intent(c.w, actor, quote)
    rel(q.quote_j, 402_292.5445548)
    assert World.seq(c.w) == seq
    rel(energy(c), 898_946.2777903)
    assert observe(c.w).casts == %{@cid => record}

    settle(c, record)
    assert {:ok, %{outcome: nil, seq: settled}} = Task.await(task, 10_000)
    assert settled == seq + 1
    rel(energy(c), 496_653.7332355)
    # 已结算的记录不再响应到期消息（旧定时器稍后到达时忽略）。
    settle(c, record)
    assert World.seq(c.w) == settled
  end

  test "走火也走完前摇：余额 0 的点火在前摇期间不扣能，结算为 misfire_energy、广播 outcome 1", c do
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, _}, 5_000
    {task, _request, record} = begin(c, @leaf_micro, heat(), 2_000_000)
    assert record.live == 1
    assert energy(c) == 0.0
    settle(c, record)
    assert {:ok, %{outcome: :misfire_energy, seq: seq, caster: %{spent_j: spent}}} = Task.await(task, 10_000)
    assert spent == 0.0
    assert_receive {:canonical_delta, %{transaction_seq: ^seq, transaction: %{casts: %{@cid => %{live: 0, outcome: 1}}}}}, 5_000
    assert observe(c.w).casts == %{}
  end

  test "结算时目标已失效：前摇中叶被换成石 → stale_target、不扣能、目标无热源，广播 outcome 2", c do
    {a, r} = request(c, @stone_micro, draw(), 1_000_000)
    assert {:ok, _} = VoxelRegion.TestSupport.spell(c.w, a, r)
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, _}, 5_000
    {task, _request, record} = begin(c, @leaf_micro, heat(), 2_000_000)
    {:ok, _} = World.apply_edits(c.w, [{{0, 2, 3}, @stone}])
    seq = World.seq(c.w)

    settle(c, record)
    assert {:error, :stale_target} = Task.await(task, 10_000)
    rejected = seq + 1
    assert World.seq(c.w) == rejected
    assert_receive {:canonical_delta, %{transaction_seq: ^rejected, transaction: %{casts: %{@cid => %{live: 0, outcome: 2}}}}}, 5_000
    rel(energy(c), 898_946.2777903)
    s = observe(c.w)
    assert s.casts == %{}
    refute Map.has_key?(s.thermal.sources, {0, 2, 3})
  end

  test "待施放不持久化：前摇中冷重启 → 记录丢失、未扣能；日志回放正常，重启后可再施放", c do
    {a, r} = request(c, @stone_micro, draw(), 1_000_000)
    assert {:ok, _} = VoxelRegion.TestSupport.spell(c.w, a, r)
    {actor, request} = request(c, @leaf_micro, heat(), 2_000_000)
    # 调用方在独立进程里等待（World 停止时它随调用退出，不牵连测试进程）。
    spawn(fn -> World.spell_intent(c.w, actor, request) end)
    assert Enum.find_value(1..2_000, fn _ -> observe(c.w).casts[@cid] end)

    :ok = stop_supervised(:world)
    w = start(c.root)
    c = %{c | w: w}
    assert observe(w).casts == %{}
    rel(energy(c), 898_946.2777903)
    {actor, request} = request(c, @leaf_micro, heat(), 3_000_000)
    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(w, actor, request)
    rel(energy(c), 496_653.7332355)
  end
end
