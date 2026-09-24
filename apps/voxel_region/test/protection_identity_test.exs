defmodule VoxelRegion.ProtectionIdentityTest do
  @moduledoc """
  只测试：没有受保护区域时，热（含辐射与燃烧）、液体与冶炼的提交与引入受保护区域前的主线逐位相同。
  电路一项随 R8-04 增量 3 撤下：主线记录用的是已退役的电源设备，现行目录没有可对照的等价场景；受保护区域对电路的
  分域由 protection_world_test 的电路边界用例（蓄能石／热电石回路跨边界）覆盖。

  `@recorded` 由引入前的主线（1b2a10c8）用本文件同一场景逐提交记录：每个值是该时刻行状态与热账的 sha256。
  场景只用主线已有入口（作者编辑、material_supply、四个意图入口、thermal_experiment），目录为已发布 5be2e8c7，
  热环境为 Test-only 辐射环境 ε 0.9。时间键为相对首个动作提交的已模拟秒数；后台 500 ms 定时提交可能跳过个别键，
  只比较两次都观察到的键，并要求足够多。第二组在远处另建一个区域：场景全在野外，物理必须仍与记录相同。
  """
  use ExUnit.Case, async: false
  @moduletag :protection
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @base "5be2e8c79d8789a29aa17e023294c8aafbff51ff4b8c07a945035dbfcf91fe57"
  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @materials [1, 11, 15, 16, 19, 21, 24]

  setup do
    root = Path.join(System.tmp_dir!(), "protection_identity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp start(c, name, opts \\ []) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    File.cp!(Path.join(@fixtures, @base <> ".json"), catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment-radiation.json"), env)
    w = start_supervised!({World, Keyword.merge([source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, production_materials: @materials], opts)}, id: name)
    {:ok, _} = World.material_supply(w, 1001, "fixture", Map.new(@materials, &{&1, 60_000_000}))
    w
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp actor(eye) do
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp stamp(a, seq), do: Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()})
  defp observe(w), do: World.simulation_snapshot(w, [1001], {{-1, -1, -1}, {1, 1, 1}})

  defp digest(s) do
    # 身份字段（纪元、附件 id、构件 owner）取自事务序号，随定时提交与额外作者事务平移；只比物理值与位置。
    rows = s.property_states |> Enum.map(&Map.drop(&1, [:seq, :request_id, :incarnation, :owner])) |> Enum.sort()
    # 冷板撤下（R8-04 增量 2）后电路不再维护冷板的制冷／排热两本账（新世界里不出现这两个键）；比较不含它们。
    ledger = Map.drop(s.thermal_accounting, [:elapsed_s, :active, :circuit_cooling_j, :circuit_rejected_j])
    # R8-04 增量 3：格被移除时按移除格上的储能记移除账；没有蓄能石时该键为 0.0（主线里不出现），不属于物理值。
    ledger = if Map.get(ledger, :circuit_removed_j) == 0.0, do: Map.delete(ledger, :circuit_removed_j), else: ledger
    # 原子键 map 的内部次序随原子表而变，编码必须用 deterministic。
    :crypto.hash(:sha256, :erlang.term_to_binary({rows, ledger, Enum.sort(s.liquid_quantities)}, [:deterministic]))
    |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # 每次手动提交后按相对模拟时刻记录摘要，直到 until 秒。
  defp trace(w, t0, until, acc \\ %{}) do
    send(w, :thermal_commit)
    s = observe(w)
    t = s.thermal_accounting.elapsed_s - t0
    acc = Map.put(acc, t, digest(s))
    if t >= until, do: acc, else: trace(w, t0, until, acc)
  end

  # 时间原点取动作事务自身记录的模拟时刻，不受其前后插入的定时提交影响。
  defp elapsed_at(w, seq), do: hd(World.entries_after(w, seq - 1)).thermal.elapsed_s

  defp far(w, true), do: {:ok, _} = apply(World, :author_regions, [w, [%{holder: :reserved, min: {5000, 5000}, max: {5100, 5100}}]])
  defp far(_w, false), do: :ok

  defp fire(c, name, far?) do
    w = start(c, name)
    far(w, far?)
    {:ok, _} = World.apply_edits(w, (for x <- 0..5, z <- 0..4, do: {{x, 0, z}, 1}) ++ [{{2, 1, 2}, 19}, {{3, 1, 2}, 19}])
    a = actor({2.5, 3.5, 2.5})
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 9, direction: {0.0, -1.0, 0.0},
      micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
    {:ok, t} = World.tool_intent(w, a, q)
    r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material]))
    {:ok, lit} = World.tool_intent(w, stamp(a, seq), %{r | action: 1})
    trace(w, elapsed_at(w, lit), 80.0)
  end

  defp liquid(c, name, far?) do
    w = start(c, name, liquid_bounds: {{14, 0, -2}, {28, 4, 3}})
    far(w, far?)
    channel = for x <- 16..26, do: [{{x, 0, 0}, 11}, {{x, 1, -1}, 11}, {{x, 1, 1}, 11}]
    {:ok, _} = World.apply_edits(w, List.flatten(channel) ++ [{{15, 1, 0}, 11}, {{27, 1, 0}, 11}])
    a = actor({20.5, 3.5, 0.5})
    seq = next()
    {:ok, _} = World.production_intent(w, stamp(a, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1,
      action: 3, material: 21, tool_id: 12, coord: {20, 1, 0}})
    Enum.reduce_while(1..10_000, nil, fn _, _ ->
      send(w, :liquid_commit)
      if World.liquid_activity(w).active_cells == 0, do: {:halt, :ok}, else: {:cont, nil}
    end)
    %{settled: Enum.sort(observe(w).liquid_quantities)}
  end

  defp ore(c, name, far?) do
    w = start(c, name)
    far(w, far?)
    {:ok, _} = World.apply_edits(w, [{{20, 5, 0}, 16}, {{21, 5, 0}, 15}])
    path = Path.join(c.root, "heat_#{name}.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [20, 5, 0], ambient_kelvin: 293.15,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8,
      power_w: 1.0e6, energy_j: 2.6e7}))
    :ok = World.thermal_experiment(w, path)
    # 实验入口以新热账开始，模拟时刻从 0 计。
    trace(w, 0.0, 40.0)
  end

  # 主线 1b2a10c8 上以本文件场景运行两次得到的同一记录（记录用的临时测试随后删除）。
  @recorded %{
    fire: %{46.0 => "194e3b9635d2db66", 23.0 => "170df3f933bbd4b0", 20.5 => "3ae4fe0fedcc8ddb", 11.0 => "4647ac1659522e4d", 36.5 => "1404f63359b3d930", 20.0 => "b4bbc0a2adfe750e", 25.5 => "7a0253f9d71aa39b", 74.5 => "566d59cafb0879a3", 56.0 => "325d144938413c32", 80.0 => "f9bad4195b4dc0a6", 37.0 => "a8ec3ae201c5c7ce", 3.5 => "c8295655a9c97403", 7.0 => "01b7ea432c4187d6", 64.5 => "16f266bbbd55639f", 14.0 => "05ac4fd3278b30c9", 63.5 => "6559bc29b23d12a6", 31.5 => "e0241092ebf31dc9", 9.5 => "23462335f34196c0", 8.5 => "bacbef0d886fedbc", 43.5 => "74a7cbf488586c93", 13.5 => "7c46149dbc9745e3", 1.0 => "28dc3d6727b209ff", 53.0 => "f83427c8329c756f", 46.5 => "e147545aab08938f", 49.0 => "3ac8f78fd218c466", 47.0 => "9b6f6bca918a7db0", 70.5 => "6e8db7a87e61dfbe", 67.5 => "b65987e796326e4b", 77.5 => "3f556b9f2618e24a", 32.0 => "5c5048a43aa3fce9", 75.5 => "6f70de9bdb04cf11", 45.5 => "c6ac38826ff1a628", 54.5 => "322dfecdeab8f522", 66.5 => "5bd9dbf0139a8350", 30.0 => "6ec424f8a84f3c20", 28.5 => "2aeffb7ceabdd0ba", 10.0 => "0a4016e5bd207c41", 72.0 => "b70e051a0fb08746", 29.5 => "0f74703b427e99e3", 36.0 => "2e1e69f787736f3d", 57.0 => "f79af535bce83056", 67.0 => "a2d60cfc89155074", 75.0 => "f9ef6d3890e3943d", 3.0 => "cd821799795c1259", 71.5 => "8bc30a6a41c990a0", 69.0 => "edce4be9ced5de8c", 40.5 => "99b2dee4528a20c5", 52.0 => "ce0c7bbc3f4f398d", 6.5 => "684bdc05ddc62cda", 5.5 => "ee120096d9281bc1", 70.0 => "30a541aaaafc9166", 44.0 => "5c773269ef62b126", 27.0 => "d8f827a90a6335aa", 24.0 => "f907e54f8fd908c2", 65.5 => "5d0801954afdc503", 73.0 => "293a13c882d8bc67", 43.0 => "65de6518be7bf72b", 56.5 => "d6b0356283a5ce84", 48.5 => "1d335680bfca3b0c", 41.0 => "dba96edd7d1ebd95", 23.5 => "5d2f85ead374241d", 17.5 => "8b7294f044135194", 62.5 => "2dec26216f3cae63", 35.0 => "d8a1079b81b0abc0", 18.5 => "0129548e64c046b6", 76.0 => "60c544e7ed6f4a5d", 78.0 => "09bbf8f059e87739", 61.5 => "1b2c353707433053", 10.5 => "87c342a10327303d", 1.5 => "c1efe8eac2ca431a", 22.0 => "de6cb99f064e8785", 11.5 => "4ad161ab14a8ebc8", 68.0 => "813a86d2d2331c96", 72.5 => "ff67057ecec92933", 7.5 => "a1a453ef23a300e6", 15.5 => "975b3ea9117ecf3d", 27.5 => "0a6a9747afaa7e81", 15.0 => "990168134583e172", 38.0 => "e7cf5fed49e4cd6c", 2.0 => "ad5e41c2c794d13e", 19.5 => "a7e1c8dfe678138e", 76.5 => "9f8e84e31a3b5c34", 39.5 => "bd0ffed0d1265553", 53.5 => "8476e21bd9f633c0", 31.0 => "9c53222127df71f3", 5.0 => "63401855d2ce2b1f", 62.0 => "0926414eacb3369d", 74.0 => "d7a6fd8551fb5289", 78.5 => "82da9de838e179bb", 30.5 => "17c0b2d1fefacafa", 50.0 => "2718e4f4fdb64d79", 32.5 => "c91ec73023048527", 68.5 => "4465fc1aa342d416", 65.0 => "a346557f094c0726", 42.5 => "ee1a5fe8763eb602", 64.0 => "a04306831ae8b9d1", 28.0 => "8b308612f63065c3", 79.0 => "82fc2ac9bfef0727", 24.5 => "8849395a21b07eca", 33.0 => "b7b42517f8827d5b", 79.5 => "9103ec4a2322ca91", 25.0 => "317e450136fd12e2", 0.5 => "2e3436142450abfe", 26.0 => "6eb551a44c32cb88", 47.5 => "675c2640e2839698", 8.0 => "1fbb230af1804e32", 69.5 => "2e2c64b59f844c21", 6.0 => "be9d60d2b3c34564", 66.0 => "8c7617230f8ad951", 29.0 => "b3c307f2db3d6547", 17.0 => "a0bd57278c1e3875", 19.0 => "11fb99483ca7277e", 55.0 => "99a4b65fa33fba14", 60.0 => "52cefcbe597fb5fb", 16.5 => "62e55239ad67fe21", 37.5 => "b9c8fc686b06c0c9", 59.5 => "11d6f5d7c4436494", 77.0 => "83dc040f3d18a86c", 51.5 => "5295d06f9fe1ba4b", 40.0 => "60791d3fa76640c3", 33.5 => "188d4681624d82cc", 61.0 => "231a66c85d735054", 54.0 => "911a4d3bd7cf82dd", 45.0 => "ac5ecf258b029504", 12.0 => "eaf228b87474bf44", 63.0 => "58c5f806f38d2575", 58.0 => "6ec731e09d94a700", 14.5 => "51c8a83d70ed021d", 51.0 => "ad8cec7d1cd43368", 16.0 => "0016d917835be745", 4.5 => "e70ccf25731415ab", 34.5 => "9cbaf2808a76e4bc", 52.5 => "4b54e582d37481c1", 12.5 => "5b5d0e72fa20f6f6", 48.0 => "ce8418c39417f44a", 26.5 => "f566ddac49c50837", 73.5 => "fbaa9705e2b0d1e7", 44.5 => "ea341ce8fa316af9", 42.0 => "22db7e053d3d5920", 13.0 => "e680a243329d8368", 21.0 => "1ecde2e253a9092d", 39.0 => "1b6e44bbf6a3ae84", 38.5 => "4500dfdd293f370f", 57.5 => "0b4f44504ef1e275", 21.5 => "e06c2d8cd3fee959", 55.5 => "892975cbd0ad1d56", 35.5 => "2677be236d5ead60", 34.0 => "75e36debd82a98f7", 41.5 => "1af8066d18359a47", 9.0 => "2240204d0d9d2e6e", 58.5 => "2b20aea5b4b8b565", 18.0 => "9166c548a11e461c", 2.5 => "ee0c603e4fff08e8", 60.5 => "82e72a14999456c7", 50.5 => "2f33da0d225aade1", 59.0 => "232f65b78e081d8a", 4.0 => "2852a71702960dd1", 22.5 => "054b341b8321bfa0", 49.5 => "c8b8e23414457225", 71.0 => "560651cddc6e22c4"},
    liquid: %{settled: [{{19, 1, 0}, 87379}, {{20, 1, 0}, 349530}, {{21, 1, 0}, 87379}]},
    ore: %{23.0 => "737c3c8d5c45f6f5", 20.5 => "cb3a605dc5aaeb10", 11.0 => "a95a18b4fc55691f", 36.5 => "f6da61d13fe3d931", 20.0 => "0cf32d32704c3aa2", 25.5 => "3f425c51fbe021d6", 37.0 => "8be63516682eda4b", 3.5 => "1f3904d052367d58", 7.0 => "b5913c0e94fac037", 14.0 => "8a4f1705876e36c0", 31.5 => "0b9cf70f57e48aac", 9.5 => "98f571d4ccbf4d9f", 8.5 => "abae5a30bdb1ff3b", 13.5 => "1ad7a55e090af3af", 1.0 => "35bac5427f93d144", 32.0 => "69b4c5b335e09f41", 30.0 => "38acdc7a39acbb7d", 28.5 => "71d482d91e50957e", 10.0 => "f7c6e4df228199d9", 29.5 => "462de5f74a637d62", 36.0 => "248a599700b353bd", 3.0 => "0346b71e7b1efdc8", 6.5 => "d4c0fbbf4ad0beab", 5.5 => "2e4fcd1d2da7c081", 27.0 => "4345772ca85180a4", 24.0 => "94eef5d21343e07a", 23.5 => "10708b811e466edb", 17.5 => "5b27707a61712f59", 35.0 => "ac49e8bfb1a01b6e", 18.5 => "4a92adcde9bbd0a9", 10.5 => "43b6770d2be82d6b", 1.5 => "d56ee84c77eade65", 22.0 => "67ad69e269654bb3", 11.5 => "3fca7457ea7fdc46", 7.5 => "ac43035fec6b863c", 15.5 => "049bc83e96e56359", 27.5 => "9f1756f99a2c18db", 15.0 => "b8bfca6aff6445b8", 38.0 => "3ba8e3b66482acc2", 2.0 => "1d5bfaa12c656c2f", 19.5 => "268649d8b9581d43", 39.5 => "a83a2ae9dd871b13", 31.0 => "089d4ee572deab49", 5.0 => "1ae617eb4a4a71ba", 30.5 => "f2f6a5dce43b0707", 32.5 => "21c832885df712be", 28.0 => "cedeb259ef5d8776", 24.5 => "81f6fe6530a594c8", 33.0 => "75c58c49cf78f5bc", 25.0 => "08a7268c2927cee2", 0.5 => "73227752e9dccbd3", 26.0 => "51767794154db31b", 8.0 => "2c942b1ecb38444a", 6.0 => "86813b06a9f8b7fe", 29.0 => "dc38b9a69957f6fe", 17.0 => "5c922be891590650", 19.0 => "14fe38bd0d79add9", 16.5 => "7737470c1ad9f002", 37.5 => "af2a9579cc7a8e5a", 40.0 => "de18c87049d4ba0c", 33.5 => "3461131f5b2315d1", 12.0 => "3b73cfb5f0984cb0", 14.5 => "cc00bba9269002db", 16.0 => "5686d9f438c8bfa9", 4.5 => "887ed60f2df10b3b", 34.5 => "a5518df10070d014", 12.5 => "bc2bc307a907cc5d", 26.5 => "8d9739d4e5da76e1", 13.0 => "b231d2b48538ae9c", 21.0 => "ec09d648754153a1", 39.0 => "8c295ae8b74c0a3b", 38.5 => "3545e3335d398ade", 21.5 => "ff9d18a7e6a10eb7", 35.5 => "623d547205fbbd0d", 34.0 => "1f581f0611857ea1", 9.0 => "5024db1b20f4c65d", 18.0 => "47fb80c5f750c89d", 2.5 => "17546cb0c8fd2957", 4.0 => "f1eaae34dcdd8e4d", 22.5 => "3df7adc5d38ab477"}
  }

  for {scenario, far?} <- [fire: false, liquid: false, ore: false, fire: true, liquid: true, ore: true] do
    @tag :identity
    test "#{scenario}#{if far?, do: "（远处另有区域）", else: ""} 与主线记录逐位相同", c do
      started = System.monotonic_time(:microsecond)
      observed = apply(__MODULE__, :run, [unquote(scenario), c, :"#{unquote(scenario)}_#{unquote(far?)}", unquote(far?)])
      IO.puts("PROTECTION_PERF #{unquote(scenario)} far=#{unquote(far?)} wall_us=#{System.monotonic_time(:microsecond) - started}")
      recorded = Map.fetch!(@recorded, unquote(scenario))
      common = for {k, v} <- observed, Map.has_key?(recorded, k), do: {k, v}
      assert length(common) >= min(10, map_size(recorded))
      for {k, v} <- common, do: assert({k, v} == {k, recorded[k]})
    end
  end

  def run(:fire, c, name, far?), do: fire(c, name, far?)
  def run(:liquid, c, name, far?), do: liquid(c, name, far?)
  def run(:ore, c, name, far?), do: ore(c, name, far?)
end
