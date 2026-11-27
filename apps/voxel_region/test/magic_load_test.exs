defmodule VoxelRegion.MagicLoadTest do
  @moduledoc """
  只测试（`@moduletag :load`，默认排除）：魔法 v2 切片 8a，Linux 合成负载（决策稿
  `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §8.1、§12.3 风险 1–2、§13 L8-1 / L8-2；设计 TheWorldBook
  `docs/2026-11-19-glyph-composition-game-design.md` §5.6、§5.9、§12.2 切片 1 验收第 6 条）。

  ## 要证明什么

  分区内满额魔法负载下，World 每拍（0.5 s 热提交）的耗时、热活动集、每拍持久化与日志字节、积压分级，是否在设计 §5.6
  的结算预算与 §5.9 的写入量假设之内；以及 T15 反例（最小合法热容、2500 K）对热内核子步数的影响。

  ## 环境与数据（全部由本次运行拥有，跑完清理）

  - 进程内 World：不开 Gate/QUIC，**不创建任何 UDP/TCP socket**；持久化走正式后端 `OverlayLog.Db`（本 VM 的测试库，
    独立 `content_version`，开始与结束各清一次该世界的行）。外加一个 gate 式订阅与一个 canonical 订阅（各一个丢弃进程），
    使广播与编码成本计入每拍时间。
  - 世界：平地石铺 (−2..30) × (−2..31)，8 × 8 个站位（间距 4 m）。施法者全部是替身玩家（`TestSupport.Actor`），经
    `World.send_caster_state/4` 开户（与玩家登录同一入口，一次性充能）、`World.caster_presence/3` 推送在场，结构全部经
    `World.spell_intent/3`（`TestSupport.spell/3`）施放产生，不写 `thermal.structures`。
  - 程序（发布预设或按 IR v2 规则改参数的合法程序，签名与报价照常校验）：
    - 热节点：发布预设“灼点”（1500 K，〈蓄〉15 kJ），贴石面；整个寿命（31.5 s，63 拍）都醒着（探查实测），到寿由新施法者
      在别的站位补施——“16 个醒着的热节点”靠持续施放维持，与无〈链〉的 P1 一致（热结构不会长期醒着）。
    - 规则：“定时火种”只把〈时〉由 30 s 改为 600 s（每个 1 条规则；寿命约 572 s，窗口内既不触发也不衰竭）。
    - 其余：发布预设“灯”（寿命 132 s），到寿补施。
    - L8-2 反例：〈附〉球 r = 120 mm、82 g、〈热〉2500 K、〈蓄〉5 kJ。82 g 是该半径下 T15（0.45·C_th / g_max ≥ 25 ms，
      附录 A.7）报价不拒的最小质量（测试开头用真实报价扫描确认），C_th = 41 J/K；r = 100 mm 时热份额超容量，被拒。端口温度
      只在出生后几秒接近 2500 K（吞吐限流下热份额很快放出），所以〈蓄〉取 T13 允许的小值（寿命约 8 s），到寿即补施，窗口里
      反复出现“刚出生、最热”的时刻；摘要按反例端口温度 ≥ 1500 K 的拍与其余拍分开统计内核子步与 `nif_us`。
  - 档 a（设计原数，**probe**）：256 结构 / 16 醒着热节点 / 64 规则（权重 320 单位）。发布预算 B = 256 造不出，probe 目录只把
    `quotas.region_budget_units` 调到 512，其余字节同发布目录；组成由本测试的补施目标决定，不由准入决定。
  - 档 b（正常准入上限）：发布目录 `22c459f0…` 原样；16 醒着热节点 + 64 规则优先，其余用灯填到准入拒绝为止（B + R = 288 单位）。
  - L8-2：档 b 的组成，16 个热节点中的 1 个换成上面的反例结构。

  ## 驱动与窗口

  手动时钟：World 不自排热提交，本测试按墙钟 500 ms 投递 `:thermal_commit`（落后时立即投递下一拍，并计入落后量）；
  分页切点、写回进程等 World 自己的墙钟定时器照常运行。预热 `LOAD_WARMUP_S`（缺省 60 s 模拟）内按节奏错开出生（热节点每
  4 拍至多 1 个、灯每拍至多 2 个），使寿命到期均匀分布；共同采样窗口 `LOAD_WINDOW_S`（缺省 240 s，L8-2 为 `LOAD_L82_WINDOW_S`
  缺省 120 s）。每档总模拟时长 ≤ 5 min。

  ## 测量（只读 World 已有的结构化日志与本测试的计量包装，生产代码不加判定）

  - 每拍 World 时间：`voxel_thermal_callback elapsed_us`（热提交整拍处理时间），分项 `voxel_thermal_sim steps_us`（热内核段）、
    `voxel_structure_tick elapsed_us / step_us_total / step_us_max`（结构步进）、`voxel_thermal_commit persist_us / broadcast_us`。
  - 热活动集：`voxel_thermal_sim hot / candidates`、`voxel_thermal_kernel nodes`（世界格无魔法时为 0，所以即增量）。
  - 热内核：`voxel_thermal_kernel nif_us / kernel_steps / simulated_s`、`voxel_thermal_throttle`。
  - 持久化字节：计量包装 `MeteredLog` 按行统计每笔追加与页切点写入的 payload 字节（与 `OverlayLog.Db` 同一行表示，只多一次求和）；
    热事务的元数据行另抽样解码，估算 `thermal.structures` 的份额。
  - 日志字节：World 进程每拍发出的 `voxel_*` 结构化日志行字节数。
  - 积压：`voxel_persist_backlog` 级别变化、`voxel_page_cut`。

  ## 判定（阈值只在测试侧，AGENTS §2.2-9）

  设计 §5.6 / §5.9 的数值：每拍 World 时间 p95 ≤ 500 ms（一拍）；`Structure.step` 平均 ≤ 30 µs、最坏 ≤ 100 µs / 结构 / 拍、
  每分区最坏 ≤ 26 ms；持久化 ≤ 16 KB / 拍（p95）；积压分级不触发；T15：每个 50 ms 段的内核子步 ≤ 2。另有窗口有效性（拍数
  足额、组成达标）。全部数字与判定写进摘要 JSON（`LOAD_OUT`，缺省新建临时目录）并打印；任一判定不过，用例失败（不把失败改成通过）。

  运行（WSL）：`cd apps/voxel_region && mix test --no-start --only load test/magic_load_test.exs`
  """
  use ExUnit.Case, async: false
  @moduletag :load
  @moduletag timeout: :infinity

  alias DataService.Voxel.OverlayLogStore
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.Magic.{Catalog, Cost, Program}
  alias VoxelRegion.TestSupport.Actor

  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @catalog Path.expand("../priv/magic", __DIR__) |> Path.join("*.json") |> Path.wildcard() |> then(fn [path] -> path end)
  @external_resource @catalog
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @content_version 8_026_112_601
  @stone 11
  @tick_ms 500
  # 平地与站位（宏格，Y-up，1 宏格 = 1 m）。
  @ground for x <- -2..30, z <- -2..31, do: {x, 0, z}
  @simulation_box {{-4, 0, -4}, {33, 4, 34}}
  @stations 64
  @grant_mj VoxelRegion.World.Casting.initial_charge_mj()

  # 设计 §5.6 结算预算、§5.9 写入量、附录 A.7 T15（测试侧阈值）。
  @budget %{tick_us: 500_000, step_mean_us: 30, step_max_us: 100, region_step_us: 26_000, persist_bytes: 16 * 1024,
    steps_per_50ms: 2}

  # ---------------------------------------------------------------------------
  # 只测试的支撑模块
  # ---------------------------------------------------------------------------

  defmodule LoadSource do
    @moduledoc "只测试：`TestSupport.Source` 的空气世界，换一个独立的 content_version（Db 后端按它隔离本次运行的行）。"
    defdelegate open(opts), to: VoxelRegion.TestSupport.Source
    def content_version(_), do: 8_026_112_601
    defdelegate world_dir(s), to: VoxelRegion.TestSupport.Source
    defdelegate generated(s), to: VoxelRegion.TestSupport.Source
    defdelegate ensure(s, level, region), to: VoxelRegion.TestSupport.Source
    defdelegate read(s, level, region), to: VoxelRegion.TestSupport.Source
  end

  defmodule MeteredLog do
    @moduledoc """
    只测试：正式后端 `OverlayLog.Db` 的计量包装。追加用与 `Db.append/2` 相同的 `OverlayLog.rows/1` 行表示写库，再把各行
    payload 字节数（和元数据行本身，refc binary 不复制）发给计量进程；页切点的段行与全局行同样计字节。其余回调原样委托。
    """
    @behaviour VoxelRegion.OverlayLog
    alias VoxelRegion.OverlayLog.Db

    defp meter(message) do
      case :persistent_term.get({__MODULE__, :meter}, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end

    defp bytes(rows), do: Enum.reduce(rows, 0, fn row, sum -> sum + byte_size(Map.get(row, :payload, <<>>)) end)

    @impl true
    def open(dir, cv), do: Db.open(dir, cv)

    @impl true
    def append(cv, txn) do
      rows = OverlayLog.rows(txn)
      :ok = DataService.Voxel.OverlayLogStore.append(cv, rows)
      meta = Enum.find_value(rows, fn row -> if row.kind == 3, do: row.payload end)
      meter({:persist, :append, txn.seq, bytes(rows), length(rows), meta, Map.has_key?(txn, :thermal) and txn[:entries] == []})
      :ok
    end

    @impl true
    def write_pages(cv, cut, rows) do
      result = Db.write_pages(cv, cut, rows)
      meter({:persist, :pages, cut, bytes(rows), 0})
      result
    end

    @impl true
    def publish(cv, cut, rows, globals) do
      result = Db.publish(cv, cut, rows, globals)
      meter({:persist, :pages, cut, bytes(rows), byte_size(globals)})
      result
    end

    @impl true
    defdelegate replay(cv), to: Db
    @impl true
    defdelegate checkpoint(cv, txn), to: Db
    @impl true
    defdelegate prefix(cv), to: Db
    @impl true
    defdelegate clear_unpublished(cv, prefix), to: Db
    @impl true
    defdelegate load(cv), to: Db
    @impl true
    defdelegate collect(cv, prefix, limit), to: Db
    @impl true
    defdelegate load_head(cv, segment), to: Db
    @impl true
    defdelegate read_pages(cv, keys, fragments), to: Db
    @impl true
    defdelegate locate(cv, ids), to: Db
    @impl true
    defdelegate page_keys(cv), to: Db
  end

  defmodule Capture do
    @moduledoc "只测试：logger 处理器，把 World 的 `voxel_*` 结构化日志行转给测量进程。"
    def log(%{msg: {:string, text}}, %{config: %{pid: pid}}) do
      text = IO.chardata_to_string(text)
      if String.starts_with?(text, "voxel_"), do: send(pid, {:load_log, text})
      :ok
    end

    def log(_, _), do: :ok
  end

  defmodule ManualClock do
    @moduledoc "只测试：不推进的时钟，热提交只由测试按墙钟节奏投递。"
    @behaviour VoxelRegion.World.Clock
    @impl true
    def now(_), do: 0
    @impl true
    def schedule(_, _, _, _), do: make_ref()
    @impl true
    def cancel(_, _), do: false
  end

  defmodule ServerClock do
    @moduledoc "只测试：服务器时间线（µs），每拍由测试推进 500 ms。"
    def now(agent), do: Agent.get(agent, & &1)
  end

  # ---------------------------------------------------------------------------
  # 程序
  # ---------------------------------------------------------------------------

  defp sample(id), do: Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  # 定时火种：〈时〉duration_cs 由 3000（30 s）改为 60000（600 s），其余字节同发布预设。
  defp ember do
    <<head::binary-size(31), 3000::16, tail::binary>> = sample("timed_ember")
    head <> <<60_000::16>> <> tail
  end

  # 〈蓄〉槽：4 位十进制指数 + 12 位尾数（设计 §11.4.2）。
  defp energy(j) do
    exp = Enum.find(0..15, fn x -> div(j, Integer.pow(10, x)) < 4096 and rem(j, Integer.pow(10, x)) == 0 end)
    <<exp::4, div(j, Integer.pow(10, exp))::12>>
  end

  # L8-2 反例：〈附〉〈形 球 120 mm, mass_g〉〈热 2500 K〉〈蓄 5 kJ〉（布局同发布预设“灼点”）。
  defp hot_probe(mass_g),
    do: <<2, 1, 1, 0, 8, 0xFF, 0, 1, 0, 2, 0, 120::16, 0::32, mass_g::16, 1, 0, 15, 25_000::16, 1, 1, 0, 27>> <>
          energy(5_000) <> <<0, 0>>

  @site %{ambient_k: 293.15, formation_distance_m: 2.0, emissivity: 0.9, exchange_w_per_m2_k: 10.0}

  # T15 报价不拒的最小质量：真实报价扫描（82 g 以下有 `:thermal_step`）。
  defp min_legal_mass(catalog) do
    Enum.find(1..65_535, fn m ->
      case Program.diagnose_ir(hot_probe(m), catalog) do
        {:ok, p} -> not Enum.any?(Cost.quote_structure(p, catalog, @site).rejects, &(&1.check == :thermal_step))
        _ -> false
      end
    end)
  end

  defp programs(catalog_path) do
    catalog = Catalog.load(catalog_path)
    mass = min_legal_mass(catalog)

    programs = %{scorch: sample("scorch"), ember: ember(), lamp: sample("lamp"), probe: hot_probe(mass)}

    quotes =
      Map.new(programs, fn {kind, bytes} ->
        {:ok, p} = Program.diagnose_ir(bytes, catalog)
        q = Cost.quote_structure(p, catalog, @site)
        assert q.rejects == [], "#{kind} 报价被拒：#{inspect(q.rejects)}"
        {kind, q}
      end)

    %{bytes: programs, quotes: quotes, probe_mass_g: mass,
      # 本地记账：一次施放按报价总价的 1.05 倍预留（结算按当时 site 重报价，差异很小），不足就换新施法者。
      cost: Map.new(quotes, fn {k, q} -> {k, round(q.total_mj * 1.05)} end)}
  end

  # ---------------------------------------------------------------------------
  # 环境
  # ---------------------------------------------------------------------------

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "magic_load_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    sink = spawn(fn -> sink() end)
    :ok = OverlayLogStore.reset_world(@content_version)

    on_exit(fn ->
      :persistent_term.erase({MeteredLog, :meter})
      Process.exit(sink, :kill)
      File.rm_rf!(root)
      OverlayLogStore.reset_world(@content_version)
    end)

    out = System.get_env("LOAD_OUT") || Path.join(System.tmp_dir!(), "magic_load_out_#{System.os_time(:second)}")
    %{root: root, sink: sink, out: out}
  end

  defp sink do
    receive do
      _ -> sink()
    end
  end

  defp start_world(c, quotas) do
    File.cp!(Path.join([@fixtures, "combustion", @properties <> ".json"]), Path.join(c.root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(c.root, "environment.json"))
    magic = Path.join(c.root, "magic.json")

    if quotas == %{} do
      File.cp!(@catalog, magic)
    else
      catalog = @catalog |> File.read!() |> Jason.decode!()
      File.write!(magic, Jason.encode!(update_in(catalog["quotas"], &Map.merge(&1, quotas))))
    end

    clock = start_supervised!({Agent, fn -> 1_000_000_000_000 end}, id: :server_clock)

    w =
      start_supervised!(
        {World,
         [source: LoadSource, log: MeteredLog, root: c.root, observer: c.sink, name: nil, clock: {ManualClock, nil},
          server_clock: {ServerClock, clock}, property_catalog_path: Path.join(c.root, "properties.json"),
          thermal_environment_path: Path.join(c.root, "environment.json"), magic_catalog_path: magic]},
        id: :world
      )

    {:ok, _} = World.apply_edits(w, Enum.map(@ground, &{&1, @stone}))
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    tiles = VoxelRegion.TestSupport.tiles(@simulation_box)
    # 一个在线玩家的两路下行：gate 式日志订阅与 canonical 订阅（丢弃进程接收）。
    :ok = World.subscribe(w, c.sink, 0, tiles, 0)
    :ok = World.canonical_snapshot_and_subscribe(w, tiles, c.sink, make_ref())

    Map.merge(c, %{w: w, clock: clock, tiles: tiles, digest: :crypto.hash(:sha256, File.read!(magic)),
      programs: programs(magic), catalog_path: magic})
  end

  # ---------------------------------------------------------------------------
  # 施法者与施放
  # ---------------------------------------------------------------------------

  defp station_xz(s), do: {4 * rem(s, 8), 4 * div(s, 8)}

  # 目标格：热结构与火种贴不同的石面；灯（〈握〉）只需一个合法射线目标。
  defp target_cell(kind, {x, z}) when kind in [:scorch, :probe], do: {x + 1, 0, z + 1}
  defp target_cell(:ember, {x, z}), do: {x - 1, 0, z + 1}
  defp target_cell(:lamp, {x, z}), do: {x, 0, z + 1}

  defp new_caster(c, run, kind) do
    cid = run.next_cid
    station = rem(run.station_counter, @stations)
    {x, z} = station_xz(station)

    a = %{cid: cid, controller: :player, gate: c.sink, identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {x + 0.5, 2.5, z + 0.5}, feet: {x + 0.5, 1.0, z + 0.5}, tick_us: 16_667}

    a = Map.put(a, :player, start_supervised!({Actor, a}, id: {:actor, cid}))
    :ok = GenServer.call(a.player, {:presence, c.w, :present})
    _ = World.send_caster_state(c.w, cid, 0, {c.sink, a.identity})
    caster = %{cid: cid, actor: a, kind: kind, station: {x, z}, spent_mj: 0}

    {caster, %{run | next_cid: cid + 1, station_counter: run.station_counter + 1,
      casters: Map.put(run.casters, cid, caster), pools: Map.update(run.pools, kind, [cid], &(&1 ++ [cid]))}}
  end

  defp aim({ex, ey, ez}, {x, y, z}) do
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {dx / n, dy / n, dz / n}
  end

  defp next_id, do: System.unique_integer([:positive, :monotonic])

  # 一次施放：射线取目标（正式工具入口）再经 `World.spell_intent/3` 施放；`at` 为 Gate 入口时刻（全局每次 +1 s，施法间隔
  # GCRA 自然满足）。返回 :built 或拒绝原因。
  defp cast(c, run, caster, kind) do
    {cx, _, cz} = target_cell(kind, caster.station)
    micro = {cx * 8 + 4, 4, cz * 8 + 4}
    a = caster.actor
    q = %{request_id: next_id(), client_intent_seq: next_id(), logical_scene_id: 1, action: 0, tool_id: 1,
      direction: aim(a.eye, micro), micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, target} = World.tool_intent(c.w, a, q)
    seq = next_id()

    request =
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, catalog_digest: c.digest,
        direction: aim(a.eye, micro), program: c.programs.bytes[kind]}
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))

    started = System.monotonic_time(:microsecond)
    result = VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: run.at, clock_node: node()}), request)
    us = System.monotonic_time(:microsecond) - started

    outcome =
      case result do
        {:ok, %{outcome: nil}} -> :built
        {:ok, %{outcome: other}} -> {:outcome, other}
        {:error, reason} -> reason
      end

    run = %{run | at: run.at + 1_000_000, cast_us: [us | run.cast_us], casts: Map.update(run.casts, {kind, outcome}, 1, &(&1 + 1))}

    run =
      if outcome == :built,
        do: update_in(run.casters[caster.cid].spent_mj, &(&1 + c.programs.cost[kind])),
        else: run

    {outcome, run}
  end

  # 选同类施法者：名下 < 6 个且本地记账余额够一次；没有就开一个新的。拥挤时（用量 ≥ 75%·B，设计 §5.6 的份额分支）只选名下
  # 已无结构的（在场人数几百时份额 < 1，名下有结构的必被拒，不为必然的拒绝施放）。拒绝时换新施法者再试一次（名下为空的在场者
  # 在 B 以内、或用预留保底时照常准入），新施法者也被拒即到上限。
  defp place(c, run, kind, per_caster, crowded?) do
    cost = c.programs.cost[kind]
    limit = if crowded?, do: 1, else: 6

    existing =
      Enum.find(Map.get(run.pools, kind, []), fn cid ->
        caster = run.casters[cid]
        caster.spent_mj + cost <= @grant_mj and Map.get(per_caster, cid, 0) < limit
      end)

    {caster, run} = if existing, do: {run.casters[existing], run}, else: new_caster(c, run, kind)

    case cast(c, run, caster, kind) do
      {:built, run} ->
        {:built, run, Map.update(per_caster, caster.cid, 1, &(&1 + 1))}

      {reason, run} when existing != nil and reason in [:region_budget, :structure_quota] ->
        {fresh, run} = new_caster(c, run, kind)

        case cast(c, run, fresh, kind) do
          {:built, run} -> {:built, run, Map.put(per_caster, fresh.cid, 1)}
          {reason, run} -> {reason, run, per_caster}
        end

      {reason, run} ->
        {reason, run, per_caster}
    end
  end

  # ---------------------------------------------------------------------------
  # 组成：普查与补施
  # ---------------------------------------------------------------------------

  # 普查（只读契约）：按施法者类别数结构、醒着的热结构；准入用量取 `World.stats/1`。
  defp census(c, run) do
    structures = VoxelRegion.TestSupport.observe(c.w, [], c.tiles).structures
    admission = World.stats(c.w).magic_admission

    acc = %{kinds: %{}, awake: %{}, per_caster: %{}, total: map_size(structures), probe_k: nil}

    acc =
      Enum.reduce(structures, acc, fn {_, r}, acc ->
        kind = get_in(run.casters, [r.caster, :kind]) || :other
        awake = kind in [:scorch, :probe] and :asleep not in r.status and :flying not in r.status
        probe_k = if kind == :probe, do: max(acc.probe_k || 0.0, r.temperature_k), else: acc.probe_k

        %{acc | probe_k: probe_k, kinds: Map.update(acc.kinds, kind, 1, &(&1 + 1)),
          awake: if(awake, do: Map.update(acc.awake, kind, 1, &(&1 + 1)), else: acc.awake),
          per_caster: Map.update(acc.per_caster, r.caster, 1, &(&1 + 1))}
      end)

    Map.merge(acc, %{units: admission.usage_units, budget: admission.budget_units, reserve: admission.reserve_units,
      awake_nodes: admission.awake_nodes, present: length(admission.present)})
  end

  # 本拍补施：按优先级（热节点 → 规则 → 灯）补到目标。预热期按节奏错开（热每 4 拍至多 1 个、灯每拍至多 2 个），之后补满。
  # 档 b 的灯“填到准入拒绝为止”，但先给缺的热节点各留 3 单位：否则热节点休眠（权重 3 → 1）或到寿腾出的零散单位会被灯占走，
  # 新热节点（要 3 单位）在上限处挤不进来，热节点数逐渐流失（首轮完整运行实测）。剩余单位不足时不再尝试（不为必然的拒绝开新户）。
  defp top_up(c, run, spec, tick, warmup?) do
    n = census(c, run)
    crowded? = n.units >= 0.75 * n.budget
    hot_cap = if warmup?, do: if(rem(tick, 4) == 0, do: 1, else: 0), else: :all
    scorch_need = max(spec.scorch - Map.get(n.awake, :scorch, 0), 0)
    probe_need = max(Map.get(spec, :probe, 0) - Map.get(n.awake, :probe, 0), 0)
    ember_need = max(spec.ember - Map.get(n.kinds, :ember, 0), 0)

    acc = {run, n.per_caster, n.budget + n.reserve - n.units}
    {acc, scorch} = place_n(c, acc, :scorch, capped(scorch_need, hot_cap), 3, crowded?)
    {acc, probe} = place_n(c, acc, :probe, probe_need, 3, crowded?)
    {{run, per_caster, room}, ember} = place_n(c, acc, :ember, ember_need, 1.5, crowded?)

    hot_deficit = scorch_need - scorch + probe_need - probe
    lamp_need = if spec.total == :fill, do: 10_000, else: spec.total - n.total - scorch - probe - ember
    lamp_cap = if warmup?, do: 2, else: :all

    {{run, _, _}, _} =
      place_n(c, {run, per_caster, room - 3 * hot_deficit}, :lamp, capped(max(lamp_need, 0), lamp_cap), 1, crowded?)

    run
  end

  defp capped(need, :all), do: need
  defp capped(need, cap), do: min(need, cap)

  # 逐个施放直到够数、剩余单位不足或被拒；返回 {累加器, 建成数}。
  defp place_n(c, acc, kind, count, weight, crowded?, built \\ 0)
  defp place_n(_c, acc, _kind, 0, _weight, _crowded?, built), do: {acc, built}

  defp place_n(c, {run, per_caster, room}, kind, count, weight, crowded?, built) do
    if room < weight do
      {{run, per_caster, room}, built}
    else
      case place(c, run, kind, per_caster, crowded?) do
        {:built, run, per_caster} -> place_n(c, {run, per_caster, room - weight}, kind, count - 1, weight, crowded?, built + 1)
        {_reason, run, per_caster} -> {{run, per_caster, room}, built}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 每拍驱动与测量
  # ---------------------------------------------------------------------------

  defp fields(text) do
    [name | pairs] = String.split(text, " ")
    {name, Map.new(for pair <- pairs, [k, v] <- [String.split(pair, "=", parts: 2)], do: {k, number(v)})}
  end

  defp number(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ ->
        case Float.parse(v) do
          {f, ""} -> f
          _ -> v
        end
    end
  end

  defp blank_tick,
    do: %{kernel: [], sim: nil, throttle: nil, structure: nil, commit: nil, callback: nil, appends: [], log_bytes: 0,
      log_lines: 0, sleep: nil, triggers: nil}

  # 投递一次热提交并收齐本拍的日志行，直到 `voxel_thermal_callback`（整拍处理完）。30 s 内没有完成即记为未完成拍（积压暂停等）。
  defp commit_tick(c, run) do
    send(c.w, :thermal_commit)
    collect_tick(run, blank_tick(), System.monotonic_time(:millisecond) + 30_000)
  end

  defp collect_tick(run, t, deadline) do
    receive do
      {:load_log, text} ->
        t = %{t | log_bytes: t.log_bytes + byte_size(text), log_lines: t.log_lines + 1}
        {name, f} = fields(text)

        case name do
          "voxel_thermal_kernel" -> collect_tick(run, %{t | kernel: [f | t.kernel]}, deadline)
          "voxel_thermal_sim" -> collect_tick(run, %{t | sim: f}, deadline)
          "voxel_thermal_throttle" -> collect_tick(run, %{t | throttle: f}, deadline)
          "voxel_structure_tick" -> collect_tick(run, %{t | structure: f}, deadline)
          "voxel_structure_sleep" -> collect_tick(run, %{t | sleep: f}, deadline)
          "voxel_structure_triggers" -> collect_tick(run, %{t | triggers: f}, deadline)
          "voxel_thermal_commit" -> collect_tick(run, %{t | commit: f}, deadline)
          "voxel_thermal_callback" -> {%{t | callback: f}, run}
          other -> collect_tick(between(run, other, f), t, deadline)
        end

      {:persist, :append, seq, bytes, rows, meta, thermal?} ->
        collect_tick(run, %{t | appends: [%{seq: seq, bytes: bytes, rows: rows, meta: meta, thermal: thermal?} | t.appends]}, deadline)

      {:persist, :pages, cut, bytes, globals} ->
        collect_tick(pages(run, cut, bytes, globals), t, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {%{t | callback: :timeout}, run}
    end
  end

  # 两拍之间：页切点、积压级别变化、施放产生的追加与日志。
  defp between(run, "voxel_persist_backlog" <> _ = name, f), do: update_in(run.backlog, &[{name, f} | &1])
  defp between(run, "voxel_page_cut", f), do: update_in(run.page_cuts, &[f | &1])
  defp between(run, _name, _f), do: run

  defp pages(run, cut, bytes, globals),
    do: update_in(run.page_bytes, &Map.update(&1, cut, %{rows: bytes, globals: globals}, fn p -> %{rows: p.rows + bytes, globals: p.globals + globals} end))

  # 等到本拍墙钟节奏点，期间吸收两拍之间的消息。
  defp idle_until(run, deadline) do
    receive do
      {:load_log, text} ->
        {name, f} = fields(text)
        run = %{run | idle_log_bytes: run.idle_log_bytes + byte_size(text)}
        idle_until(between(run, name, f), deadline)

      {:persist, :append, _seq, bytes, _rows, _meta, _thermal} ->
        idle_until(%{run | idle_append_bytes: run.idle_append_bytes + bytes, idle_appends: run.idle_appends + 1}, deadline)

      {:persist, :pages, cut, bytes, globals} ->
        idle_until(pages(run, cut, bytes, globals), deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> run
    end
  end

  defp new_run,
    do: %{next_cid: 100_001, station_counter: 0, casters: %{}, pools: %{}, at: 1_000_000, cast_us: [], casts: %{},
      backlog: [], page_cuts: [], page_bytes: %{}, idle_log_bytes: 0, idle_append_bytes: 0, idle_appends: 0, ticks: []}

  defp drive(c, spec, warmup_s, window_s) do
    warmup = round(warmup_s * 1000 / @tick_ms)
    total = warmup + round(window_s * 1000 / @tick_ms)
    :persistent_term.put({MeteredLog, :meter}, self())

    Logger.configure(level: :info)
    :ok = :logger.set_handler_config(:default, :level, :warning)
    :ok = :logger.add_handler(:magic_load, Capture, %{level: :info, config: %{pid: self()}})

    try do
      # 规则结构（寿命长于整个运行）一次建成，出生在第 0 拍之前。
      run = top_up(c, new_run(), %{spec | scorch: 0, total: 0} |> Map.put(:probe, 0), 0, false)
      run = Enum.reduce(0..(total - 1), run, fn tick, run -> one_tick(c, run, spec, tick, tick < warmup) end)
      {run, warmup}
    after
      :logger.remove_handler(:magic_load)
      :logger.set_handler_config(:default, :level, :all)
      Logger.configure(level: :warning)
      :persistent_term.erase({MeteredLog, :meter})
    end
  end

  defp one_tick(c, run, spec, tick, warmup?) do
    started = System.monotonic_time(:millisecond)
    before = length(run.cast_us)
    run = top_up(c, run, spec, tick, warmup?)
    topped = System.monotonic_time(:millisecond)
    n = census(c, run)
    Agent.update(c.clock, &(&1 + @tick_ms * 1000))
    # 补施产生的追加与日志已在邮箱里：投递热提交前先吸收进“两拍之间”，不混进本拍。
    run = idle_until(run, System.monotonic_time(:millisecond))
    sent = System.monotonic_time(:millisecond)
    {t, run} = commit_tick(c, run)
    done = System.monotonic_time(:millisecond)

    record = Map.merge(t, %{tick: tick, warmup: warmup?, census: Map.drop(n, [:per_caster]), top_up_ms: topped - started,
      casts: length(run.cast_us) - before,
      idle: %{append_bytes: run.idle_append_bytes, appends: run.idle_appends, log_bytes: run.idle_log_bytes},
      lag_ms: max(sent - (run[:next_due] || sent), 0), commit_wall_ms: done - sent})

    run = idle_until(%{run | ticks: [record | run.ticks]}, started + @tick_ms)
    Map.put(run, :next_due, started + @tick_ms)
  end

  # ---------------------------------------------------------------------------
  # 汇总与判定
  # ---------------------------------------------------------------------------

  defp pct([], _p), do: nil

  defp pct(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))
  end

  defp dist(values), do: %{p50: pct(values, 0.5), p95: pct(values, 0.95), max: Enum.max(values, fn -> nil end),
    mean: if(values == [], do: nil, else: Float.round(Enum.sum(values) / length(values), 1))}

  defp get(f, key), do: (f && Map.get(f, key)) || 0

  # 一拍里各次内核调用的“每 50 ms 段子步数”（T15 的口径）。
  defp steps50(t),
    do: for(k <- t.kernel, get(k, "simulated_s") > 0, do: get(k, "kernel_steps") / (get(k, "simulated_s") / 0.05))

  # 热事务元数据行抽样解码：`thermal.structures`（显式字段 map）单独压缩后的字节，估算其在每拍持久化里的份额。
  defp structures_share(ticks) do
    samples =
      for t <- Enum.take_every(ticks, 20), a <- t.appends, a.thermal and a.meta != nil do
        meta = OverlayLog.term(a.meta)
        structures = get_in(meta, [:thermal, :structures]) || %{}
        bare = put_in(meta, [:thermal, :structures], %{})
        %{meta_bytes: byte_size(a.meta), structures: map_size(structures),
          structures_bytes: byte_size(:erlang.term_to_binary(structures, [{:compressed, 1}])),
          rest_bytes: byte_size(:erlang.term_to_binary(bare, [{:compressed, 1}])),
          property_rows: length(Map.get(meta, :property_states, []))}
      end

    per = for s <- samples, s.structures > 0, do: s.structures_bytes / s.structures
    %{samples: length(samples), meta_bytes: dist(Enum.map(samples, & &1.meta_bytes)),
      structures_bytes: dist(Enum.map(samples, & &1.structures_bytes)), rest_bytes: dist(Enum.map(samples, & &1.rest_bytes)),
      property_rows: dist(Enum.map(samples, & &1.property_rows)),
      bytes_per_structure: if(per == [], do: nil, else: Float.round(Enum.sum(per) / length(per), 1))}
  end

  defp summarize(name, c, run, warmup, spec) do
    all = Enum.reverse(run.ticks)
    window = Enum.drop(all, warmup)
    done = Enum.filter(window, &is_map(&1.callback))

    callback = Enum.map(done, &get(&1.callback, "elapsed_us"))
    structure = Enum.map(done, &get(&1.structure, "elapsed_us"))
    step_total = Enum.map(done, &get(&1.structure, "step_us_total"))
    step_max = Enum.map(done, &get(&1.structure, "step_us_max"))
    structures = Enum.map(done, &get(&1.structure, "structures"))
    kernel_calls = Enum.flat_map(done, & &1.kernel)
    nif_tick = Enum.map(done, fn t -> Enum.sum(Enum.map(t.kernel, &get(&1, "nif_us"))) end)
    steps_tick = Enum.map(done, &get(&1.throttle, "kernel_steps"))

    steps_per_50ms = Enum.flat_map(done, &steps50/1)
    # L8-2：反例结构在拍首端口温度 ≥ 1500 K 的拍（刚出生、最热）与其余拍分开。
    {probe_hot, probe_cool} = Enum.split_with(done, &((&1.census.probe_k || 0.0) >= 1500.0))

    probe_split = fn ticks ->
      %{ticks: length(ticks), steps_per_50ms: dist(Enum.flat_map(ticks, &steps50/1)),
        kernel_steps_per_tick: dist(Enum.map(ticks, &get(&1.throttle, "kernel_steps"))),
        nif_us_per_tick: dist(Enum.map(ticks, fn t -> Enum.sum(Enum.map(t.kernel, &get(&1, "nif_us"))) end)),
        clamped_nodes: dist(Enum.map(ticks, &get(&1.throttle, "clamped_nodes"))),
        throttled_nodes: dist(Enum.map(ticks, &get(&1.throttle, "throttled_nodes")))}
    end

    thermal_appends = for t <- done, a <- t.appends, a.thermal, do: a.bytes
    page_cuts = Enum.reverse(run.page_cuts)

    # 两拍之间（补施的施放事务、开户等）的追加与日志：相邻两拍累计计数之差，归到后一拍。
    idle =
      all
      |> Enum.chunk_every(2, 1, :discard)
      |> Map.new(fn [a, b] -> {b.tick, Map.new(b.idle, fn {k, v} -> {k, v - a.idle[k]} end)} end)

    window_idle = for t <- window, d = idle[t.tick], d != nil, do: {t, d}

    interval_bytes =
      for {t, d} <- window_idle, is_map(t.callback),
          do: d.append_bytes + Enum.sum(for a <- t.appends, do: a.bytes)
    window_s = length(window) * @tick_ms / 1000

    summary = %{
      scenario: name,
      environment: %{otp: System.otp_release(), elixir: System.version(), schedulers: System.schedulers_online(),
        cpu: cpu(), catalog_digest: Base.encode16(c.digest, case: :lower), content_version: @content_version,
        probe_mass_g: c.programs.probe_mass_g},
      spec: spec,
      window: %{warmup_ticks: warmup, window_ticks: length(window), completed_ticks: length(done), simulated_s: window_s,
        lag_ms: dist(Enum.map(window, & &1.lag_ms)), top_up_ms: dist(Enum.map(window, & &1.top_up_ms))},
      composition: %{
        total: dist(Enum.map(window, & &1.census.total)),
        awake_scorch: dist(Enum.map(window, &Map.get(&1.census.awake, :scorch, 0))),
        awake_probe: dist(Enum.map(window, &Map.get(&1.census.awake, :probe, 0))),
        rules: dist(Enum.map(window, &Map.get(&1.census.kinds, :ember, 0))),
        lamps: dist(Enum.map(window, &Map.get(&1.census.kinds, :lamp, 0))),
        units: dist(Enum.map(window, & &1.census.units)),
        kernel_heat_nodes: dist(Enum.map(done, &get(&1.structure, "awake_nodes"))),
        present: dist(Enum.map(window, & &1.census.present))
      },
      world_tick_us: %{callback: dist(callback), thermal_steps: dist(Enum.map(done, &get(&1.sim, "steps_us"))),
        structure_tick: dist(structure), structure_step_total: dist(step_total), structure_step_max: dist(step_max),
        persist: dist(Enum.map(done, &get(&1.commit, "persist_us"))), broadcast: dist(Enum.map(done, &get(&1.commit, "broadcast_us"))),
        commit_wall_ms: dist(Enum.map(done, & &1.commit_wall_ms))},
      structure_step_mean_us:
        if(Enum.sum(structures) > 0, do: Float.round(Enum.sum(step_total) / Enum.sum(structures), 2), else: nil),
      active_set: %{hot: dist(Enum.map(done, &get(&1.sim, "hot"))), candidates: dist(Enum.map(done, &get(&1.sim, "candidates"))),
        kernel_nodes: dist(Enum.map(kernel_calls, &get(&1, "nodes"))), edges: dist(Enum.map(kernel_calls, &get(&1, "edges")))},
      kernel: %{nif_us_per_tick: dist(nif_tick), nif_us_per_call: dist(Enum.map(kernel_calls, &get(&1, "nif_us"))),
        calls_per_tick: dist(Enum.map(done, &length(&1.kernel))), kernel_steps_per_tick: dist(steps_tick),
        kernel_steps_per_call: dist(Enum.map(kernel_calls, &get(&1, "kernel_steps"))),
        steps_per_50ms: dist(steps_per_50ms),
        throttled_nodes: dist(Enum.map(done, &get(&1.throttle, "throttled_nodes"))),
        clamped_nodes: dist(Enum.map(done, &get(&1.throttle, "clamped_nodes"))),
        probe_k: dist(for(t <- done, t.census.probe_k != nil, do: Float.round(t.census.probe_k, 1))),
        probe_hot: probe_split.(probe_hot), probe_cool: probe_split.(probe_cool)},
      persistence: %{thermal_txn_bytes: dist(thermal_appends), thermal_txn_rows: dist(for(t <- done, a <- t.appends, a.thermal, do: a.rows)),
        structures_share: structures_share(done),
        between_ticks_append_bytes: dist(Enum.map(window_idle, fn {_, d} -> d.append_bytes end)),
        between_ticks_appends: dist(Enum.map(window_idle, fn {_, d} -> d.appends end)),
        per_tick_interval_bytes: dist(interval_bytes),
        page_cuts: length(page_cuts), page_cut_elapsed_us: dist(Enum.map(page_cuts, &get(&1, "elapsed_us"))),
        page_cut_units: dist(Enum.map(page_cuts, &get(&1, "units"))),
        page_cut_bytes: dist(Enum.map(Map.values(run.page_bytes), &(&1.rows + &1.globals))),
        page_globals_bytes: dist(Enum.map(Map.values(run.page_bytes), & &1.globals))},
      logs: %{bytes_per_tick: dist(Enum.map(done, & &1.log_bytes)), lines_per_tick: dist(Enum.map(done, & &1.log_lines)),
        between_ticks_bytes: dist(Enum.map(window_idle, fn {_, d} -> d.log_bytes end))},
      backlog: Enum.reverse(run.backlog) |> Enum.map(fn {n, f} -> Map.put(f, "event", n) end),
      casts: %{by_outcome: Map.new(run.casts, fn {{k, o}, n} -> {"#{k}:#{inspect(o)}", n} end),
        casters: map_size(run.casters), cast_us: dist(run.cast_us),
        total_casts: Enum.sum(for {_, n} <- run.casts, do: n), window_casts: Enum.sum(Enum.map(window, & &1.casts))},
      triggers: Enum.count(done, &(&1.triggers != nil)),
      sleep_ticks: Enum.count(done, &(&1.sleep != nil))
    }

    verdicts = verdicts(summary, spec)
    summary = Map.put(summary, :verdicts, verdicts)
    File.mkdir_p!(c.out)
    path = Path.join(c.out, "#{name}.json")
    File.write!(path, Jason.encode!(json(summary), pretty: true))
    report(name, summary, path)
    summary
  end

  defp cpu do
    case File.read("/proc/cpuinfo") do
      {:ok, text} -> text |> String.split("\n") |> Enum.find_value(&(String.starts_with?(&1, "model name") && String.trim(List.last(String.split(&1, ":")))))
      _ -> nil
    end
  end

  # JSON 化：元组与原子转字符串。
  defp json(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), json(v)} end)
  defp json(l) when is_list(l), do: Enum.map(l, &json/1)
  defp json(t) when is_tuple(t), do: inspect(t)
  defp json(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  defp json(v), do: v

  defp verdicts(s, spec) do
    awake_target = spec.scorch + Map.get(spec, :probe, 0)

    probe =
      if Map.get(spec, :probe, 0) > 0,
        do: [{:probe_observed, s.kernel.probe_hot.ticks > 0, "窗口内反例端口温度 ≥ 1500 K 的拍 #{s.kernel.probe_hot.ticks} 个"}],
        else: []

    ([
      {:window_complete, s.window.completed_ticks == s.window.window_ticks,
        "#{s.window.completed_ticks}/#{s.window.window_ticks} 拍完成"},
      {:composition, s.composition.kernel_heat_nodes.p50 >= awake_target and s.composition.rules.p50 == spec.ember and
         (spec.total == :fill or s.composition.total.p50 >= spec.total),
        "热节点 p50 #{s.composition.kernel_heat_nodes.p50}/#{awake_target}，规则 p50 #{s.composition.rules.p50}，结构 p50 #{s.composition.total.p50}"},
      {:world_tick_p95, s.world_tick_us.callback.p95 <= @budget.tick_us, "每拍 World 时间 p95 #{s.world_tick_us.callback.p95} µs ≤ 500 ms"},
      {:structure_step_mean, s.structure_step_mean_us <= @budget.step_mean_us, "结构步进平均 #{s.structure_step_mean_us} µs ≤ 30"},
      {:structure_step_max, s.world_tick_us.structure_step_max.max <= @budget.step_max_us,
        "单结构单拍最坏 #{s.world_tick_us.structure_step_max.max} µs ≤ 100"},
      {:region_step, s.world_tick_us.structure_step_total.max <= @budget.region_step_us,
        "每分区每拍结构步进最坏 #{s.world_tick_us.structure_step_total.max} µs ≤ 26 ms"},
      {:persist_16kb, s.persistence.thermal_txn_bytes.p95 <= @budget.persist_bytes,
        "热事务持久化 p95 #{s.persistence.thermal_txn_bytes.p95} B ≤ 16384"},
      {:backlog, s.backlog == [], "积压分级变化 #{length(s.backlog)} 次"},
      {:t15_steps, (s.kernel.steps_per_50ms.max || 0) <= @budget.steps_per_50ms,
        "每 50 ms 段内核子步最多 #{s.kernel.steps_per_50ms.max} ≤ 2"}
    ] ++ probe)
    |> Enum.map(fn {k, ok, detail} -> %{check: k, pass: ok, detail: detail} end)
  end

  defp report(name, s, path) do
    IO.puts("""
    MAGIC_LOAD #{name} window=#{s.window.simulated_s}s ticks=#{s.window.completed_ticks}/#{s.window.window_ticks} json=#{path}
      composition #{inspect(s.composition)}
      world_tick_us #{inspect(s.world_tick_us)} step_mean_us=#{s.structure_step_mean_us}
      active_set #{inspect(s.active_set)}
      kernel #{inspect(s.kernel)}
      persistence #{inspect(s.persistence)}
      logs #{inspect(s.logs)} backlog=#{inspect(s.backlog)}
      casts #{inspect(s.casts)} lag_ms=#{inspect(s.window.lag_ms)}
    """)

    for v <- s.verdicts, do: IO.puts("  VERDICT #{name} #{v.check} #{if v.pass, do: "PASS", else: "FAIL"} #{v.detail}")
  end

  defp assert_verdicts(summary) do
    failed = for v <- summary.verdicts, not v.pass, do: "#{v.check}: #{v.detail}"
    assert failed == [], "未通过的判定：\n" <> Enum.join(failed, "\n")
  end

  defp seconds(env, default), do: String.to_integer(System.get_env(env, Integer.to_string(default)))

  # ---------------------------------------------------------------------------
  # 用例
  # ---------------------------------------------------------------------------

  test "L8-1 档 a（设计原数，probe B = 512）：256 结构 / 16 醒着热节点 / 64 规则，持久化开启", c do
    c = start_world(c, %{"region_budget_units" => 512})
    spec = %{scorch: 16, ember: 64, total: 256}
    {run, warmup} = drive(c, spec, seconds("LOAD_WARMUP_S", 60), seconds("LOAD_WINDOW_S", 240))
    summary = summarize("tier_a", c, run, warmup, spec)
    assert_verdicts(summary)
  end

  test "L8-1 档 b（发布目录，正常准入上限）：16 醒着热节点 + 64 规则，其余灯填到准入拒绝", c do
    c = start_world(c, %{})
    spec = %{scorch: 16, ember: 64, total: :fill}
    {run, warmup} = drive(c, spec, seconds("LOAD_WARMUP_S", 60), seconds("LOAD_WINDOW_S", 240))
    summary = summarize("tier_b", c, run, warmup, spec)
    assert_verdicts(summary)
  end

  test "L8-2 反例（发布目录）：档 b 组成中 1 个热节点换成最小合法热容、2500 K 的结构", c do
    c = start_world(c, %{})
    assert c.programs.probe_mass_g == 82
    assert_in_delta c.programs.quotes.probe.c_th_j_per_k, 41.0, 1.0e-9
    spec = %{scorch: 15, probe: 1, ember: 64, total: :fill}
    {run, warmup} = drive(c, spec, seconds("LOAD_WARMUP_S", 60), seconds("LOAD_L82_WINDOW_S", 120))
    summary = summarize("l8_2", c, run, warmup, spec)
    assert_verdicts(summary)
  end
end
