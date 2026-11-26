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
  - 切片 5（飞行与〈遇〉，决策稿 §5、§13 W5-1–W5-5 与 §14 用户答复）：带〈投〉的结构由墙钟飞行驱动（`World.Projectiles`）
    逐段飞行；测试注入服务器时间线时钟 `FlightClock`（施放记录 t0 与飞行时长同源），推进它并直接投递 `:projectile_tick`
    （与 50 ms 定时拍同一入口）。墙：石格 (2, 2, 4)、(2, 1, 4)，火球自手边瞄向它。飞行中唯一的欠账来源（P1 无〈乱〉接线）
    是邻近终止释放剂量：定时火种贴叶 (0, 2, 3)，第 60 拍〈散〉释放约 187 kJ，作用于 3 m 内其后处理的结构（4c 已接线）。
  - 不覆盖：驱散与打断（切片 6）、准入与触发预算（切片 7）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Semblance, Structure}
  alias VoxelRegion.World.{Casting, Closure, Structures}
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
  # 墙石 (2, 2, 4) 的中心微格：火球自手边瞄向它，弹道越过叶的一侧、在 t ≈ 0.26 s 撞上墙的 z = 4 面。
  @wall_micro {20, 20, 36}
  # 法杖光弹（切片 5 Q5-1、切片 5b）：无质量（`mass_g` 0000）、〈蓄〉1742 J（第 3 拍衰竭区间的中点，见决策稿 §14 切片 5b）。
  @bolt_hex "020101000700010002000032000000000000010010006401001b06ce01001e7530010001002201002c00"

  defmodule FlightClock do
    @moduledoc "只测试：服务器时间线的注入单调时钟（µs，`MmoContracts.ServerTime` 同接口），由测试推进。"
    def now(agent), do: Agent.get(agent, & &1)
  end

  defmodule BodyBackend do
    @moduledoc """
    只测试：人物采样后端替身（代替 `WorldServer.Movement.Projectile` 与真实 Scene/Player）。`:persistent_term` 里登记的目标
    站在飞行体出发点沿初速方向 `at_m` 米处：采样时若这段飞行越过它，返回该段内的比例与目标上下文；冻结交付一律接纳并回执，
    每次调用都报给测试进程。
    """
    def poll(shots, clock) do
      %{test: test, target: target, at_m: at_m} = :persistent_term.get(__MODULE__)
      now = MmoContracts.ServerTime.server_us(clock)

      for {id, shot} <- shots do
        case shot do
          %{impact_delivery: hit} ->
            send(test, {:backend_delivered, id, hit})
            {id, shot.age_s, {:delivered, {:ok, Map.take(hit, [:key, :q_j])}}}

          _ ->
            send(test, {:backend_sampled, id})
            age = max(shot.age_s, (now - shot.t0_us) / 1.0e6)
            {vx, vy, vz} = shot.velocity
            t = at_m / :math.sqrt(vx * vx + vy * vy + vz * vz)
            hit = if age > shot.age_s and t > shot.age_s and t <= age, do: {(t - shot.age_s) / (age - shot.age_s), target}
            {id, shot.age_s, {:sample, age, shot.projectile_source, hit, now}}
        end
      end
    end

    def notify(hit, seq) do
      send(:persistent_term.get(__MODULE__).test, {:backend_notified, hit, seq})
      :ok
    end
  end

  defmodule BeyondSource do
    @moduledoc "只测试：region x ≥ 3（格 x ≥ 192）的 baseline 不存在（`:missing`），其余同 `TestSupport.Source`。"
    defdelegate open(opts), to: VoxelRegion.TestSupport.Source
    defdelegate content_version(s), to: VoxelRegion.TestSupport.Source
    defdelegate world_dir(s), to: VoxelRegion.TestSupport.Source
    defdelegate generated(s), to: VoxelRegion.TestSupport.Source
    defdelegate ensure(s, level, region), to: VoxelRegion.TestSupport.Source
    def read(_s, 0, {x, _, _}) when x >= 3, do: {:error, :missing}
    def read(s, level, region), do: VoxelRegion.TestSupport.Source.read(s, level, region)
  end

  defmodule HoldLog do
    @moduledoc "只测试：文件后端；登记了停点时把下一次发布停在发布点（同 `persist_backlog_test.exs`），使积压按事务数涨到中上限。"
    alias VoxelRegion.OverlayLog.File, as: Log
    defdelegate open(path, cv), to: Log
    defdelegate replay(path), to: Log
    defdelegate append(path, txn), to: Log
    defdelegate checkpoint(path, txn), to: Log
    defdelegate prefix(path), to: Log
    defdelegate clear_unpublished(path, prefix), to: Log
    defdelegate write_pages(path, cut, rows), to: Log
    defdelegate load(path), to: Log
    defdelegate load_head(path, code), to: Log
    defdelegate read_pages(path, keys, fragments), to: Log
    defdelegate locate(path, ids), to: Log
    defdelegate page_keys(path), to: Log
    defdelegate collect(path, prefix, limit), to: Log

    def publish(path, cut, rows, globals) do
      case :persistent_term.get({__MODULE__, path}, nil) do
        owner when is_pid(owner) ->
          :persistent_term.erase({__MODULE__, path})
          send(owner, {:holding_publish, self()})

          receive do
            :continue -> :ok
          end

        _ ->
          :ok
      end

      Log.publish(path, cut, rows, globals)
    end
  end

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
    wall = [{{2, 1, 4}, @stone}, {{2, 2, 4}, @stone}]
    {:ok, _} = World.apply_edits(w, ground ++ wall ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}])
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

    clock = start_supervised!({Agent, fn -> 1_000_000_000 end}, id: :flight_clock)
    w = start(root, clock: clock)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{w: w, root: root, a: a, clock: clock, opts: [], digest: :crypto.hash(:sha256, File.read!(@catalog))}
  end

  # `opts`：`clock`（服务器时间线 Agent，缺省用生产单调时钟）与直接透传给 World 的 `projectile_backend`、`log`、`source`、
  # `persist_backlog`。
  defp start(root, opts \\ []) do
    {clock, opts} = Keyword.pop(opts, :clock)

    world_opts =
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
      ]
      |> Keyword.merge(if(clock, do: [server_clock: {FlightClock, clock}], else: []))
      |> Keyword.merge(opts)

    start_supervised!({World, world_opts}, id: :world)
  end

  defp restart(c, opts \\ []) do
    :ok = stop_supervised(:world)
    opts = Keyword.merge(c.opts, opts)
    w = start(c.root, [clock: c.clock] ++ opts)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{c | w: w, opts: opts}
  end

  # 推进服务器时间线 `seconds` 秒并投递一个投射物拍，等它（含过页闸的采样结果）处理完。
  defp fly(c, seconds) do
    Agent.update(c.clock, &(&1 + round(seconds * 1_000_000)))
    send(c.w, :projectile_tick)
    await(fn -> VoxelRegion.TestSupport.projectiles_settled?(c.w) end)
  end

  # 分 50 ms 拍飞行（与定时拍同步长），直到 `stop?.()` 成立或飞满 `seconds`。
  defp fly_until(c, seconds, stop?) do
    Enum.reduce_while(1..round(seconds / 0.05), nil, fn _, _ ->
      fly(c, 0.05)
      if stop?.(), do: {:halt, :ok}, else: {:cont, nil}
    end)
  end

  defp await(fun) do
    Enum.reduce_while(1..500, nil, fn _, _ ->
      if fun.() do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)
    |> then(&assert(&1 == :ok, "5 s 内未达成等待条件"))
  end

  defp actor(extra \\ %{}) do
    a = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5}, tick_us: 16_667} |> Map.merge(extra)

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

  # 结构账（整数 mJ）按去向闭合：created + heat_in = light + anima + leak_heat + released + body + stored（决策稿 §4.2；
  # body 为切片 5 人物命中进入组织的部分）。
  defp assert_accounts_closed(thermal) do
    get = &Map.get(thermal, &1, 0)
    keys = [:structure_created_mj, :structure_heat_in_mj, :structure_light_mj, :anima_radiated_mj, :structure_leak_heat_mj,
      :structure_released_mj, :structure_body_mj, :structure_stored_mj]
    assert Enum.all?(keys, &is_integer(get.(&1))), inspect(Map.take(thermal, keys))

    assert get.(:structure_created_mj) + get.(:structure_heat_in_mj) ==
             get.(:structure_light_mj) + get.(:anima_radiated_mj) + get.(:structure_leak_heat_mj) +
               get.(:structure_released_mj) + get.(:structure_body_mj) + get.(:structure_stored_mj),
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
    # 切片 5：飞行按墙钟推进（服务器时间线），落地后才作为热节点；一拍飞完全程（约 0.5 s）。
    fly(c, 1.0)
    assert :flying not in observe(c.w).structures[id].status

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

  # ---------------------------------------------------------------------------
  # 切片 5：飞行与〈遇〉（决策稿 §5、§13 W5-1–W5-5、§14 用户答复）
  # ---------------------------------------------------------------------------

  # 以程序字节施放；`direction` 覆盖准星方向（无质量光弹水平射出，不打到地面）。返回 {结构 id, 出生记录}。
  defp build_program(c, micro, bytes, at, direction \\ nil) do
    request = request(c, micro, bytes, [])
    request = if direction, do: %{request | direction: direction}, else: request
    actor = Map.merge(c.a, %{received_us: at, clock_node: node()})
    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(c.w, actor, request)
    assert_receive {:canonical_delta, %{transaction: %{casts: %{@cid => %{live: 0, outcome: 0}}} = txn}}, 5_000
    assert [{id, record}] = Map.to_list(Map.fetch!(txn, :structures))
    {id, record}
  end

  defp bolt(energy_j \\ 1742),
    do: @bolt_hex |> Base.decode16!(case: :lower) |> binary_part(0, 26) |> Kernel.<>(<<0::4, energy_j::12>>) |>
          Kernel.<>(binary_part(Base.decode16!(@bolt_hex, case: :lower), 28, 14))

  # 飞到弹道上与 `point` 相距 [lo, hi] m 的最早时刻（5 ms 步长，纯运动学），一拍推进到那里后停住（时钟不再前进）。
  defp hover(c, record, point, lo, hi) do
    t =
      Enum.find(1..200, fn k ->
        d = distance(Semblance.position(record.origin, record.velocity, k * 0.005, record.massless), point)
        d >= lo and d <= hi
      end) * 0.005

    fly(c, t)
    t
  end

  defp distance({ax, ay, az}, {bx, by, bz}), do: :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2 + (bz - az) ** 2)

  # 日志里最后一份持久化的结构值（显式字段 map 经 `Structure.from_record/2` 换回）。
  defp persisted(c, id) do
    %{thermal: %{structures: %{^id => %{structure: record}}}} =
      Path.join(c.root, "overlay.log") |> OverlayLog.File.replay() |> Enum.filter(&Map.has_key?(&1, :thermal)) |> List.last()

    {:ok, s} = Structure.from_record(record, Catalog.load(@catalog))
    s
  end

  # 逐次热提交，直到 `id` 出现终止记录（live ≠ 1）；返回 {提交次数, 终止记录}。
  defp commit_until_end(c, id, max) do
    Enum.reduce_while(1..max, nil, fn n, _ ->
      commit(c)
      {records, _} = drain()

      case for({_, ^id, %{live: live} = r} <- records, live != 1, do: r) do
        [] -> {:cont, nil}
        [ended] -> {:halt, {n, ended}}
      end
    end)
    |> tap(&assert(&1, "#{max} 次提交内 #{inspect(id)} 未终止"))
  end

  # 逐次热提交，收集 `ids` 各自的终止记录，直到全部终止；返回 %{id => {第几次提交, 终止记录}}。
  defp commit_until_all(c, ids, max) do
    Enum.reduce_while(1..max, %{}, fn n, acc ->
      commit(c)
      {records, _} = drain()
      acc = Enum.reduce(records, acc, fn {_, id, r}, acc -> if id in ids and r.live != 1, do: Map.put(acc, id, {n, r}), else: acc end)
      if map_size(acc) == length(ids), do: {:halt, acc}, else: {:cont, acc}
    end)
    |> tap(&assert(map_size(&1) == length(ids), "#{max} 次提交内未全部终止：#{inspect(Map.keys(&1))}"))
  end

  defp ended_record(id) do
    {records, _} = drain()
    assert [ended] = for({_, ^id, %{live: live} = r} <- records, live != 1, do: r)
    ended
  end

  defp register_backend(target_at_m) do
    target = %{id: 2002, identity: :target, life_generation: 7, position: {11.0, 1.0, 0.5}, velocity: {0.0, 0.0, 0.0},
      tissue_k: 307.15, tissue_c_j_per_k: 209.4}

    :persistent_term.put(BodyBackend, %{test: self(), target: target, at_m: target_at_m})
    on_exit(fn -> :persistent_term.erase(BodyBackend) end)
  end

  test "W5-1 火球撞墙：投射物提交点以 live 2 终止，rest 为命中点；动能与释放进墙格，账目闭合", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, record} = build_program(c, @wall_micro, program("fireball"), 2_000_000)
    assert :flying in record.status and record.ends_on_contact and not record.massless

    log = info_log(fn -> fly_until(c, 1.0, fn -> observe(c.w).structures == %{} end) end)
    ended = ended_record(id)
    assert ended.live == Codec.structure_end_live(:contact) and :flying not in ended.status
    # 球心停在墙的 z = 4 面外一个半径（0.25 m）；飞行终点即命中时刻，落点在该时刻的弹道上（z 取面）。
    {x, y, z} = ended.rest
    assert_in_delta z, 4.0 - 0.25, 1.0e-9
    assert x > 2.0 and x < 3.0 and y > 2.0 and y < 3.0
    # 地形按 50 ms 弦段求交：命中点在弦上，与抛物线相差不超过弦的拱高 g·Δt²/8 ≈ 3 mm。
    {px, py, _} = Semblance.position(record.origin, record.velocity, ended.flight_s, false)
    assert_in_delta x, px, 0.005
    assert_in_delta y, py, 0.005
    assert ended.flight_s > 0.2 and ended.flight_s < 0.3

    sid = Regex.escape(inspect(id))
    assert log =~ ~r/voxel_structure_flight sid=#{sid} .*phase=contact target=terrain .*reading_lost=false/
    assert log =~ ~r/voxel_structure_end .*sid=#{sid} .*live=2 type=released .*cell=\{2, 2, 4\} .*hit=terrain/

    s = observe(c.w)
    # 运转储能热半、热份额（至多到 T_port）与动能（0.5 kg × 12² / 2 = 36 J）都进墙格；墙格得到有限热源。
    assert s.thermal.structure_released_mj > 36_000
    assert Map.has_key?(s.thermal.sources, {2, 2, 4})
    assert_accounts_closed(s.thermal)
  end

  test "W5-2 过热保险火球：邻近定时火种终止释放把相干压到 0.5 以下，〈满〉在命中前触发 → 飞行中 live 6", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {ember, ember_record} = build_program(c, @leaf_micro, program("timed_ember"), 2_000_000)
    # 过热保险火球的寿命约 39 拍（附录 A.3：19.5 s），短于火种的 60 拍：火种走过 40 拍后再施放。
    for _ <- 1..40, do: commit(c)
    drain()
    {id, record} = build_program(c, @wall_micro, program("guarded_fireball"), 3_000_000)
    # 停在距火种 1.3–1.4 m 处：剂量按 (1 − d / 3 m)² 衰减，火种约 187 kJ 的释放在这里把相干压进 (0.3, 0.5)。
    t = hover(c, record, ember_record.rest, 1.3, 1.4)
    assert :flying in observe(c.w).structures[id].status

    # 火种第 60 拍〈散〉；过热保险在同一拍或读数丢失（p = min(0.5, debt / 0.5)）时晚几拍触发，始终在飞行中。
    %{^ember => {ember_n, ember_end}, ^id => {n, ended}} = commit_until_all(c, [ember, id], 40)
    assert ember_end.live == 6
    assert n >= ember_n and n - ember_n <= 10, "火种第 #{ember_n} 次、过热保险第 #{n} 次提交终止"
    assert :flying not in ended.status
    assert ended.live == Codec.structure_end_live(:released)
    assert ended.coherence < 128 and ended.coherence > 76
    assert_in_delta ended.flight_s, t, 1.0e-9
    assert ended.rest == Semblance.position(record.origin, record.velocity, t, false)
    assert_accounts_closed(observe(c.w).thermal)
  end

  test "W5-3 法杖光弹（无质量）：直线匀速、无射程终点，第 3 拍在飞行中以 live 3 衰竭；发射相位 0.05 s 与 0.5 s 时路程 31.5 m 与 45 m", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)

    # 发射相位 = 出生到第一个热拍的墙钟间隔（生产中在 (0, 0.5] s 内）。第 3 拍衰竭于 相位 + 1.0 s，路程 30 × (相位 + 1.0) m。
    for {phase, at} <- [{0.05, 2_000_000}, {0.5, 3_000_000}] do
      {id, record} = build_program(c, @leaf_micro, bolt(), at, {1.0, 0.0, 0.0})
      assert record.massless and record.ends_on_contact and :flying in record.status
      assert record.velocity == {30.0, 0.0, 0.0}
      # 线上预测到预计飞行时长 1.5 s（报价寿命 1.255 s 的整拍上界）为止，不在施法域 30 m 处截断。
      assert record.flight_s == 1.5

      fly_until(c, phase, fn -> false end)
      commit(c)
      fly_until(c, 0.5, fn -> false end)
      commit(c)
      assert %{live: 1} = observe(c.w).structures[id]
      fly_until(c, 0.5, fn -> false end)

      log = info_log(fn -> commit(c) end)
      ended = ended_record(id)
      assert ended.live == Codec.structure_end_live(:exhausted) and :flying not in ended.status
      {ox, oy, oz} = record.origin
      assert_in_delta ended.flight_s, phase + 1.0, 1.0e-9
      {x, y, z} = ended.rest
      assert_in_delta x - ox, 30.0 * (phase + 1.0), 1.0e-9
      assert {y, z} == {oy, oz}
      assert x - ox >= 30.0
      assert log =~ ~r/voxel_structure_end .*live=3 type=exhausted .*in_flight=true /
    end

    s = observe(c.w)
    # 悬空终止：释放落不进格，全部计入灵炁辐射账。
    assert Map.get(s.thermal, :structure_released_mj, 0) == 0
    assert_accounts_closed(s.thermal)
  end

  test "W5-3 光弹命中人物（采样后端替身）：冻结交付、Player 接纳后 live 2；组织得 E_op 热半 871 J，辐射半只记账", c do
    register_backend(10.0)
    c = restart(c, projectile_backend: BodyBackend)
    # Player 形状的施法者（带生命代次）才采样人物（Q5-4 且沿 v1）。
    c = %{c | a: actor(%{life_generation: 3, position: {0.5, 1.0, 0.5}})}
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, record} = build_program(c, @leaf_micro, bolt(), 2_000_000, {1.0, 0.0, 0.0})

    # 第一拍越过 10 m 处的人物（t = 1/3 s）：冻结交付，停在命中点（不再飞行），终止记录等接纳结果。
    fly(c, 0.4)
    assert_received {:backend_sampled, ^id}
    {records, _} = drain()
    assert [frozen] = for({_, ^id, r} <- records, do: r)
    assert frozen.live == 1 and :flying not in frozen.status
    {ox, oy, oz} = record.origin
    assert_in_delta frozen.flight_s, 10.0 / 30.0, 1.0e-9
    assert_in_delta elem(frozen.rest, 0), ox + 10.0, 1.0e-9
    assert {elem(frozen.rest, 1), elem(frozen.rest, 2)} == {oy, oz}

    # 下一拍交付：Q5-2 进入组织的是 E_op 热半——命中在第一个热拍之前，E_op = 〈蓄〉1742 J，不补记维持费（Q5-3 暂行），
    # 所以 q = ½ × 1742 J = 871 J；无〈热〉、无质量，没有热份额与动能；辐射半 871 J 只记账。
    fly(c, 0.05)
    assert_received {:backend_delivered, ^id, %{q_j: q_j, target: %{id: 2002, life_generation: 7}}}
    assert q_j == 871.0
    assert_received {:backend_notified, %{q_j: 871.0}, seq}
    ended = ended_record(id)
    assert ended.live == Codec.structure_end_live(:contact) and ended.rest == frozen.rest

    s = observe(c.w)
    assert s.seq == seq
    assert s.thermal.structure_body_mj == 871_000
    assert s.thermal.projectile_body_j == 871.0 and s.thermal.body_exchange_j == 871.0
    assert_accounts_closed(s.thermal)
  end

  test "A5 伤害随距离衰减是能量账的自然结果：同一光弹约 2 m 处命中进组织 871 J，接近衰竭（第 2 拍后、40 m）处约 574 J", c do
    register_backend(2.0)
    c = restart(c, projectile_backend: BodyBackend)
    c = %{c | a: actor(%{life_generation: 3, position: {0.5, 1.0, 0.5}})}
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)

    # 近：2 m 处的人物（t = 1/15 s），在第一个热拍之前命中——E_op 仍是〈蓄〉1742 J，q = ½ × 1742 J。
    {near, _} = build_program(c, @leaf_micro, bolt(), 2_000_000, {1.0, 0.0, 0.0})
    fly(c, 0.1)
    fly(c, 0.05)
    assert_received {:backend_delivered, ^near, %{q_j: near_j}}
    assert ended_record(near).live == Codec.structure_end_live(:contact)

    # 远：40 m 处的人物（t = 4/3 s）。飞行中走过两个热拍（维持费逐拍扣），第 3 拍之前命中——接近衰竭。
    register_backend(40.0)
    {far, _} = build_program(c, @leaf_micro, bolt(), 3_000_000, {1.0, 0.0, 0.0})
    fly(c, 0.5)
    commit(c)
    fly(c, 0.5)
    commit(c)
    fly(c, 0.4)
    fly(c, 0.05)
    assert_received {:backend_delivered, ^far, %{q_j: far_j}}
    assert ended_record(far).live == Codec.structure_end_live(:contact)

    # 没有任何距离衰减规则：近大远小只来自飞行中的维持出账（第 2 拍后 E_op = 1 147 879 mJ，q = ½ × E_op 按整数 mJ
    # 四舍五入 = 573 940 mJ）。组织块热容 209.4 J/K：近处升温 871 / 209.4 ≈ 4.16 K，远处 573.94 / 209.4 ≈ 2.74 K。
    assert near_j == 871.0
    assert far_j == 573.94
    assert near_j > far_j
    assert_accounts_closed(observe(c.w).thermal)
  end

  test "W5-4 带欠账的火球：投射物提交点的〈遇〉读数丢失时不触发、停在命中点，之后第一个未丢失的热拍以 live 2 终止", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {ember, ember_record} = build_program(c, @leaf_micro, program("timed_ember"), 2_000_000)
    # 火球的寿命约 49 拍（附录 A.3：24.5 s），火种走过 40 拍后再施放，火种释放后还剩约 29 拍可找丢失拍。
    for _ <- 1..40, do: commit(c)
    drain()
    {id, record} = build_program(c, @wall_micro, program("fireball"), 3_000_000)
    # 停在距火种 1.55–1.7 m 处：火种的终止释放给它约 0.3–0.45 的欠账（相干仍高于 0.3），读数丢失概率 0.5。
    hover(c, record, ember_record.rest, 1.55, 1.7)
    {_, %{live: 6}} = commit_until_end(c, ember, 70)
    catalog = Catalog.load(@catalog)

    # 找一拍：纯值层判定在下一拍号求值〈遇〉会丢失（丢失判定按 mix64(id, tick) 由纯值用例对冻结向量证明）。
    lost =
      Enum.find_value(1..30, fn _ ->
        s = persisted(c, id)
        assert s.debt_micro > 0

        case Structure.evaluate_rules(s, %{contact: true}, s.last_tick + 1, catalog) do
          {_, []} -> s
          _ -> commit(c) && nil
        end
      end)

    assert lost, "30 拍内没有丢失拍"
    log = info_log(fn -> fly_until(c, 1.0, fn -> :flying not in observe(c.w).structures[id].status end) end)
    sid = Regex.escape(inspect(id))
    assert log =~ ~r/voxel_structure_flight sid=#{sid} .*phase=contact target=terrain .*reading_lost=true/
    {records, _} = drain()
    assert [landed] = for({_, ^id, r} <- records, do: r)
    assert landed.live == 1 and :flying not in landed.status
    assert_in_delta elem(landed.rest, 2), 3.75, 1.0e-9

    # 接触保持待决：之后的热拍重判，第一个未丢失的拍以 live 2（读〈遇〉的规则）终止，落点不变。
    {n, ended} = commit_until_end(c, id, 20)
    assert n >= 1
    assert ended.live == Codec.structure_end_live(:contact) and ended.rest == landed.rest
    assert_accounts_closed(observe(c.w).thermal)
  end

  test "W5-5 冷重启：飞行中的结构以 live 3 就地散解（一笔事务），不再采样人物；账目闭合", c do
    register_backend(1000.0)
    c = restart(c, projectile_backend: BodyBackend)
    c = %{c | a: actor(%{life_generation: 3, position: {0.5, 1.0, 0.5}})}
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {id, record} = build_program(c, @wall_micro, program("fireball"), 2_000_000)
    fly(c, 0.1)
    assert_received {:backend_sampled, ^id}
    # 热提交把飞行进度（0.1 s）随 thermal 落盘。
    commit(c)
    before = observe(c.w).thermal

    log = info_log(fn -> send(self(), {:restarted, restart(c)}) end)
    assert_received {:restarted, c}
    sid = Regex.escape(inspect(id))
    {x, y, z} = Semblance.position(record.origin, record.velocity, 0.1, false)
    assert log =~ ~r/voxel_structure_flight sid=#{sid} .*phase=restored target=none t_s=0.1 /
    assert log =~ ~r/voxel_structure_end .*sid=#{sid} .*live=3 type=exhausted .*reason=restored/
    assert log =~ ~r/voxel_projectile_restored_dissipated /
    assert log =~ "rest=#{inspect({x, y, z})}"

    s = observe(c.w)
    assert s.structures == %{}
    assert s.thermal.anima_radiated_mj > before.anima_radiated_mj
    assert_accounts_closed(s.thermal)
    send(c.w, :projectile_tick)
    refute_receive {:backend_sampled, _}, 200
  end

  test "离开可读范围：无质量投掷飞进 baseline 不存在的 region 时在该段起点以 live 3 就地散解，记 out_of_domain", c do
    c = restart(c, source: BeyondSource)
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    # 〈蓄〉4000 J 的光弹在热拍里约飞 5 s（第 10 拍衰竭）；本例不推进热提交，只飞行。x = 192 m 以外的 region 读不出 canonical。
    {id, _record} = build_program(c, @leaf_micro, bolt(4000), 2_000_000, {1.0, 0.0, 0.0})
    log = info_log(fn -> fly_until(c, 7.0, fn -> observe(c.w).structures == %{} end) end)
    ended = ended_record(id)
    assert ended.live == Codec.structure_end_live(:exhausted)
    {x, _, _} = ended.rest
    assert x < 192.0 and x > 190.0
    sid = Regex.escape(inspect(id))
    assert log =~ ~r/voxel_structure_out_of_domain sid=#{sid} .*reason=\{\{3, 0, 0\}, :missing\}/
    assert log =~ ~r/voxel_structure_flight sid=#{sid} .*phase=out_of_domain/
    assert_accounts_closed(observe(c.w).thermal)
  end

  # 有质量的光弹变体（`mass_g` 10 g，即 v1 迁来的原程序字节 `000a`）：用来证明有质量投掷同样没有射程终点。
  defp massed_bolt(energy_j) do
    bytes = bolt(energy_j)
    binary_part(bytes, 0, 16) <> <<10::16>> <> binary_part(bytes, 18, byte_size(bytes) - 18)
  end

  test "A1 有质量投掷没有射程终点：上仰 20° 抛出，施放时预测到弹道下降时刻（不在 30 m 截断），飞过 30 m 路程照常沿弹道飞", c do
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    up = {:math.cos(:math.pi() / 9), :math.sin(:math.pi() / 9), 0.0}
    {id, record} = build_program(c, @leaf_micro, massed_bolt(4000), 2_000_000, up)
    assert not record.massless and :flying in record.status

    # 预计飞行时长（`Structures.flight_horizon_s/4`）：有质量取 min(整拍寿命, t_fall)。手边 y = 2.5 + 0.5·sin 20°，
    # 施法者脚 y = 1.0 → 支撑格底面 y = 0，D = 手边高度；t_fall = (v_y + √(v_y² + 2gD)) / g ≈ 2.33 s（寿命约 5 s）。
    {_, hy, _} = record.origin
    {_, vy, _} = record.velocity
    t_fall = (vy + :math.sqrt(vy * vy + 2 * 9.81 * hy)) / 9.81
    # 测试世界 x > 12 m 之外没有地面，预测不命中：线上预测到 t_fall 为止。旧规则按路程 30 m（约 1.0 s）截断。
    assert_in_delta record.flight_s, t_fall, 1.0e-9
    {ox, _, _} = record.origin
    {rx, _, _} = record.rest
    assert rx - ox > 60.0

    # 真实飞行：不推进热拍（不衰竭），飞 1.5 s（路程 > 30 m 施法域）仍在飞行，位置在弹道上。
    fly_until(c, 1.5, fn -> false end)
    flight = Enum.find(World.stats(c.w).simulation_progress.projectiles.flights, &(&1.id == inspect(id)))
    assert_in_delta flight.simulated_through_s, 1.5, 1.0e-9
    assert :flying in observe(c.w).structures[id].status
    {x, y, _} = Semblance.position(record.origin, record.velocity, 1.5, false)
    assert x > 30.0 and y > 2.0
  end

  test "A3 读取闭包与前摇驻留：施法域按 range_m，投掷结构另加按报价推导的飞行走廊（4000 J 光弹 T = 5 s、约 150 m）", c do
    state = :sys.get_state(c.w)
    {:ok, program} = Program.diagnose_ir(bolt(4000), state.magic)
    key = make_ref()
    actor = Map.put(c.a, :action_key, key)
    request = %{direction: {1.0, 0.0, 0.0}, program: bolt(4000)}
    state = %{state | pending_casts: %{@cid => %{actor: actor, request: request, program: program}}}

    # 预计飞行时长：报价寿命 life_s ≈ 4.886 s → 整拍上界 (⌊4.886 / 0.5⌋ + 1) × 0.5 = 5.0 s；无质量路程 30 m/s × 5 s = 150 m。
    quote = Cost.quote_structure(program, state.magic, %{ambient_k: 293.15, formation_distance_m: 0.0, emissivity: 0.9,
      exchange_w_per_m2_k: 10.0})
    assert_in_delta quote.life_s, 4.886, 0.001
    assert Structures.flight_horizon_s(quote, {30.0, 0.0, 0.0}, true, 2.5) == 5.0

    # 出手闭包：施法域（眼 ±30 m → x region −1..0）加 +x 走廊到 x = 1 + 150 = 151 m（region 2，[128, 192)）；
    # 走廊止于 T，不到 region 3；施法域方向之外（−x 的 region −2）不装。
    {keys, [], []} = Closure.needs(state, {:authorize_cast, key, actor, request})
    regions = MapSet.new(for {0, r} <- keys, do: r)
    assert {2, 0, 0} in regions and {1, 0, 0} in regions
    refute {3, 0, 0} in regions
    refute {-2, 0, 0} in regions
    # 报价（前摇开始）不建结构、不预测：只装施法域。
    {quote_keys, [], []} = Closure.needs(state, {:spell_intent, actor, request})
    refute {0, {2, 0, 0}} in quote_keys
    # 前摇期间的驻留需求与出手闭包同一走廊。
    assert {:ok, {resident, _, _}} = Casting.residency_dependencies(state)
    assert {0, {2, 0, 0}} in resident
  end

  test "W4-6 积压达 mid：热提交与投射物拍都不开始，结构冻结（拍号与飞行进度不变）且仍计入每人上限", c do
    c = restart(c, log: HoldLog, persist_backlog: %{suffix_txns: {2, 12, 40}})
    assert :ok = World.compact(c.w)
    path = Path.join(c.root, "overlay.log")
    :persistent_term.put({HoldLog, path}, self())
    on_exit(fn -> :persistent_term.erase({HoldLog, path}) end)

    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {bolt_id, _} = build_program(c, @leaf_micro, bolt(4000), 2_000_000, {1.0, 0.0, 0.0})
    for k <- 1..5, do: build_program(c, @leaf_micro, program("lamp"), (2 + k) * 1_000_000)
    assert_receive {:holding_publish, writer}, 5_000

    Enum.reduce_while(1..20, nil, fn _, _ ->
      if World.stats(c.w).persist_level == :mid, do: {:halt, :ok}, else: (commit(c); {:cont, nil})
    end)

    assert World.stats(c.w).persist_level == :mid
    tick = tick(c)
    structures = observe(c.w).structures
    flight = fn -> Enum.find(World.stats(c.w).simulation_progress.projectiles.flights, &(&1.id == inspect(bolt_id))) end
    before = flight.()

    send(c.w, :thermal_commit)
    fly(c, 0.5)
    assert tick(c) == tick and observe(c.w).structures == structures
    assert flight.().simulated_through_s == before.simulated_through_s
    assert flight.().wait_reason == :writeback
    # 冻结的结构照常占用配额：第 7 个被拒（不扣能、不提交）。
    assert {:error, :structure_quota} = spell(c, @leaf_micro, program("lamp"), at: 9_000_000)
    send(writer, :continue)
  end

  test "W4-7 灼点贴在 500 K 的墙面上：第一拍 env 由接触格温度给出，越线位置位、x* ≈ 0.25（出生记录按报价不越线）", c do
    # 作者初态：墙石 (2, 2, 4) 的属性行经持久化边界写成 500 K（同 setup 给蓄能石充能的做法）。
    {:ok, row} = World.tool_intent(c.w, c.a, query(c.a, @wall_micro))
    seq = World.seq(c.w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(Path.join(c.root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{temperature_kelvin: 500.0, seq: seq + 1, request_id: 0})]
    })

    w = start(c.root, clock: c.clock)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    c = %{c | w: w}
    fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    {hot, hot_record} = build_program(c, @wall_micro, program("scorch"), 2_000_000)
    # 出生记录按报价（施法者所在格的气候温度，设计 §4.2）判越线：不越线。
    assert hot_record.status == []

    log = info_log(fn -> commit(c) end)
    {_, states} = drain()
    assert [{_, ^hot, hot_state}] = for({_, ^hot, _} = s <- states, do: s)
    assert :overline in hot_state.status

    [_, x_star, env, temperature] =
      Regex.run(~r/voxel_structure_state sid=#{Regex.escape(inspect(hot))} .*x_star=([\d.e-]+) env=([\d.e-]+) .*temperature_k=([\d.e-]+)/, log)

    # 手算（设计 §4.3）：env = 1 + 0.5 × (500 − 300) / 100 = 2，x* = √(((1 + 4 × 0.6124²) / 2 − 1) / 4) = 0.25。
    assert_in_delta String.to_float(temperature), 500.0, 1.0
    assert_in_delta String.to_float(env), 2.0, 0.01
    assert_in_delta String.to_float(x_star), 0.25, 0.005
    assert hot_state.load / 255 > String.to_float(x_star)
  end
end
