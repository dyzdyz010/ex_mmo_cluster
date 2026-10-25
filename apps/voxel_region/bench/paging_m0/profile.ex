defmodule VoxelRegion.Bench.M0Profile do
  @moduledoc """
  只测试（Test-only）：M1 定位用的 World 函数级剖析。经 `Code.compile_file/1` 编译进运行节点，只发一次。

  `run(out, cell, n, type)`：只对 World 进程开 `call_time`（自身墙钟 µs）或 `call_memory`（自身分配字数）计量，
  经作者入口 `apply_edits` 在 `cell` 交替放石 / 挖空 n 笔（与 M0 编辑者同一入口），把按计量值排序的前 200 个函数写成 JSON。
  直接用 `:erlang.trace_pattern/3`（`:tprof` 在 tools 应用里，节点代码路径没有）。剖析期间 World 变慢属预期，结论只用于排序。
  """

  alias VoxelRegion.World

  def run(out, {x, y, z} = cell, n, type \\ :call_time) do
    world = Process.whereis(World)
    pattern = {:_, :_, :_}
    # 只开计数器（同 tprof）：不得带 :local / :global——那会让 World 每次调用都给调用方发一条追踪消息，
    # 2026-10-25 首次剖析因此堆满消息、吃光开发机内存。call_time / call_memory 本身已计入本地调用。
    :erlang.trace_pattern(:on_load, true, [type])
    :erlang.trace_pattern(pattern, true, [type])
    :erlang.trace(world, true, [:call])
    t0 = System.monotonic_time(:microsecond)

    seqs =
      for i <- 1..n do
        {:ok, seq} = World.apply_edits(World, [{cell, if(rem(i, 2) == 1, do: 11, else: 0)}])
        seq
      end

    wall = System.monotonic_time(:microsecond) - t0
    :erlang.trace(world, false, [:call])
    rows = collect(type)
    :erlang.trace_pattern(:on_load, false, [type])
    :erlang.trace_pattern(pattern, false, [type])

    total = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    top =
      rows
      |> Enum.sort_by(&(-elem(&1, 2)))
      |> Enum.take(200)
      |> Enum.map(fn {{m, f, a}, calls, value} ->
        %{mfa: "#{inspect(m)}.#{f}/#{a}", calls: calls, value: value, percent: Float.round(100 * value / max(total, 1), 2)}
      end)

    File.write!(out, Jason.encode!(%{type: type, cell: [x, y, z], edits: n, seqs: seqs, wall_us: wall, total: total, top: top}, pretty: true))
    Jason.encode!(%{wall_us: wall, total: total, top15: Enum.take(top, 15)})
  end

  # 逐个已加载函数读计量（与 tprof collect 同法）：call_time 每进程 {pid, 次数, 秒, 微秒}，call_memory {pid, 次数, 字数}。
  defp collect(type) do
    for {m, _} <- :code.all_loaded(), {f, a} <- functions(m),
        {^type, [_ | _] = per} <- [:erlang.trace_info({m, f, a}, type)] do
      {calls, value} =
        Enum.reduce(per, {0, 0}, fn
          {_pid, c, s, us}, {cc, vv} -> {cc + c, vv + s * 1_000_000 + us}
          {_pid, c, words}, {cc, vv} -> {cc + c, vv + words}
        end)

      {{m, f, a}, calls, value}
    end
  end

  defp functions(m) do
    m.module_info(:functions)
  rescue
    _ -> []
  end
end
