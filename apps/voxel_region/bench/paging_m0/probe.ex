defmodule VoxelRegion.Bench.M0Probe do
  @moduledoc """
  只测试（Test-only）：区域分页 M0 的节点内采样器。经 `Code.compile_file/1` 编译进运行节点，只发一次。

  - `start/2`：幂等启动注册名 `:m0_probe` 采样进程（已存在则直接返回），到截止时间自行退出并撤销全部钩子。
    每秒一行 JSON：节点 `erlang:memory`、World 堆 / mailbox / GC 计数、调度器利用率、run queue、进程数。
  - World 回合：`:sys.install` 调试钩子记录每条消息从 `in` 到 `out` / `noreply` 的墙钟时长，按消息类别汇总直方图与最长回合。
  - GC / 调度停顿：`:erlang.system_monitor` 的 long_gc（≥20 ms）与 long_schedule（≥50 ms）事件逐条写盘。
  - PG：`DataService.Repo` 的 telemetry 查询事件，按表汇总 queue / query 时长直方图（池等待 = queue_time）。
  - `snapshot/0` 返回当前汇总（JSON 文本）；`stop/0` 立即撤销钩子。
  采样只读进程元信息，不复制 World 状态；字段级堆拆分另用 `field_heap/0` 在 World 进程内按需执行一次。
  """

  @name :m0_probe
  @table :m0_probe_hist
  @telemetry_id "m0-probe-repo"

  def start(out_dir, opts \\ []) do
    case Process.whereis(@name) do
      nil ->
        caller = self()
        pid = spawn(fn -> init(caller, out_dir, opts) end)
        receive do
          {:m0_probe_started, ^pid} -> Jason.encode!(%{started: inspect(pid), out_dir: out_dir})
        after
          10_000 -> raise "m0 probe did not start"
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

  # 当前汇总：回合直方图、PG 直方图（从 ETS 读，不打扰 World）。
  def snapshot do
    Jason.encode!(summary())
  end

  # 清零直方图，开始一个新的测量窗口。
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    Jason.encode!(%{reset: System.system_time(:millisecond)})
  end

  # 在 World 进程内按字段计算 flat_size（字），沿用 10-23 heap_probe 的做法；只在少数时点调用。
  def field_heap(world \\ VoxelRegion.World) do
    me = self()

    :sys.replace_state(
      world,
      fn s ->
        words = :erlang.system_info(:wordsize)

        fields =
          s
          |> Map.delete(:__struct__)
          |> Enum.map(fn {k, v} -> {k, Float.round(:erts_debug.flat_size(v) * words / 1_048_576, 1)} end)
          |> Enum.sort_by(&elem(&1, 1), :desc)
          |> Enum.take(25)

        info = Process.info(self(), [:total_heap_size, :heap_size, :memory])

        send(me, {:m0_field_heap,
         %{
           seq: s.seq,
           top_fields_mb: Map.new(fields),
           total_heap_mb: Float.round(info[:total_heap_size] * words / 1_048_576, 1),
           process_memory_mb: Float.round(info[:memory] / 1_048_576, 1),
           refined_macros: map_size(s.refined),
           instances: map_size(s.instances),
           epochs: map_size(s.epochs),
           damage: map_size(s.damage),
           snapshots: MapSet.size(s.snapshots),
           payloads: map_size(s.payloads),
           entries: map_size(s.entries)
         }})

        s
      end,
      600_000
    )

    receive do
      {:m0_field_heap, value} -> Jason.encode!(value)
    after
      600_000 -> raise "field heap timeout"
    end
  end

  # ---- 采样进程 ----

  defp init(caller, out_dir, opts) do
    Process.register(self(), @name)
    File.mkdir_p!(out_dir)
    interval = Keyword.get(opts, :interval_ms, 1000)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :duration_s, 3600) * 1000
    world = Process.whereis(VoxelRegion.World)

    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    :undefined = :erlang.system_monitor()
    :erlang.system_monitor(self(), [{:long_gc, 20}, {:long_schedule, 50}])
    :ok = :sys.install(world, {&turn_hook/3, nil})

    :telemetry.attach(@telemetry_id, [:data_service, :repo, :query], &__MODULE__.repo_event/4, nil)

    samples = File.open!(Path.join(out_dir, "samples.jsonl"), [:append, :utf8])
    events = File.open!(Path.join(out_dir, "events.jsonl"), [:append, :utf8])
    send(caller, {:m0_probe_started, self()})
    Process.send_after(self(), :tick, interval)

    loop(%{
      world: world,
      samples: samples,
      events: events,
      interval: interval,
      deadline: deadline,
      sched: :scheduler.sample_all(),
      out_dir: out_dir
    })
  end

  defp loop(st) do
    receive do
      :tick ->
        st = tick(st)

        if System.monotonic_time(:millisecond) >= st.deadline do
          finish(st)
        else
          Process.send_after(self(), :tick, st.interval)
          loop(st)
        end

      :stop ->
        finish(st)

      {:monitor, pid, kind, info} ->
        line = %{
          utc_ms: System.system_time(:millisecond),
          kind: kind,
          pid: inspect(pid),
          name: name_of(pid),
          info: Map.new(info, fn {k, v} -> {k, inspect_term(v)} end)
        }

        IO.write(st.events, Jason.encode!(line) <> "\n")
        loop(st)
    end
  end

  defp tick(st) do
    now = :scheduler.sample_all()
    util = :scheduler.utilization(st.sched, now)

    {total_sched, weighted} =
      Enum.reduce(util, {nil, []}, fn
        {:total, v, _}, {_, w} -> {v, w}
        {:weighted, v, _}, {t, w} -> {t, [{:weighted, v} | w]}
        {:normal, id, v, _}, {t, w} -> {t, [{"n#{id}", v} | w]}
        {:cpu, id, v, _}, {t, w} -> {t, [{"c#{id}", v} | w]}
        {:io, id, v, _}, {t, w} -> {t, [{"io#{id}", v} | w]}
        _, acc -> acc
      end)

    world =
      case Process.info(st.world, [
             :total_heap_size,
             :heap_size,
             :memory,
             :message_queue_len,
             :reductions,
             :garbage_collection
           ]) do
        nil ->
          nil

        info ->
          words = :erlang.system_info(:wordsize)

          %{
            heap_mb: Float.round(info[:total_heap_size] * words / 1_048_576, 1),
            young_mb: Float.round(info[:heap_size] * words / 1_048_576, 1),
            memory_mb: Float.round(info[:memory] / 1_048_576, 1),
            mailbox: info[:message_queue_len],
            reductions: info[:reductions],
            minor_gcs: info[:garbage_collection][:minor_gcs]
          }
      end

    mem = :erlang.memory()

    line = %{
      utc_ms: System.system_time(:millisecond),
      memory_mb: Map.new(mem, fn {k, v} -> {k, Float.round(v / 1_048_576, 1)} end),
      world: world,
      sched_total: total_sched,
      sched: Map.new(weighted),
      run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      processes: :erlang.system_info(:process_count)
    }

    IO.write(st.samples, Jason.encode!(line) <> "\n")
    %{st | sched: now}
  end

  defp finish(st) do
    :erlang.system_monitor(:undefined)
    :sys.no_debug(st.world)
    :telemetry.detach(@telemetry_id)
    File.write!(Path.join(st.out_dir, "summary-final.json"), Jason.encode!(summary()))
    File.close(st.samples)
    File.close(st.events)
    :ok
  end

  # ---- World 回合钩子（在 World 进程内执行，只做计时与 ETS 计数）----

  # 计时起点放在 World 进程字典里，不依赖调试函数状态在 in → out 之间的传递（实测 gen_server 回复阶段拿不到 in 阶段的新状态）。
  @doc false
  def turn_hook(fs, {:in, msg}, _proc), do: begin_turn(fs, msg)
  def turn_hook(fs, {:in, msg, _from}, _proc), do: begin_turn(fs, msg)

  def turn_hook(fs, event, _proc) when elem(event, 0) in [:out, :noreply] do
    case Process.delete(:m0_turn) do
      {t0, k} -> record(k, System.monotonic_time(:microsecond) - t0)
      nil -> :ok
    end

    fs
  end

  def turn_hook(fs, _event, _proc), do: fs

  defp begin_turn(fs, msg) do
    Process.put(:m0_turn, {System.monotonic_time(:microsecond), kind(msg)})
    fs
  end

  defp kind({:"$gen_call", _from, req}), do: "call:" <> tag(req)
  defp kind({:"$gen_cast", req}), do: "cast:" <> tag(req)
  defp kind(msg), do: "info:" <> tag(msg)

  defp tag(t) when is_atom(t), do: Atom.to_string(t)
  defp tag(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)), do: Atom.to_string(elem(t, 0))
  defp tag(_), do: "other"

  defp record(k, us) do
    bucket = bucket(us)
    :ets.update_counter(@table, {:turn, k, bucket}, 1, {{:turn, k, bucket}, 0})
    :ets.update_counter(@table, {:turn_sum, k}, us, {{:turn_sum, k}, 0})
    :ets.update_counter(@table, {:turn_n, k}, 1, {{:turn_n, k}, 0})

    case :ets.lookup(@table, {:turn_max, k}) do
      [{_, max, _}] when max >= us -> :ok
      _ -> :ets.insert(@table, {{:turn_max, k}, us, System.system_time(:millisecond)})
    end
  end

  @doc false
  def repo_event(_event, measurements, metadata, _config) do
    source = to_string(metadata[:source] || "other")

    for {key, native} <- [queue: measurements[:queue_time], query: measurements[:query_time]], native != nil do
      us = System.convert_time_unit(native, :native, :microsecond)
      b = bucket(us)
      :ets.update_counter(@table, {:pg, source, key, b}, 1, {{:pg, source, key, b}, 0})
      :ets.update_counter(@table, {:pg_sum, source, key}, us, {{:pg_sum, source, key}, 0})
    end

    :ets.update_counter(@table, {:pg_n, source}, 1, {{:pg_n, source}, 0})
  end

  # 对数桶：上界 2^n 微秒。
  defp bucket(us) when us <= 1, do: 1
  defp bucket(us), do: Integer.pow(2, ceil(:math.log2(us)))

  defp summary do
    rows = if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)

    turns =
      for {{:turn_n, k}, n} <- rows, into: %{} do
        hist = for({{:turn, ^k, b}, c} <- rows, do: {b, c}) |> Enum.sort()
        [{_, max, at}] = for {{:turn_max, ^k}, m, a} <- rows, do: {k, m, a}
        sum = Enum.find_value(rows, fn {{:turn_sum, ^k}, s} -> s; _ -> nil end)
        {k, %{n: n, sum_us: sum, max_us: max, max_at_ms: at, p50_le_us: pct(hist, n, 0.5),
              p95_le_us: pct(hist, n, 0.95), p99_le_us: pct(hist, n, 0.99), hist: Map.new(hist)}}
      end

    pg =
      for {{:pg_n, source}, n} <- rows, into: %{} do
        by =
          for key <- [:queue, :query], into: %{} do
            hist = for({{:pg, ^source, ^key, b}, c} <- rows, do: {b, c}) |> Enum.sort()
            sum = Enum.find_value(rows, 0, fn {{:pg_sum, ^source, ^key}, s} -> s; _ -> nil end)
            c = Enum.sum(Enum.map(hist, &elem(&1, 1)))
            {key, %{sum_us: sum, p50_le_us: pct(hist, c, 0.5), p99_le_us: pct(hist, c, 0.99), hist: Map.new(hist)}}
          end

        {source, Map.put(by, :n, n)}
      end

    %{utc_ms: System.system_time(:millisecond), turns: turns, pg: pg}
  end

  defp pct([], _n, _q), do: nil

  defp pct(hist, n, q) do
    target = q * n

    Enum.reduce_while(hist, 0, fn {b, c}, acc ->
      if acc + c >= target, do: {:halt, b}, else: {:cont, acc + c}
    end)
  end

  defp name_of(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> Atom.to_string(name)
      _ -> nil
    end
  end

  defp inspect_term(v) when is_integer(v) or is_binary(v) or is_atom(v), do: v
  defp inspect_term(v), do: inspect(v, limit: 20)
end
