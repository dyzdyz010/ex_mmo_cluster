defmodule VoxelRegion.Bench.M0Load do
  @moduledoc """
  只测试（Test-only）：区域分页 M0 的负载驱动。经 `Code.compile_file/1` 编译进运行节点，只发一次。

  一个“活跃窗口” = 一个订阅者 + 一个编辑者：
  - 长期订阅者先以自身 PID 经 `World.set_simulation_windows/2` 登记完整 XYZ 盒，收到回执后再走
    `World.canonical_snapshot_and_subscribe/5`（含碰撞 chunk），记录快照耗时 / 字节与每笔 `canonical_delta` 的到达时刻与字节。
    普通 canonical 订阅本身不授予模拟资格；窗口外扩由 World 负责，不在夹具里重复计算。
  - 编辑者走作者入口 `World.apply_edits/2`，在窗口中心柱地表上方一格交替放石 / 挖空（世界不随时间增长，只有世代递增），
    记录每笔调用的墙钟延迟与返回 seq。它覆盖 World 几何提交尾部（规约、后像、日志、扇出），不覆盖玩家工具会话、
    限速与扣料（那些在 Player / Tools 路径），结论只适用于提交尾部。

  `start/1` 幂等（注册名 `:m0_load`）；`report/0` 返回 JSON 汇总，快照行包含窗口的模拟来源 PID。
  `stop/0` 请求结束全部窗口；订阅者在 stop／截止时间退出，World 收到 DOWN 后同时退休订阅与模拟资格。
  """

  alias VoxelRegion.{CollisionStream, World}

  @name :m0_load
  @table :m0_load_rows

  # spec: %{windows: [%{id, x, z}], interval_ms, radius, duration_s, material}
  def start(spec) do
    case Process.whereis(@name) do
      nil ->
        caller = self()
        pid = spawn(fn -> init(caller, spec) end)

        receive do
          {:m0_load_started, ^pid, windows} -> Jason.encode!(%{started: inspect(pid), windows: windows})
        after
          600_000 -> raise "m0 load did not start"
        end

      pid ->
        Jason.encode!(%{already_running: inspect(pid)})
    end
  end

  def stop do
    case Process.whereis(@name) do
      nil -> Jason.encode!(%{running: false})
      pid -> send(pid, :stop) && Jason.encode!(%{stopping: inspect(pid)})
    end
  end

  # 地表：从 top 向下按 step 粗扫，再在命中段内逐格细扫，返回首个非空气格之上的空气格 y。
  def surface(x, z, top \\ 586, bottom \\ -200) do
    coarse = for y <- top..bottom//-8, do: {x, y, z}
    hit = first_solid(coarse)
    fine = for y <- min(hit + 8, top)..hit//-1, do: {x, y, z}
    first_solid(fine) + 1
  end

  defp first_solid(cells) do
    %{probe_occupancy: rows} = World.material_snapshot(World, [], cells)
    %{cell: [_, y, _]} = Enum.find(rows, &(&1.material != 0 or &1.refined))
    y
  end

  def report do
    rows = if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)
    commits = for {{:commit, w, seq}, t0, t1} <- rows, do: {w, seq, t0, t1}
    deltas = for {{:delta, w, seq}, t, bytes} <- rows, do: {w, seq, t, bytes}
    snaps = for {{:snapshot, w}, v} <- rows, do: Map.put(v, :window, w)
    errors = for {{:error, w, n}, v} <- rows, do: %{window: w, n: n, error: v}

    lat = commits |> Enum.map(fn {_, _, t0, t1} -> t1 - t0 end) |> Enum.sort()
    commit_start = Map.new(commits, fn {_, seq, t0, _} -> {seq, t0} end)

    fanout =
      deltas
      |> Enum.flat_map(fn {_, seq, t, _} ->
        case commit_start do
          %{^seq => t0} -> [t - t0]
          _ -> []
        end
      end)
      |> Enum.sort()

    {first, last} =
      case commits do
        [] -> {0, 0}
        _ -> {Enum.min(Enum.map(commits, &elem(&1, 2))), Enum.max(Enum.map(commits, &elem(&1, 3)))}
      end

    per_window =
      commits
      |> Enum.group_by(&elem(&1, 0), fn {_, seq, t0, t1} -> {seq, t1 - t0} end)
      |> Map.new(fn {w, rows} ->
        {w, %{commit_us: pcts(rows |> Enum.map(&elem(&1, 1)) |> Enum.sort()), seqs: Enum.map(rows, &elem(&1, 0))}}
      end)

    Jason.encode!(%{
      per_window: per_window,
      commits: length(commits),
      span_s: Float.round((last - first) / 1_000_000, 1),
      commit_us: pcts(lat),
      delta_after_commit_start_us: pcts(fanout),
      deltas: length(deltas),
      delta_bytes: Enum.sum(Enum.map(deltas, &elem(&1, 3))),
      snapshots: snaps,
      errors: Enum.take(errors, 20),
      error_count: length(errors)
    })
  end

  defp pcts([]), do: nil

  defp pcts(sorted) do
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, floor(q * n))) end
    %{n: n, p50: at.(0.5), p95: at.(0.95), p99: at.(0.99), max: List.last(sorted),
      mean: div(Enum.sum(sorted), n)}
  end

  # ---- 进程 ----

  defp init(caller, spec) do
    Process.register(self(), @name)
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    radius = Map.get(spec, :radius, 1)

    windows =
      for w <- spec.windows do
        y = surface(w.x, w.z)
        cell = {w.x, y, w.z}
        box = CollisionStream.box({w.x + 0.5, y + 0.5, w.z + 0.5}, radius)
        %{id: w.id, cell: cell, box: box}
      end

    activity = if Map.get(spec, :activity, false), do: Enum.map(windows, &activity/1), else: []
    activity = if Map.get(spec, :circuit, false), do: activity ++ Enum.map(windows, &circuit/1), else: activity
    subs = for w <- windows, do: spawn_link(fn -> subscriber(w) end)
    # 等全部窗口快照到达再开始编辑，快照阶段与稳态编辑分开计量。
    for _ <- subs, do: receive(do: ({:m0_snapshot_ready, _id} -> :ok))

    deadline = System.monotonic_time(:millisecond) + Map.get(spec, :duration_s, 600) * 1000
    interval = Map.get(spec, :interval_ms, 1000)
    material = Map.get(spec, :material, 11)
    n = length(windows)

    editors =
      for {w, i} <- Enum.with_index(windows) do
        # 相位错开，避免所有窗口同一毫秒提交。
        phase = div(interval * i, max(n, 1))
        spawn_link(fn -> editor(w, interval, phase, deadline, material) end)
      end

    send(caller, {:m0_load_started, self(),
                  %{windows: Enum.map(windows, &%{id: &1.id, cell: Tuple.to_list(&1.cell), box: inspect(&1.box)}),
                    activity: activity}})
    Process.flag(:trap_exit, true)
    wait(subs ++ editors, deadline)
  end

  # 到截止时间结束全部窗口，但本进程（ETS 表 owner）留到 stop，供 report 读取。
  defp wait(children, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      :stop -> shutdown(children)
      {:EXIT, _pid, :normal} -> wait(children, deadline)
      {:EXIT, pid, reason} -> :ets.insert(@table, {{:error, :exit, inspect(pid)}, inspect(reason)}); wait(children, deadline)
    after
      left + 2_000 ->
        shutdown(children)
        receive do: (:stop -> :ok)
    end
  end

  # 模拟活动夹具（每窗口一次，经只测试作者入口）：编辑格东侧约 12 m 处 3×2×3 的水（离 2 m 时会流到编辑格上，作者入口拒绝改写液体格）（液体实验入口，随后在地表流散），
  # 水下地表一个有限热源（热实验入口，20 kW、10 GJ，测量期内不耗尽）。
  # 同一节点进程内每窗口只装一次（逐级加压时窗口 1..n 复用，已装的跳过）。
  defp activity(%{cell: {x, y, z}} = w) do
    dir = Path.join(System.tmp_dir!(), "m0-activity-#{System.pid()}")
    File.mkdir_p!(dir)
    basin = Path.join(dir, "basin-#{w.id}.json")
    if File.exists?(basin), do: %{window: w.id, already: true}, else: install_activity(w, dir, basin, {x + 12, z, y})
  end

  defp install_activity(w, dir, basin, {fx, fz, yref}) do
    {x, y, z} = spot({fx, fz}, for(dx <- 0..2, dz <- -1..1, do: {dx, dz}), 2, yref)
    deposits = for dx <- 0..2, dy <- 0..1, dz <- -1..1, do: %{macro: [x + dx, y + dy, z + dz], material: 21}
    File.write!(basin, Jason.encode!(%{deposits: deposits}))
    {:ok, liquid_seq} = World.liquid_experiment(World, basin)
    hot = ground(x + 1, y, z)
    :ok = heat_source(dir, "heat-#{w.id}", hot, 20_000.0)
    %{window: w.id, liquid_seq: liquid_seq, water_cells: length(deposits), basin: [x, y, z], heat_source: hot}
  end

  # 电路夹具（每窗口一次，经作者入口 apply_edits + 热实验入口）：circuit_test“手算例 1”的 8 格环，立在编辑格西侧的
  # x-y 平面上，底排在三列最高地表上（坡地时可悬空）：热铜 H — 热电石 T — 冷铜 C 在顶排，C 下接电阻合金（灯）再经铜回到 H。
  # H 上一个有限热源（200 kW、10 GJ；10 kW 时 60 s 内温差不够、低于 1 W 零功率判据被断流）把 T 的热端烧热，
  # 冷端靠环境散热，热电动势驱动环路电流，每个热步都要求解电路。
  defp circuit(%{cell: {x, y, z}} = w) do
    dir = Path.join(System.tmp_dir!(), "m0-activity-#{System.pid()}")
    File.mkdir_p!(dir)
    marker = Path.join(dir, "circuit-#{w.id}.json")
    if File.exists?(marker), do: %{window: w.id, circuit_already: true}, else: install_circuit(w, dir, marker, {x - 14, z - 4, y})
  end

  defp install_circuit(w, dir, marker, {fx, fz, yref}) do
    {cu, te, alloy} = {24, 43, 40}
    {x, y, z} = spot({fx, fz}, for(dx <- 0..2, do: {dx, 0}), 3, yref)
    loop = [{{x, y + 2, z}, cu}, {{x + 1, y + 2, z}, te}, {{x + 2, y + 2, z}, cu}, {{x + 2, y + 1, z}, alloy},
            {{x + 2, y, z}, cu}, {{x + 1, y, z}, cu}, {{x, y, z}, cu}, {{x, y + 1, z}, cu}]
    {:ok, seq} = World.apply_edits(World, loop)
    :ok = heat_source(dir, "circuit-heat-#{w.id}", [x, y + 2, z], 200_000.0)
    File.write!(marker, Jason.encode!(%{seq: seq}))
    %{window: w.id, circuit_seq: seq, loop: Enum.map(loop, fn {c, m} -> [Tuple.to_list(c), m] end)}
  end

  # 夹具只落在纯宏格空气上（液体实验拒绝微格；如园中央与普通地形的植被都有微格）：从 from 起按 4 m 网格由近及远
  # 螺旋试位置；y 取占地各列地表的最高值（坡地上夹具可悬空，水随后下落），占地 × 高度内全部是无微格的空气才取。
  # 每个位置只向 World 取一次：占地各列在参考高度 ±24 m 的竖条（活动开始后 World 被液体提交占满，逐格探测会排队超时）。
  defp spot({x0, z0}, columns, height, yref) do
    offsets = for r <- 0..8, dx <- -r..r, dz <- -r..r, max(abs(dx), abs(dz)) == r, do: {4 * dx, 4 * dz}
    ys = (yref + 24)..(yref - 24)//-1

    Enum.find_value(offsets, fn {ox, oz} ->
      {x, z} = {x0 + ox, z0 + oz}
      strips = for {dx, dz} <- columns, do: {x + dx, z + dz}
      %{probe_occupancy: rows} = World.material_snapshot(World, [], for({cx, cz} <- strips, y <- ys, do: {cx, y, cz}))
      cols = rows |> Enum.chunk_every(Enum.count(ys)) |> Enum.zip(strips)
      tops = for {strip, _} <- cols, do: Enum.find(strip, &(&1.material != 0 or &1.refined))

      with true <- Enum.all?(tops),
           y = tops |> Enum.map(fn %{cell: [_, cy, _]} -> cy + 1 end) |> Enum.max(),
           true <- y + height - 1 <= yref + 24,
           true <- Enum.all?(cols, fn {strip, _} ->
             strip |> Enum.filter(fn %{cell: [_, cy, _]} -> cy >= y and cy < y + height end)
             |> Enum.all?(&(&1.material == 0 and not &1.refined))
           end) do
        {x, y, z}
      else
        _ -> nil
      end
    end) || raise "no clear macro spot near #{inspect({x0, z0})}"
  end

  # 热源要宏格实体目标：从 y − 1 往下找第一个无微格的非空气格。
  defp ground(x, y, z) do
    cells = for dy <- 1..12, do: {x, y - dy, z}
    %{probe_occupancy: rows} = World.material_snapshot(World, [], cells)
    %{cell: cell} = Enum.find(rows, &(&1.material != 0 and not &1.refined))
    cell
  end

  defp heat_source(dir, name, macro, power) do
    env = Application.fetch_env!(:voxel_region, :thermal_environment_path) |> File.read!() |> Jason.decode!()
    path = Path.join(dir, "#{name}.json")

    File.write!(path, Jason.encode!(
      Map.merge(Map.take(env, ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin emissivity view_range_cells)),
        %{classification: "Test-only", source_macro: macro, power_w: power, energy_j: 1.0e10})))

    World.thermal_experiment(World, path)
  end

  @doc "电路能量累计（热状态里的 circuit_* 键）；在 World 进程内取值，不复制整份状态。活动负载下 World 排队，等待上限放宽到 120 s。"
  def circuit_totals do
    me = self()
    :sys.replace_state(World, fn s ->
      send(me, {:m0_circuit, s.thermal && Map.take(s.thermal, [:circuit_thermoelectric_j, :circuit_light_j,
        :circuit_peltier_absorbed_j, :circuit_peltier_released_j, :active])})
      s
    end, 120_000)
    receive do: ({:m0_circuit, v} -> Jason.encode!(v || %{}))
  end

  defp shutdown(children), do: Enum.each(children, &Process.exit(&1, :shutdown))

  defp subscriber(w) do
    ref = make_ref()
    me = self()
    # 同一长期来源先取得资格再准备快照；登记不计入原有快照耗时，退出后由 World monitor 退休。
    :ok = World.set_simulation_windows(World, [w.box])
    t0 = System.monotonic_time(:microsecond)
    # 与 Scene 一样由调用方进程做 prepare，再由 World 原子发快照并登记订阅。
    :ok = call_subscribe(w.box, me, ref)

    receive do
      {:canonical_snapshot, ^ref, snap} ->
        t1 = System.monotonic_time(:microsecond)

        :ets.insert(@table, {{:snapshot, w.id},
          %{us: t1 - t0, bytes: :erlang.external_size(snap), seq: snap.transaction_seq,
            regions: length(snap.regions), simulation_source: inspect(me)}})

        send(Process.whereis(@name), {:m0_snapshot_ready, w.id})
        deltas(w)
    after
      600_000 -> raise "snapshot timeout"
    end
  end

  defp call_subscribe(box, pid, ref) do
    case World.canonical_snapshot_and_subscribe(World, box, pid, ref, true) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> raise "subscribe failed: #{inspect(other)}"
    end
  end

  defp deltas(w) do
    receive do
      {:canonical_delta, delta} ->
        :ets.insert(@table, {{:delta, w.id, delta.transaction_seq}, System.monotonic_time(:microsecond),
                             :erlang.external_size(delta)})
        deltas(w)

      _other ->
        deltas(w)
    end
  end

  defp editor(w, interval, phase, deadline, material) do
    Process.sleep(phase)
    edit_loop(w, interval, deadline, material, 0)
  end

  defp edit_loop(w, interval, deadline, material, n) do
    if System.monotonic_time(:millisecond) < deadline do
      next = System.monotonic_time(:millisecond) + interval
      value = if rem(n, 2) == 0, do: material, else: 0
      t0 = System.monotonic_time(:microsecond)

      case World.apply_edits(World, [{w.cell, value}]) do
        {:ok, seq} -> :ets.insert(@table, {{:commit, w.id, seq}, t0, System.monotonic_time(:microsecond)})
        other -> :ets.insert(@table, {{:error, w.id, n}, inspect(other)})
      end

      Process.sleep(max(next - System.monotonic_time(:millisecond), 0))
      edit_loop(w, interval, deadline, material, n + 1)
    end
  end
end
