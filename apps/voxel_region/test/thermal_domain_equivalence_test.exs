Code.require_file("support/thermal_reference.exs", __DIR__)

defmodule VoxelRegion.ThermalDomainEquivalenceTest do
  @moduledoc """
  只测试：118 格木屋经真实 World 提交燃烧，增量热域必须保持全量重建的历史参考。
  温度、HP、燃料、燃烧标志与选定热账逐位比较。内核次序按节点键定义（不取 map 遍历次序），结果与 OTP 版本无关，
  故只有一张表：ε0.9 与 ε0 参考均由 2c4038e7 全量重建路径按键序录制（2026-11-07 重录，旧表依赖 OTP 的 map 次序，
  依据见 Saved/Tests/test-audit-20261105/results-thermal-order.md）。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, WorldClock}
  alias VoxelRegion.TestSupport.ThermalReference

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @grass 1
  @wood 19
  @box {{-2, -2, -2}, {10, 8, 10}}

  setup do
    root = Path.join(System.tmp_dir!(), "thermal_equivalence_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    clock = start_supervised!({WorldClock, 10_000})
    %{root: root, clock: clock}
  end

  defp start(c, digest, environment) do
    catalog = Path.join(c.root, "properties.json")
    File.cp!(Path.join(@fixtures, digest <> ".json"), catalog)
    env = Path.join(c.root, "environment.json")
    File.cp!(Path.join(@fixtures, environment), env)
    w = start_supervised!({World, [source: VoxelRegion.TestSupport.Source, log: VoxelRegion.TestSupport.NullLog, root: c.root, observer: self(),
      name: nil, property_catalog_path: catalog, thermal_environment_path: env, production_materials: [15, @wood],
      clock: {WorldClock, c.clock}]})
    {:ok, _} = World.material_supply(w, 1001, "fixture", %{15 => 10_000_000})
    w
  end

  # The fire_furnace_production_test house: 7x4x7, walls and roof one cell thick, door 1x2 and one window.
  defp house do
    for x <- 0..6, y <- 1..4, z <- 0..6, x in [0, 6] or z in [0, 6] or y == 4,
        {x, y, z} not in [{3, 1, 0}, {3, 2, 0}, {6, 2, 3}], do: {{x, y, z}, @wood}
  end

  defp ignite(w) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {6.5, 1.5, -4.0},
      tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
    q = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 0, tool_id: 9, direction: {0.0, 0.0, 1.0},
      micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, t} = World.tool_intent(w, a, q)
    r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material])) |> Map.put(:action, 1)
    {:ok, _} = World.tool_intent(w, Map.merge(a, %{received_us: 1_000_000, clock_node: node()}), r)
  end

  defp digest(s) do
    rows =
      s.damage
      |> Enum.map(fn {key, t} ->
        {key, Map.get(t, :temperature_kelvin), t.hp, Map.get(t, :remaining_fuel_j), Map.get(t, :burning)}
      end)
      |> Enum.sort()

    ledger = Map.take(s.thermal, [:supplied_j, :environment_j, :combustion_j, :combustion_removed_j, :removed_j,
      :discarded_fuel_j, :fuel_initialized_j, :elapsed_s])

    :crypto.hash(:sha256, :erlang.term_to_binary({rows, Enum.sort(ledger)})) |> Base.encode16(case: :lower)
  end

  # 只测试：调度时钟固定，显式提交仍走正式内核；每次公共观察必须对应完成的一笔 0.5 s。
  defp run(w, until, trace \\ %{}, previous \\ 0.5) do
    send(w, :thermal_commit)
    await_step(w, previous + 0.5, System.monotonic_time(:millisecond) + 5_000)
    s = VoxelRegion.TestSupport.observe(w, [], @box)
    assert_in_delta s.thermal.elapsed_s - previous, 0.5, 1.0e-9
    capture_raw(:step, s)
    trace = Map.put(trace, s.thermal.elapsed_s, digest(s))
    if s.thermal.elapsed_s >= until or not s.thermal.active,
      do: trace, else: run(w, until, trace, s.thermal.elapsed_s)
  end

  # 强制提交遇冷页会保留同一thermal_run跨消息完成；只等待这次目标，不补发第二次commit。
  defp await_step(w, target, deadline, waiting \\ false) do
    stats = World.stats(w)
    progress = stats.simulation_progress.thermal
    assert stats.simulation_io.status != :failed, "thermal page IO failed: #{inspect(stats.simulation_io)}"
    assert progress.model_elapsed_s <= target + 1.0e-9,
      "thermal advanced beyond requested step: #{inspect(progress)} target=#{target}"

    if abs(progress.model_elapsed_s - target) <= 1.0e-9 and progress.remaining_s == 0.0 do
      if waiting, do: record_wait(:complete, target, progress, stats.simulation_io)
      :ok
    else
      unless waiting, do: record_wait(:waiting, target, progress, stats.simulation_io)
      assert progress.wait_reason != :rest, "thermal rested before requested step: #{inspect(progress)}"
      assert System.monotonic_time(:millisecond) < deadline,
        "thermal step incomplete: #{inspect(progress)} io=#{inspect(stats.simulation_io)} target=#{target}"
      receive do after 5 -> :ok end
      await_step(w, target, deadline, true)
    end
  end

  defp record_wait(stage, target, progress, io) do
    if path = System.get_env("THERMAL_DOMAIN_CAPTURE") do
      File.write!(path <> ".progress.jsonl", Jason.encode!(%{stage: stage, target: target,
        progress: progress, simulation_io: io}) <> "\n", [:append])
    end
  end

  defp burn(c, digest, environment) do
    w = start(c, digest, environment)
    # 只测试：参考记录点火前已有一次 0.5 s；由公开强制提交建立，不再借用建场耗时触发真实 timer。
    # 独占调度时钟不前进，因此读取和记录 raw 都不会插入额外自然 due；原物理参数及冻结表保持。
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @box)
    {:ok, _} = World.apply_edits(w, (for x <- -1..7, z <- -1..7, do: {{x, 0, z}, @grass}) ++ house())
    send(w, :thermal_commit)
    initial = World.simulation_snapshot(w, [], @box)
    assert initial.thermal_accounting.elapsed_s == 0.5
    capture_raw(:before_ignition, initial)
    ignite(w)
    run(w, 600.0)
  end

  # 只读取证：长度前缀 ETF 保留每笔公开观察；中途失败仍保留已有前缀，不改原摘要投影或 expected。
  defp capture_raw(kind, snapshot) do
    if path = System.get_env("THERMAL_DOMAIN_CAPTURE") do
      bytes = :erlang.term_to_binary({kind, snapshot})
      File.write!(path, <<byte_size(bytes)::unsigned-big-32, bytes::binary>>, [:append])
    end
  end

  defp assert_recorded(trace, recorded, label) do
    for {elapsed, digest} <- Enum.sort(trace), rem(trunc(elapsed * 2), 20) == 0,
      do: IO.puts("THERMAL_DIGEST #{label} #{inspect(elapsed)} #{digest}")
    assert :ok == ThermalReference.compare(trace, recorded)
  end

  # 参考：2c4038e7 全量重建路径按节点键序（ref-sorted）在 OTP 28 与 29 上录制，两版逐点相同；31 点中 160/170 s 两个检查点
  # 取全量路径实际观测到的邻近步（159.99…、170.99…），全量路径在大火阶段只观测部分步。证据：Voxim
  # Saved/Tests/test-audit-20261105/results-thermal-order.md。
  @radiation %{
    10.0 => "d600c5a7ecb73413ab90086009f1ab04bbb84a5573af59e5ea8fde107d8500bd",
    20.0 => "cbdde38d3d66fa83d4302e08463dd1719e6f0ed4f763ef04d2a864a30953fb3f",
    30.000000000000004 => "f7ede5ffedc55b320d3160b1cc7d1d2103b5313ac54b8d7283ce1919c5a90315",
    40.00000000000001 => "4281bdf1a903ba6a114f171f9337f6bb61bbc1d4b097cb7b5b5881987f141749",
    50.000000000000014 => "986efc0ab0369e54e0ccd0bbbe0ba4839af42283928c2240544ee1090f5a818b",
    60.000000000000014 => "c952742635d6f3368e7b82e20d745b0a1a11b312261236846e8e231192abb104",
    70.00000000000001 => "7ec0fdb56429cdb20a287bdc423a612547c08a9d4b1f257a5d52ac623fa856ef",
    80.0 => "f1c0bd6603c8f23bfaf41a0c56364a884754a623402e96011b27779b498f1faf",
    90.49999999999999 => "e53dccbe9f519e54d1267cd52f72f650fa9b181bb6f5fc28126a60aa953ac7b2",
    100.49999999999999 => "366059b2eeb346793843992490782c153b4b66eeeadb2388aeada98f3fdd91e6",
    110.49999999999999 => "3dddbe162b0f7ea2db374fa7177311294b25853126d8c1bf16ab1f6daf42f0a3",
    120.49999999999997 => "655b8564d44697c653ae821588705e8b1b91e3d0434c84ff65f449fd197d88b6",
    130.49999999999991 => "a747dabd877c9b76bb2e845df56ce3c76d86473f17c7a2912fd0d57a16aee9d5",
    140.49999999999991 => "897d5157b2afbd2229d89fdfdfac5f764a55017bf28479ec13fa53e3afba370e",
    150.49999999999991 => "5c6697f0366c4f4d6de69673804cfd35d4b8dc8af813604e6729b7c74119b9b4",
    159.99999999999994 => "3cd5ba9c7b38eb8db6bfac2f6cd38a5d10e522ab17d2c8b3a39457df691150c4",
    170.99999999999997 => "c5c0d03d0340b6a765c068ff40f2079ad6cafe93501c0845c7f5fcf572531593",
    430.0000000000002 => "cf4718bbebe2f7fc6b65eed8607139d4cd97d0e7288ba05634ac11d4514cbdff",
    440.0000000000002 => "99e3823623fb67c209186f4216f05c73aeff38b69e32910a2fabf6169b2bd6c8",
    460.0000000000002 => "3c6c8fd541b400fa3eae45558393808d07b70abad0cb3f1ad8d0e2038ed63e35",
    480.0000000000002 => "327cc748df6963c16461741ba52b3a5452cbb0d54db0eca3fb9b69a34d144f91",
    490.0000000000002 => "e9f6fac8a6cb888a256ceef202f2562f45de1f42adc76ee49b90d3896909e34d",
    510.0000000000002 => "1af236f251131b6c700dded422b5c5994ac7308f3e51668fdf6dec8cd7b8e6ce",
    520.0000000000002 => "782fe20e0aee99cc3675713664dd537a48b9e5385d41fd49ed4e6713f4e30394",
    530.0000000000002 => "d5eb3dd037d553795c376b4c3eb594794d4b60b2a56a6bdbd6bdc35e642060ea",
    540.0000000000002 => "ebb6fe232066f561d062c44e07e238afd80676a0ffb22f822bafc6bbf30390ee",
    550.0000000000002 => "1db86cd65c299efade7800f605c1f15babf50dde14fe1c2ba05230aac37c8d08",
    560.0000000000002 => "2a6cbf69672b81ca709bd95a09a4a1231efa0446f5b27dd22cdb7607808bfc5a",
    580.0000000000002 => "7918e0f21fdc8912a8de7113b3a55be1cc5f2c177b97613cd3b4dfa6c942b380",
    590.0000000000002 => "40cca1971566ff2423fc167becdd38b13e9fe68fa470bb4d2cdf4d8cef8b05c8",
    600.0000000000002 => "2b61e10f75a897a4b458429286280b830209b7847e03fd699a950cae686fcefc"
  }

  @zero %{
    10.000000000000002 => "cf6e4841e6f06b9089c512ec5c2c4b10a72d62e75a8c5f8cec99dd62c5e458c9",
    20.000000000000004 => "d7cfc60a906d5172d83ea7b5c7f8d8b8650cb3e1b5e75c164d4fbe3180df52cd",
    30.000000000000004 => "1c51dd2b0e21da842c75fc406c07d171e1d45eb2786cdeefb9a9af5d8f7b705e",
    40.0 => "f6d7dc4688e85fc46a3bffd8cd2c2162c073b4077ba115b45f49ee1375405a3c",
    50.0 => "801ac88c0728368e8ead7759f04966f77fd2df56184ad635214bdaaaecfbf12c",
    60.0 => "073e5ea2ae249123afd30e4758e5f68160ebc78a7dd97e576ef603e0643cb9db",
    70.0 => "8d509717b1bd84628ccbf8acc8ae1e685a8787da2e268dedeb787e6578802792",
    80.0 => "1f7b8273ba4329e73588b0ef4f06f2d50cf53d2ab59f8f686110dfd543cdda76",
    90.0 => "afb21dab0a6f7db60b6302db53f1e2e18f58755da2403e2cfc4dafe4086593f6",
    100.49999999999999 => "c18b0f2694e75e172d95632e88502abf460b4712640c5ea44a31a0c9353bd865",
    110.49999999999999 => "ad56d4c7d504db1610b4b9342ba1c9cbe2936ca2cc2b383f3d56d0b2c4c71785",
    120.49999999999997 => "2f49c909565a434bcae77e76605837ceead37d54a27af311379426ac2dbee1bc",
    130.49999999999997 => "96f6e43c20f5ae4590d4705982f28a8d095996499b7b356d86190d14e7fee666",
    140.49999999999997 => "1837e596c2a0959e1d2ee761cbda5108a357d39d4768cbb1f804b3a72f72d717",
    150.49999999999997 => "f6a174608b7e0761f12ab2706956d120e0449be27a1230529e565e9659ae4f41",
    160.00000000000014 => "b3b5ae1a851ee535cdbb1cf69760a80bb620269f07de61e7ffd2bf897d6b4327",
    170.0000000000002 => "3680799ee2519619bd1eee68e32c91bb95d6873ec3851597a9c3c7157b866000",
    180.00000000000028 => "036fa6ff3873fde7d75aae0ec22dcd8826d2bcd750e314ece072eca9bd22f2d5",
    190.00000000000028 => "67507f2c3e8f8170770fe3191cfbbfa5d075397282bf1140f64429a918a19798",
    200.0000000000003 => "db1cf591925423910b82d31b86e32499c56e73b90ab22f8f8f1859de3ccec2a6"
  }

  # 慢层（单项 ≥ 45 s）：实测约 58 s（WSL +S 2:2），接近默认 60 s；超时留约 2 倍余量。
  @tag :slow
  @tag timeout: 120_000
  test "radiation catalog, eps 0.9: a burning house matches the full-rebuild digests commit by commit", c do
    trace = burn(c, "5be2e8c79d8789a29aa17e023294c8aafbff51ff4b8c07a945035dbfcf91fe57", "environment-radiation.json")
    assert_recorded(trace, @radiation, :radiation)
  end

  # 慢层（单项 ≥ 45 s）：实测约 56 s（WSL +S 2:2），接近默认 60 s；超时留约 2 倍余量。
  @tag :slow
  @tag timeout: 120_000
  test "earlier catalog, eps 0: a burning house matches the full-rebuild digests commit by commit", c do
    trace = burn(c, "fbd4f30106f1cecbd5ea73cb361b7e19058a531420fbaf86998ad89f43f6ba70", "environment.json")
    assert_recorded(trace, @zero, :zero)
  end
end
