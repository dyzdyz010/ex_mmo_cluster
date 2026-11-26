defmodule VoxelRegion.MagicStructureWorldTest do
  @moduledoc """
  只测试：魔法 v2 切片 4c 的结构运行时在真实 World 里的接线（决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md`
  §4、§13 W4-1–W4-4、Q4-5；设计 TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` §5、§12.1 更正 3、附录 A）。

  - 契约：经 `World.spell_intent/3` 施放的结构在同一笔事务里出现施放记录 live 0 与结构记录 live 1、扣费等于报价；
    每次热提交推进一拍、按 id 升序步进；灯按附录 A.3 在第 264 ± 1 拍断供衰竭（live 3）；结构账按去向逐项整数闭合；
    冷重启后持久化记录逐位相同、从下一拍继续不补算；每人至多 6 个结构；释放执行时复核保护区持有者；热结构经内核限流。
  - 场景（同 `magic_world_test.exs`，Y-up，1 宏格 = 1 m）：地面石 11 铺 y = 0；施法者脚 (0.5, 1.0, 0.5)、眼 (0.5, 2.5, 0.5)；
    蓄能石 A (2,1,0) 经持久化边界安装一次 10 MJ（作者初态），施法者经正式〈取〉入口取能；孤立叶 (0,2,3)。
  - 驱动：手动时钟（World 不自行开始热提交），测试以 `:thermal_commit` 逐次推进热提交（与定时提交同一内核与提交路径）；
    观察走公开订阅（PropertyBatch 的结构增量）、`TestSupport.observe/3` 的热账与日志回放。
  - 期望：灯寿命 264 拍取附录 A.3（132 s / 0.5 s）；装载 56 = round(0.221 × 255)；限流取设计 §5.3.1 的上限
    min(t_hi, 2500 K)；其余是不变量（整数闭合、逐位相同、计数上限）。不复制 `Magic.Structure` 的算法当期望。
  - 不覆盖：〈遇〉接触与飞行终点由射程推导（切片 5）、驱散与打断（切片 6）、准入与触发预算（切片 7）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @catalog Path.expand("../priv/magic", __DIR__) |> Path.join("*.json") |> Path.wildcard() |> then(fn [path] -> path end)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @catalog
  @external_resource Path.join(@fixtures, "magic/ir-v2-samples.json")
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @simulation_box {{-8, 0, -2}, {12, 3, 5}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @leaf_micro {4, 20, 28}
  # 地面石 (2, 0, 2) 顶层的微格：炽热投掷斜向下投向这里（弹道不经过蓄能石与叶）。
  @ground_micro {20, 7, 20}

  defmodule ManualClock do
    @moduledoc "只测试：不推进的时钟，热提交只由测试显式投递。"
    @behaviour VoxelRegion.World.Clock
    @impl true
    def now(_), do: 0
    @impl true
    def schedule(_, _, _, _), do: make_ref()
    @impl true
    def cancel(_, _), do: false
  end

  setup do
    root = Path.join(System.tmp_dir!(), "structure_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @properties <> ".json"]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    File.cp!(@catalog, Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -8..12, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}])
    a = actor()
    # 作者初态：蓄能石 A 的正式属性行经持久化边界写入 10 MJ（同 `magic_world_test.exs`）。
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    w = start(root)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{w: w, root: root, a: a, digest: :crypto.hash(:sha256, File.read!(@catalog))}
  end

  defp start(root) do
    start_supervised!(
      {World,
       [
         source: Source,
         log: Log,
         root: root,
         observer: self(),
         name: nil,
         clock: {ManualClock, nil},
         property_catalog_path: Path.join(root, "properties.json"),
         thermal_environment_path: Path.join(root, "environment.json"),
         magic_catalog_path: Path.join(root, "magic.json")
       ]},
      id: :world
    )
  end

  defp restart(c) do
    :ok = stop_supervised(:world)
    w = start(c.root)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{c | w: w}
  end

  defp actor do
    a = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5}, tick_us: 16_667}

    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp energy(c), do: elem(World.caster_state(c.w, @cid), 1).energy_j
  defp program(id), do: Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  defp aim(a, {x, y, z}) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {dx / n, dy / n, dz / n}
  end

  defp query(a, micro) do
    seq = next()

    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 1, direction: aim(a, micro),
      micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  defp request(c, micro, bytes, opts) do
    {:ok, target} = World.tool_intent(c.w, c.a, query(c.a, micro))
    seq = next()

    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: Keyword.get(opts, :action, 1),
      catalog_digest: c.digest, direction: aim(c.a, micro), program: bytes}
    |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
  end

  defp spell(c, micro, bytes, opts \\ []) do
    request = request(c, micro, bytes, opts)
    at = Keyword.get(opts, :at, request.client_intent_seq * 1_000_000)
    VoxelRegion.TestSupport.spell(c.w, Map.merge(c.a, %{received_us: at, clock_node: node()}), request)
  end

  # 〈取〉程序（设计 §11.4.1）：kind 0、下标 0、`energy_j` 槽 dec。
  defp draw(energy_j) do
    e = Enum.find(0..15, &(rem(energy_j, 10 ** &1) == 0 and div(energy_j, 10 ** &1) <= 4095))
    <<2, 0, 1, 0::16, e::4, div(energy_j, 10 ** e)::12>>
  end

  defp fund(c, request_j, at) do
    assert {:ok, %{outcome: nil}} = spell(c, @stone_micro, draw(request_j), at: at)
  end

  defp subscribe(c) do
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, snapshot}, 5_000
    snapshot
  end

  # 建成：返回 {结构 id, 出生记录, 施放回复}。施放记录 live 0 与结构记录 live 1 必须在同一笔事务里（W4-1）。
  defp build(c, micro, preset, at) do
    assert {:ok, %{outcome: nil} = reply} = spell(c, micro, program(preset), at: at)
    assert_receive {:canonical_delta, %{transaction: %{casts: %{@cid => %{live: 0, outcome: 0}}} = txn}}, 5_000
    assert [{id, record}] = Map.to_list(Map.fetch!(txn, :structures))
    assert id == {txn.seq, 0} and txn.seq == reply.seq
    {id, record, reply}
  end

  # 推进一次热提交并等它落定：`:thermal_commit` 遇装页时在装页结束后才续完，所以等观察到的热提交拍号前进（5 s 超时）。
  defp commit(c) do
    before = tick(c)
    send(c.w, :thermal_commit)

    Enum.reduce_while(1..500, nil, fn _, _ ->
      if tick(c) > before do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)
    |> then(&assert(&1 == :ok, "热提交 #{before + 1} 未在 5 s 内完成"))
  end

  # 热提交拍号（Q4-9）：只在出现过结构参与的提交后才有，之前为 0。
  defp tick(c), do: Map.get(observe(c.w).thermal, :commit_tick, 0)

  # 收下邮箱里已到的全部结构增量：{完整记录 [{seq, id, record}], 状态增量 [{seq, id, record}]}。
  defp drain do
    Stream.repeatedly(fn ->
      receive do
        {:canonical_delta, %{transaction: txn}} -> txn
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.reduce({[], []}, fn txn, {records, states} ->
      {records ++ for({id, r} <- Map.get(txn, :structures, %{}), do: {txn.seq, id, r}),
       states ++ for({id, r} <- Map.get(txn, :structure_states, %{}), do: {txn.seq, id, r})}
    end)
  end

  defp info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  # 结构账（整数 mJ）按去向闭合：created + heat_in = light + anima + leak_heat + released + stored（决策稿 §4.2）。
  defp assert_accounts_closed(thermal) do
    get = &Map.get(thermal, &1, 0)
    keys = [:structure_created_mj, :structure_heat_in_mj, :structure_light_mj, :anima_radiated_mj, :structure_leak_heat_mj,
      :structure_released_mj, :structure_stored_mj]
    assert Enum.all?(keys, &is_integer(get.(&1))), inspect(Map.take(thermal, keys))

    assert get.(:structure_created_mj) + get.(:structure_heat_in_mj) ==
             get.(:structure_light_mj) + get.(:anima_radiated_mj) + get.(:structure_leak_heat_mj) +
               get.(:structure_released_mj) + get.(:structure_stored_mj),
           inspect(Map.take(thermal, keys))
  end

  test "W4-1 灯经 spell_intent 建成：扣费 = 报价；同一事务里施放记录 live 0 与结构记录 live 1；load 56、温度 0、发光 100 W", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    assert {:ok, %{caster: quoted}} = spell(c, @leaf_micro, program("lamp"), action: 0, at: 1_500_000)
    before = energy(c)

    {{seq, 0} = id, record, reply} = build(c, @leaf_micro, "lamp", 2_000_000)
    assert reply.caster.spent_j == quoted.quote_j
    assert_in_delta energy(c), before - quoted.quote_j, 1.0e-6

    # 线上字段（决策稿 §3.1）：灯无质量、静止在手边，无〈热〉温度 0，发光取〈辉〉标称 100 W，线内无状态位。
    assert %{live: 1, caster: @cid, shape: 0, massless: true, ends_on_contact: false, load: 56, coherence: 255,
             temperature_k: +0.0, glow_w: 100.0, status: [], coupling: [:glow], anchor_type: 0, flight_s: +0.0} = record
    assert record.origin == record.rest and record.velocity == {0.0, 0.0, 0.0}
    {ex, ey, ez} = c.a.eye
    {dx, dy, dz} = aim(c.a, @leaf_micro)
    assert record.rest == {ex + dx * 0.5, ey + dy * 0.5, ez + dz * 0.5}
    # 记录满足 Hello 46 编码约束（编码端违约即抛错）。
    assert byte_size(Codec.encode_structures(%{id => record})) == 160

    s = observe(c.w)
    assert s.structures == %{id => record}
    assert s.thermal.structures == 1 and Map.get(s.thermal, :commit_tick, 0) == 0
    # 物理能量 = 〈蓄〉50 kJ（灯无热份额与动能），构型损耗留脚下。
    assert s.thermal.structure_created_mj == 50_000_000 and s.thermal.structure_stored_mj == 50_000_000
    assert seq == reply.seq
  end

  test "W4-2 灯逐拍出账至第 264 ± 1 拍以 live 3 断供衰竭（附录 A.3）；状态增量每拍至多一条；账目逐项整数闭合", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, _record, _} = build(c, @leaf_micro, "lamp", 2_000_000)
    born = tick(c)

    # 投递的 `:thermal_commit` 遇装页时异步完成，所以拍数取观察到的 commit_tick（出生到终止），不数投递次数。
    {states, ended} =
      Enum.reduce_while(1..400, {[], nil}, fn _, {acc, _} ->
        commit(c)
        {records, states} = drain()
        acc = acc ++ states

        case for({_, ^id, %{live: live} = r} <- records, live != 1, do: r) do
          [] -> {:cont, {acc, nil}}
          [ended] -> {:halt, {acc, ended}}
        end
      end)

    assert ended, "400 次提交内灯未终止"
    tick = tick(c) - born
    assert tick in 263..265, "灯在第 #{tick} 拍终止"
    assert ended.live == Codec.structure_end_live(:exhausted)
    # 终态快照：最后一拍仍发出光（发光在泄漏之后支付），装载已降到很低。
    assert ended.glow_w > 0 and ended.load < 56
    # 状态增量：每拍至多一条，且只在分箱改变时发（远少于拍数）。
    assert length(Enum.uniq_by(states, &elem(&1, 0))) == length(states)
    assert length(states) < tick

    s = observe(c.w)
    assert s.structures == %{}
    assert s.thermal.structures == 0 and s.thermal.structure_stored_mj == 0
    # 灯悬在手边空气里：泄漏与释放的热落不进任何格，全部计入灵炁辐射账；发光逐拍计入光账。
    assert Map.get(s.thermal, :structure_leak_heat_mj, 0) == 0 and Map.get(s.thermal, :structure_released_mj, 0) == 0
    assert s.thermal.structure_light_mj > 0 and s.thermal.anima_radiated_mj > 0
    assert_accounts_closed(s.thermal)
  end

  test "W4-4 冷重启：持久化的结构记录与观察逐位相同，从 commit_tick + 1 继续，不补算停机时间", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, _record, _} = build(c, @leaf_micro, "lamp", 2_000_000)
    for _ <- 1..10, do: commit(c)
    before = observe(c.w)
    persisted = fn -> Path.join(c.root, "overlay.log") |> OverlayLog.File.replay() |> Enum.filter(&Map.has_key?(&1, :thermal)) |> List.last() end
    %{thermal: %{structures: %{^id => stored}, commit_tick: tick}} = persisted.()
    # 落盘的是显式字段 map（Q4-7），拍号与结构的最后一拍一致。
    refute is_struct(stored.structure)
    assert stored.structure.last_tick == tick and tick == before.thermal.commit_tick

    c = restart(c)
    after_restart = observe(c.w)
    assert after_restart.structures == before.structures
    keys = [:commit_tick, :structures, :structure_stored_mj, :structure_created_mj, :structure_light_mj, :anima_radiated_mj]
    assert Map.take(after_restart.thermal, keys) == Map.take(before.thermal, keys)

    commit(c)
    %{thermal: %{structures: %{^id => next}, commit_tick: next_tick}} = persisted.()
    assert next_tick == tick + 1 and next.structure.last_tick == tick + 1
    # 只走了一拍：运转储能恰好少一拍的出账（灯无供能、无热，出账为正），没有按停机时长补算。
    assert next.structure.e_op_mj < stored.structure.e_op_mj
    assert next.structure.born_tick == stored.structure.born_tick
  end

  test "Q4-5 每施法者至多 6 个结构：第 7 次施放以 :structure_quota 拒绝，不扣能、不改世界", c do
    fund(c, 1_000_000, 1_000_000)

    for k <- 1..6 do
      assert {:ok, %{outcome: nil}} = spell(c, @leaf_micro, program("lamp"), at: (1 + k) * 1_000_000)
    end

    assert map_size(observe(c.w).structures) == 6
    {seq, balance} = {World.seq(c.w), energy(c)}
    assert {:error, :structure_quota} = spell(c, @leaf_micro, program("lamp"), at: 9_000_000)
    assert {World.seq(c.w), energy(c)} == {seq, balance}
  end

  test "§12.1 更正 3：释放执行时复核持有者——定时火种贴在叶上，叶列随后归他人，到期〈散〉只发辐射、不写叶格", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, record, _} = build(c, @leaf_micro, "timed_ember", 2_000_000)
    assert record.anchor_type == 1
    # 他人（cid 2002）在施放之后认领叶所在列。
    {:ok, _} = World.author_regions(c.w, [%{holder: {:character, 2002}, min: {0, 3}, max: {0, 3}}])
    drain()

    log =
      info_log(fn ->
        Enum.reduce_while(1..80, nil, fn _, _ ->
          commit(c)
          {records, _} = drain()
          if Enum.any?(records, fn {_, rid, r} -> rid == id and r.live == 6 end), do: {:halt, :ended}, else: {:cont, nil}
        end)
      end)

    assert log =~ ~r/voxel_structure_end .*sid=#{Regex.escape(inspect(id))} .*live=6 type=released .*protected=true/
    s = observe(c.w)
    assert Map.get(s.thermal, :structure_leak_heat_mj, 0) == 0 and Map.get(s.thermal, :structure_released_mj, 0) == 0
    refute Map.has_key?(s.thermal.sources, {0, 2, 3})
    assert_accounts_closed(s.thermal)
  end

  test "对照：无保护区时定时火种的泄漏与释放热落进叶格（有限热源），live 6", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, _record, _} = build(c, @leaf_micro, "timed_ember", 2_000_000)

    ended =
      Enum.reduce_while(1..80, nil, fn _, _ ->
        commit(c)
        {records, _} = drain()
        case for({_, ^id, %{live: 6} = r} <- records, do: r) do
          [] -> {:cont, nil}
          [r] -> {:halt, r}
        end
      end)

    assert %{live: 6} = ended
    s = observe(c.w)
    assert s.thermal.structure_released_mj > 0
    assert_accounts_closed(s.thermal)
  end

  test "W4-3 炽热投掷落地后作为受限热节点：T_port ≤ min(t_hi, 2500 K) 且逐拍下降；限流日志按提交汇总；账目闭合", c do
    fund(c, 2_000_000, 1_000_000)
    fund(c, 2_000_000, 2_000_000)
    subscribe(c)
    {id, record, _} = build(c, @ground_micro, "hot_throw", 3_000_000)
    assert :flying in record.status and not record.massless
    assert_in_delta record.temperature_k, 2000.0, 1.0e-9

    log =
      info_log(fn ->
        for _ <- 1..6, do: commit(c)
      end)

    # 每次提交一行汇总（只在有受限节点参与时，飞行的第 1 拍没有）：落地后第一拍 2000 K 球的辐射远超 Φ_cap，吞吐缩放 < 1；
    # 降温后不再受限。一次提交多次内核调用时子步数相加（calls ≥ 2 的行）。
    throttles =
      for [_, tick, throttled, _clamped, scale, steps, calls] <-
            Regex.scan(~r/voxel_thermal_throttle tick=(\d+) throttled_nodes=(\d+) clamped_nodes=(\d+) min_scale=([\d.e-]+) kernel_steps=(\d+) calls=(\d+)/, log),
          do: {String.to_integer(tick), String.to_integer(throttled), String.to_float(scale), String.to_integer(steps), String.to_integer(calls)}

    assert [{_, 1, scale, _, _} | _] = throttles
    assert scale < 1.0
    assert Enum.all?(throttles, fn {_, _, _, steps, calls} -> steps >= calls end)
    assert Enum.any?(throttles, fn {_, _, _, _, calls} -> calls >= 2 end)

    {_, states} = drain()
    temperatures = for {_, ^id, r} <- states, do: r.temperature_k
    s = observe(c.w)
    current = s.structures[id]
    temperatures = temperatures ++ [current.temperature_k]
    assert Enum.all?(temperatures, &(&1 <= 2500.0))
    assert temperatures == Enum.sort(temperatures, :desc)
    assert current.temperature_k < 2000.0
    assert s.thermal.structure_heat_in_mj < 0
    assert_accounts_closed(s.thermal)
  end
end
