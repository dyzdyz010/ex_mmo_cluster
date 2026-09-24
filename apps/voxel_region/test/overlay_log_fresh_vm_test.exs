defmodule VoxelRegion.OverlayLogFreshVmTest do
  @moduledoc """
  只测试：日志元数据在一个全新 VM 里解码（冷重启就是这样）。回放用 `binary_to_term(_, [:safe])`，原子必须已在原子表里；
  测试 VM 早已加载全部模块，看不出惰性加载的模块里才有的原子。这里把一笔带拟态记录的施法事务元数据写成与日志相同的
  ETF 字节，另起一个只挂 ebin 路径、不启动应用的 `elixir` 进程，像 World 启动回放那样加载 World 后调用 `VoxelRegion.OverlayLog.term/1`。
  回归：magic-inc2 首次双端实跑（Voxim semblance-01）冷重启时 World 在 replay_log 里 `binary_to_term` 抛 ArgumentError 起不来。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.Semblance

  test "带拟态记录的事务元数据在全新 VM 里可解码" do
    catalog = %{semblance: %{specific_heat: 500.0, conductivity: 400.0}}
    form = %{"shape" => 0.0, "radius_m" => 0.4, "mass_kg" => 2.0, "temperature_k" => 2000.0, "glow_w" => 0.0, "lifetime_s" => 60.0}
    contact = %{target: %{micro: {584, 3424, -4192}, granularity: 0}, key: {73, 428, -525}, cell: {73, 428, -525}}

    launch = %{origin: {71.9, 426.8, -525.4}, velocity: {9.0, 7.3, 3.0}, t0_us: 1_790_000_000_000_000, flight_s: 0.19,
      rest: {73.6, 427.6, -524.8}, contact: contact}

    s = Semblance.new(1001, form, catalog, launch)
    metadata = %{caster_energy: %{1001 => 76_731.4}, thermal: %{semblances: %{{2229, 0} => s}, semblance_created_j: 1_706_994.0}}
    path = Path.join(System.tmp_dir!(), "overlay-fresh-vm-#{System.unique_integer([:positive])}.etf")
    File.write!(path, :erlang.term_to_binary(metadata, [{:compressed, 1}]))
    on_exit(fn -> File.rm(path) end)

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    # 与冷重启相同：回放的调用方 World 已加载（它的字面量原子已在原子表里），其余模块按需惰性加载。
    code = ~s|{:module, _} = Code.ensure_loaded(VoxelRegion.World); | <>
      ~s|IO.write(inspect(VoxelRegion.OverlayLog.term(File.read!(#{inspect(path)})) == :erlang.binary_to_term(File.read!(#{inspect(path)}))))|

    # binary_to_term 不带 :safe 在新 VM 里会自己建原子，只用来得到期望值；被测的是带 :safe 的 term/1。
    assert {"true", 0} = System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end
end
