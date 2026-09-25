defmodule VoxelRegion.MagicSemblanceWorldTest do
  @moduledoc """
  只测试：魔法增量 2 在真实 World 里的拟态运行时（Voxim Docs/Magic.md §3、§10）——炽热拟态投掷点燃叶、光球发光耗尽、
  驱散后火不灭、每人上限 6、他人地块拒绝、冷重启温度延续、canonical 订阅下发拟态增量。

  目录：材料 `b1aca503…`（UE 发布字节：蓄能石 42 每宏格 10 MJ、叶 28 热容 1200 J/K 燃点 523.15 K、k = 50），
  魔法 `1ff967d7…`（Test-only 手写：增量 1 内容 + 拟态比热 500 J/(kg·K)、导热 400 W/(m·K) 与三个新符号 / 预设）；
  热环境 = 生产 ε 0.9、环境 293.15 K、对流 10 W/(m²·K)。
  场景（Y-up，1 宏格 = 1 m）：地面石 11 铺 y = 0；施法者脚 (0.5, 1.0, 0.5) → 脚下宏格 (0,0,0)，眼 (0.5, 2.5, 0.5)；
  蓄能石 (2,1,0)；孤立叶 (0,2,3) 悬空。眼睛朝 +z 投掷：手边 = 眼 + 0.5 m·方向 = (0.5, 2.5, 1.0)，v = (0, 0, 12)，
  弹道 z = 1 + 12t 在 t = 2/12 = 0.1666667 s 到达叶的 z = 3 面，此时 y = 2.5 − ½·9.81·(1/6)² = 2.36375（在叶的 y ∈ [2, 3] 内）；
  预设球半径 0.4 m，球心停在面外一个半径：(0.5, 2.36375, 2.6)。
  蓄能石的 10 MJ 储能同增量 1：只能由热电石回路数小时充电，这里作为冷启动恢复的作者初态经持久化边界安装一次。
  World 自身每 500 ms 墙钟也会热提交：断言只用与提交次数无关的量（账闭合式、有界等待、事后状态）。
  施放先进入前摇（开始事务 + 结算事务）；测试经 `TestSupport.spell/3` 在待施放出现后直接投递到期消息，不等墙钟。
  构型损耗按前摇契约 §2 手算表（取能 1053.7222 J、炽热投掷 14 256.0776 J、驱散 2107.4444 J）。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "1ff967d746cd0f1064924292011ce5227dcb6db03d99d45a9befa98a89908075"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @forward {0.0, 0.0, 1.0}

  setup do
    root = Path.join(System.tmp_dir!(), "magic_semblance_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @catalog <> ".json"]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    File.cp!(Path.join([@fixtures, "magic", @magic <> ".json"]), Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..8, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}])
    a = actor()
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)
    OverlayLog.File.append(Path.join(root, "overlay.log"), %{seq: seq + 1, entries: [], coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]})
    w = start(root)
    data = Jason.decode!(File.read!(Path.join(root, "magic.json")))
    presets = Map.new(data["presets"], &{&1["id"], &1["program"]})
    %{w: w, root: root, a: a, digest: Base.decode16!(@magic, case: :lower), presets: presets}
  end

  defp start(root) do
    start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"),
      magic_catalog_path: Path.join(root, "magic.json")]}, id: :world)
  end

  defp restart(c), do: (:ok = stop_supervised(:world); start(c.root))

  defp actor do
    a = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp energy(c), do: elem(World.caster_state(c.w, @cid), 1).energy_j
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)
  defp burning?(s), do: Map.get(cell(s, {0, 2, 3}) || %{}, :burning, false)

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 1,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  # 取能走增量 1 的正式路径（眼睛射线命中蓄能石）；2 MJ → 施法者得 0.9 × 2 MJ − 1053.7222097 J 构型损耗 = 1 798 946.2777903 J。
  defp draw(c, at) do
    {:ok, target} = World.tool_intent(c.w, c.a, query(c.a, @stone_micro))
    program = %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "energy.draw", args: %{energy_j: 2_000_000}}]}
    request = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 1, catalog_digest: c.digest,
      direction: target_direction(c.a), program: Jason.encode!(program), semblance: {0, 0}}
    request = Map.merge(request, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    VoxelRegion.TestSupport.spell(c.w, Map.merge(c.a, %{received_us: at, clock_node: node()}), request)
  end

  defp target_direction(a), do: query(a, @stone_micro).direction

  # 手边发出与驱散不读眼睛射线目标；目标字段按线格式填 0。
  defp cast(c, program, direction, opts) do
    seq = next()
    request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: Keyword.get(opts, :action, 1),
      catalog_digest: c.digest, direction: direction, micro: {0, 0, 0}, granularity: 0, incarnation: 0,
      owner: {0, 0}, material: 0, semblance: Keyword.get(opts, :semblance, {0, 0}), program: Jason.encode!(program)}
    VoxelRegion.TestSupport.spell(c.w, Map.merge(c.a, %{received_us: Keyword.fetch!(opts, :at), clock_node: node()}), request)
  end

  defp light(lifetime),
    do: %{v: 1, target: %{kind: "aim"}, emit: "hand", steps: [%{sym: "form.semblance",
      args: %{shape: 0, radius_m: 0.15, mass_kg: 0.1, temperature_k: 293.15, glow_w: 100, lifetime_s: lifetime}}]}

  # 拟态账闭合：物理能量 = 流出（传给世界 + 散到环境）+ 光 + 释放 + 剩余（显热快照 + 其余存量）。
  defp closed?(s) do
    out = ledger(s, :semblance_exchanged_j) + ledger(s, :semblance_light_j) + ledger(s, :semblance_released_j) +
      ledger(s, :semblance_thermal_j) + ledger(s, :semblance_stored_j)

    assert_in_delta ledger(s, :semblance_created_j), out, 1.0e-6 * max(1.0, ledger(s, :semblance_created_j))
  end

  test "炽热拟态投掷：r 0.4 m、2 kg、2000 K 球以 12 m/s 投向孤立叶 → 落点精确、叶着火；支出与账闭合", c do
    assert {:ok, %{outcome: nil}} = draw(c, 1_000_000)
    assert_in_delta energy(c), 1_798_946.2777903, 1.0e-6
    assert {:ok, %{outcome: nil, seq: seq, caster: caster}} = cast(c, c.presets["hot_throw"], @forward, at: 2_000_000)
    # 支出 = E_phys 1 706 994 + E_loss 14 256.0775635 = 1 721 250.0775635 J（手算见 magic_semblance_test）；余 77 696.2002268 J。
    assert_in_delta caster.spent_j, 1_721_250.0775635, 1.0e-3
    assert_in_delta caster.energy_j, 77_696.2002268, 1.0e-3
    s = observe(c.w)
    ball = s.semblances[{seq, 0}]
    assert {ball.caster, ball.shape, ball.capacity, ball.kinetic_j} == {@cid, 0, 1000.0, 144.0}
    assert ball.origin == {0.5, 2.5, 1.0} and ball.velocity == {+0.0, +0.0, 12.0}
    assert_in_delta ball.flight_s, 1 / 6, 1.0e-12
    {rx, ry, rz} = ball.rest
    assert {rx, rz} == {0.5, 2.6}
    assert_in_delta ry, 2.36375, 1.0e-12
    assert ball.contact.cell == {0, 2, 3}
    assert ledger(s, :semblance_created_j) == 1_706_994.0
    s0 = s

    burning = Enum.find_value(1..60, fn _ -> t = commit(c.w); if burning?(t), do: t end)
    assert burning, "leaf never ignited"
    ball = burning.semblances[{seq, 0}]
    assert ball.kinetic_j == 0.0
    closed?(burning)
    assert ledger(burning, :semblance_exchanged_j) > 0
    IO.puts("SEMBLANCE_IGNITE burning_at_s=#{burning.thermal.elapsed_s - s0.thermal.elapsed_s} ball_k=#{ball.temperature_k} leaf_k=#{cell(burning, {0, 2, 3}).temperature_kelvin}")
  end

  # 树冠：命中叶与 7 片相邻叶连成一团（叶–叶接触 G = 1/(0.5/50 + 0.5/50) = 50 W/K 每面），热被邻叶分走，
  # 仍须在同一预设下着火（实测扫描见增量 2 报告：r 0.25 m 的同能量球在树冠上峰值只到 489 K）。
  test "炽热拟态投掷：同一预设命中树冠外缘叶也着火", c do
    canopy = for p <- [{1, 2, 3}, {-1, 2, 3}, {0, 3, 3}, {0, 2, 4}, {1, 3, 3}, {-1, 3, 3}, {0, 3, 4}], do: {p, @leaf}
    {:ok, _} = World.apply_edits(c.w, canopy)
    assert {:ok, _} = draw(c, 1_000_000)
    assert {:ok, %{outcome: nil}} = cast(c, c.presets["hot_throw"], @forward, at: 2_000_000)
    assert Enum.find_value(1..60, fn _ -> burning?(commit(c.w)) end), "canopy leaf never ignited"
  end

  test "光球：100 W、寿命 2 s 静止在手边 → 发光 200 J 后移除；光账等于 glow_w × 寿命，账闭合", c do
    assert {:ok, _} = draw(c, 1_000_000)
    assert {:ok, %{outcome: nil, seq: seq, caster: caster}} = cast(c, light(2), @forward, at: 2_000_000)
    # E_phys = 100 W × 2 s = 200 J（温度 = 环境，无热内容）；〈形〉d = 2.831793 rad，b = 1000 × 1.0002^1.5 = 1000.3000 W，
    # E_loss = 2·d·√(50·b) + b·0.0002 = 1266.8065 J；支出 1466.8065 J。
    assert_in_delta caster.spent_j, 1466.8065034, 1.0e-3
    orb = observe(c.w).semblances[{seq, 0}]
    assert {orb.origin, orb.rest, orb.flight_s, orb.contact} == {{0.5, 2.5, 1.0}, {0.5, 2.5, 1.0}, 0.0, nil}

    gone = Enum.find_value(1..20, fn _ -> t = commit(c.w); if t.semblances == %{}, do: t end)
    assert gone, "light orb never expired"
    assert_in_delta ledger(gone, :semblance_light_j), 200.0, 1.0e-9
    assert_in_delta ledger(gone, :semblance_released_j), 0.0, 1.0e-6
    assert ledger(gone, :semblance_created_j) == 200.0
    closed?(gone)
  end

  test "驱散：燃烧中的叶上驱散热球 → 拟态消失、余热作为有限热源落入叶格、火继续；账闭合", c do
    assert {:ok, _} = draw(c, 1_000_000)
    assert {:ok, %{seq: seq}} = cast(c, c.presets["hot_throw"], @forward, at: 2_000_000)
    assert Enum.find_value(1..60, fn _ -> burning?(commit(c.w)) end)
    before = Enum.find_value(1..10, fn _ -> t = commit(c.w); if t.thermal.sources == %{}, do: t end)
    assert Map.has_key?(before.semblances, {seq, 0})
    fed = fn t -> t.thermal.supplied_j - ledger(t, :combustion_j) end

    # 驱散只付构型损耗 2107.4444193 J（落脚下）；目标拟态 id 由线上给出，眼到球心 √(0² + 0.136² + 2.1²) ≈ 2.10 m < 6 m。
    assert {:ok, %{outcome: nil, caster: %{spent_j: dispel_j}}} =
             cast(c, c.presets["dispel"], @forward, at: 3_000_000, semblance: {seq, 0})
    assert_in_delta dispel_j, 2107.4444193, 1.0e-6
    after_dispel = observe(c.w)
    assert after_dispel.semblances == %{}
    released = ledger(after_dispel, :semblance_released_j) - ledger(before, :semblance_released_j)
    assert released > 0
    closed?(after_dispel)

    # 释放的热与脚下构型损耗都经有限热源进世界：热源放完后供热（去掉燃烧）增量 = 释放 + 2107.4444193 J。
    drained = Enum.find_value(1..10, fn _ -> t = commit(c.w); if t.thermal.sources == %{}, do: t end)
    assert_in_delta fed.(drained) - fed.(before), released + 2107.4444193, 1.0e-3
    # 驱散不追溯：叶继续燃烧。
    assert burning?(commit(c.w))
    # 已移除的 id 再驱散：stale_target，不扣能量。
    energy = energy(c)
    assert {:error, :stale_target} = cast(c, c.presets["dispel"], @forward, at: 4_000_000, semblance: {seq, 0})
    assert energy(c) == energy
  end

  test "上限：同一施法者第 7 个拟态拒绝 semblance_limit；他人地块内落点拒绝 protected_region；拒绝不扣能量", c do
    assert {:ok, _} = draw(c, 1_000_000)

    for i <- 1..6 do
      assert {:ok, %{outcome: nil}} = cast(c, light(120), @forward, at: 1_000_000 + i * 1_000_000)
    end

    seq = World.seq(c.w)
    energy = energy(c)
    assert {:error, :semblance_limit} = cast(c, light(120), @forward, at: 8_000_000)
    assert {World.seq(c.w), energy(c)} == {seq, energy}

    # 驱散一个后恢复余量；他人（cid 2002）认领叶所在列 → 投向叶被拒。
    [{id, _} | _] = Enum.sort(observe(c.w).semblances)
    assert {:ok, _} = cast(c, c.presets["dispel"], @forward, at: 9_000_000, semblance: id)
    {:ok, _} = World.author_regions(c.w, [%{holder: {:character, 2002}, min: {0, 3}, max: {0, 3}}])
    seq = World.seq(c.w)
    energy = energy(c)
    assert {:error, :protected_region} = cast(c, c.presets["hot_throw"], @forward, at: 10_000_000)
    assert {World.seq(c.w), energy(c)} == {seq, energy}
  end

  test "冷重启：落地热球的温度、年龄与接触随日志重放与检查点延续，重启后继续冷却", c do
    assert {:ok, _} = draw(c, 1_000_000)
    # 斜向下投向前方地面（石），不着火；落地后几次提交。
    {dy, dz} = {-0.6, 0.8}
    assert {:ok, %{seq: seq}} = cast(c, c.presets["hot_throw"], {0.0, dy, dz}, at: 2_000_000)
    for _ <- 1..3, do: commit(c.w)
    landed = observe(c.w).semblances[{seq, 0}]
    assert landed.kinetic_j == 0.0 and landed.contact.cell |> elem(1) == 0

    persisted = fn ->
      OverlayLog.File.replay(Path.join(c.root, "overlay.log"))
      |> Enum.filter(&Map.has_key?(&1, :thermal))
      |> List.last()
      |> then(& &1.thermal.semblances[{seq, 0}])
    end

    w = restart(c)
    stored = persisted.()
    assert observe(w).semblances[{seq, 0}] == stored
    assert stored.temperature_k > 293.15 + 1
    :ok = World.compact(w)
    w = restart(%{c | w: w})
    assert observe(w).semblances[{seq, 0}] == stored
    cooled = commit(w).semblances[{seq, 0}]
    assert cooled.temperature_k < stored.temperature_k and cooled.age_s > stored.age_s
  end

  test "下发：canonical 订阅快照含窗口内拟态；施放事务带新记录，驱散事务带 nil 删除", c do
    assert {:ok, _} = draw(c, 1_000_000)
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, snapshot}, 5_000
    assert snapshot.semblances == %{}

    assert {:ok, %{seq: seq}} = cast(c, light(120), @forward, at: 2_000_000)
    assert_receive {:canonical_delta, %{transaction_seq: ^seq, transaction: %{semblances: %{{^seq, 0} => orb}}}}, 5_000
    assert {orb.caster, orb.glow_w, orb.rest} == {@cid, 100.0, {0.5, 2.5, 1.0}}
    assert Map.has_key?(observe(c.w).semblances, {seq, 0})

    assert {:ok, %{seq: dispel}} = cast(c, c.presets["dispel"], @forward, at: 3_000_000, semblance: {seq, 0})
    assert_receive {:canonical_delta, %{transaction_seq: ^dispel, transaction: %{semblances: %{{^seq, 0} => nil}}}}, 5_000
  end
end
