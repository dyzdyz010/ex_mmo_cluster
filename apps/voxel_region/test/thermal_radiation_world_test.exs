defmodule VoxelRegion.ThermalRadiationWorldTest do
  @moduledoc "只测试：辐射换热经真实 World 热提交链路；场景由作者编辑入口与 Test-only 热源实验一次建立。"
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Log}

  @source {2, 2, 2}
  @ambient 293.15

  # 只测试：5³ 石壳（内腔 3³）或空旷场景，热源浮在内腔中心，均为同一材质。
  defp shell do
    for x <- 0..4, y <- 0..4, z <- 0..4, not (x in 1..3 and y in 1..3 and z in 1..3), do: {x, y, z}
  end

  defp start(c, name, emissivity, cells, energy, source \\ @source) do
    root = Path.join(c.root, name)
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    materials = for id <- 0..23 do
      base = %{material_id: id, max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0), defense: 2.0,
        tags: [], responses: [%{action: "damage", multiplier: 1.0}]}
      if id == 19,
        do: Map.merge(base, %{heat_capacity_per_macro: 1000.0, thermal_conductivity: 10.0,
          heat_resistance_kelvin: 1.0e5}),
        else: base
    end
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}], materials: materials,
      tools: [], definitions: []}))
    environment = Path.join(root, "environment.json")
    File.write!(environment, Jason.encode!(%{ambient_kelvin: @ambient, environment_w_per_m2_k: 10.0,
      tolerance_kelvin: 1.0, emissivity: emissivity, view_range_cells: 8}))
    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(),
      property_catalog_path: catalog, thermal_environment_path: environment, name: nil,
      production_materials: [19]]}, id: name)
    {:ok, _} = World.apply_edits(w, Enum.map([source | cells], &{&1, 19}))
    experiment = Path.join(root, "thermal.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: Tuple.to_list(source),
      ambient_kelvin: @ambient, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0,
      emissivity: emissivity, view_range_cells: 8, power_w: 20_000.0, energy_j: energy}))
    :ok = World.thermal_experiment(w, experiment)
    w
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [], {{-1, -1, -1}, {6, 6, 6}})

  # 计时器与手动提交都按整 0.5 s 推进；按已模拟时长记录每个被观察到的提交后状态。
  defp run(w, until, trace \\ %{}) do
    send(w, :thermal_commit)
    s = observe(w)
    trace = Map.put(trace, s.thermal.elapsed_s, s)
    if s.thermal.elapsed_s >= until, do: trace, else: run(w, until, trace)
  end

  defp temperature(s, cell) do
    micro = cell |> Tuple.to_list() |> Enum.map(&(&1 * 8)) |> List.to_tuple()
    Enum.find_value(s.damage, @ambient, fn {_, t} -> t.micro == micro and Map.get(t, :temperature_kelvin) end)
  end

  defp digest(s) do
    rows = s.damage |> Enum.map(fn {key, t} -> {key, t.temperature_kelvin, t.hp} end) |> Enum.sort()
    :crypto.hash(:sha256, :erlang.term_to_binary({rows, s.thermal.supplied_j, s.thermal.environment_j}))
    |> Base.encode16(case: :lower)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "radiation_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # 只测试：引入辐射前的主线（79dde382）在同一场景逐提交记录的状态摘要（行温度/HP + 供能/环境账）。
  @recorded %{
    0.5 => "92441978c789688bfc0840524eb01772d93595e77c8eca2ba7e9e983c6eaec18",
    1.0 => "382b01fcf3bc85f9cc8604a8733465792a91415425ab2b16a97687ea23c70104",
    1.5 => "ab2fb686215d1831130e9cf857fb89100b9237b60d975fe3acec9dda92900d82",
    2.0 => "cfb01a337941df744263d278b3a9c3c9cf1c42e5dcece29d48f6a23a19c1dd6a",
    2.5 => "d7d9675b69c0090a3d76e7b28621a2cacc1c9065ce6d80bbc50300f15b3d0c32",
    3.0 => "86b705402648693fc80157e055ddca09f84e3436bd06d104d1b0c682f4e0c240",
    3.5 => "2d85da602c180a229ab0151b51402da3b0f282ed88d7a406316158cbb9338480",
    4.0 => "2fa01a53e38b51d464b701d5cb9089beaaed3501b99c330c0f9a508961ce18aa",
    4.5 => "b61e88be7985a92c41ab32748642599d19170bb5ce353ca21f74605c258a419a",
    5.0 => "c659ccd0065b7a1079e7921c03793246c521575d90f8c4622516672e75ab8aef",
    5.5 => "694ea511fdae11ba4b3bdfc3e9b1d3b05bc72a3286d0b73e32292f3f03553ca7",
    6.0 => "0efce80607872f4424670c306c912fa9f977380074c001459dd755e8097e0d3f",
    6.5 => "04f9490e1b8078d4cd71b9f23164f469dc27e007619607d18367fd9674e81d86",
    7.0 => "16dde9b83eff1d9dbe9976a353d3aff6ff31cd909b71aa94064f1bc92715d955",
    7.5 => "41c8ea9b26128b3e0d1f65e962975a192ca22497086e19f0e4935be44d54a9d9",
    8.0 => "7eef80d227f59c2e7fc6849df91231da6271106bb80f70ff6eecb9846fac1956",
    8.5 => "5b88419113de3bd759522912b7d7e82308fa40228e80a38213d33747d0967e3d",
    9.0 => "b5f29e350ecf3e323a37fc484a88786e9ee20b99966a592a6e4219db598fabd2",
    9.5 => "65664fceb304812024cc47c66ec05ae18cb6d69f7e5c900aa610d64a610b1e7a",
    10.0 => "f0f904f94d763c98412f67635e444f2e108fde282c606808c8b4657ea19e9249",
    10.5 => "4b1ac00aaac5252ec24eec2516614cc03039b5074045e411f4f5c7b05fc75aab",
    11.0 => "b4622a1f4fa2e5aa0ce3e2cec9eae48a7f4ea1bf6a7f59bc5d9bb0feea03ba71",
    11.5 => "328269df1285898ac4c68963fcd3beefd43865b2caf6ffde7d1e7fe248b2d1c7",
    12.0 => "d0a09cee1d32f31d8eff7b6677cdc41ad1e65afb03405bd1f02a846f0a35e5a9",
    12.5 => "c70098cf3ff581907dd60417d498bda5668b9981a169d6f6c16167da2df6b029",
    13.0 => "51163ca389d5cfb910bfd9c1f115d74f4969a60898a7e9908e805b7146c83252",
    13.5 => "6d46d5c2cb71a36ec231f9a20729e795f6d6433d7443dc603d3ef8b32fc73cc3",
    14.0 => "08272e1cafa4b541698c9097c5756ca63026956c399e2196ea40d2a892d3e615",
    14.5 => "4fdbb004fca03739a802ead3a8dd9a29f41e5d98588a0cbfec0056526975d21c",
    15.0 => "99b3d14301495b5c4af54db63d03003290b535146d07fd0389d1c4190ce0ba42",
    15.5 => "056d37363b9f2545ae15d021402620d159a6e7c14cf4632898ec72ee2fcc9e28",
    16.0 => "dd8e4074c75dc71c4013eb4a81305d3dff50561d839f96bd590630a38ed78287",
    16.5 => "1505e0e776f223c19b3ee2f599612e1093aef42e93003cfb8732c731047969fc",
    17.0 => "cf41b0fbf2ae5c02244f477b08b00742e78ea4ed957b588b63064dfc67e218eb",
    17.5 => "b1932ebc1b271b32dddb2bdce2aa9a3279db2da1489cf702f0ae5f0082d2999a",
    18.0 => "49eb0fdcf3651536354616f2f54988ad344fceef3db9bb60d35895f0bb0f15f6",
    18.5 => "acfb5d3d5a0f7e179d43ecbb4484a416dafe7f4b589b080e707202f105beb3bc",
    19.0 => "7a2f7837f58c4577addeefe85fb47f0cd37df2a327e00913856e6a12eaf68d7b",
    19.5 => "f6f9297483ecb442d4cb9b44f77e857454a053b7688ad0e672d152eab693a36b",
    20.0 => "cbe558bc8e9ccff9c1fc8ecfc5343c27652e58f361b70eb61bd70284622ae2e6"
  }

  # 储热 ΣC(T−Ta)（场景全为 1 m³、C=1000 J/K）加编辑移除的热对照累计供能 + 环境账（环境账含对天空辐射）。
  defp ledger(s) do
    stored = for {_, t} <- s.damage, Map.has_key?(t, :temperature_kelvin), reduce: 0.0,
      do: (sum -> sum + 1000.0 * (t.temperature_kelvin - @ambient))
    {s.thermal.supplied_j + s.thermal.environment_j, stored + Map.get(s.thermal, :removed_j, 0.0)}
  end

  @tag :thermal_radiation
  test "发射率为 0 时热提交与引入辐射前的记录逐位相同", c do
    w = start(c, "zero", 0.0, shell(), 1.0e9, {2, 1, 2})
    observed = for {elapsed, s} <- run(w, 20.0), Map.has_key?(@recorded, elapsed), do: {elapsed, digest(s)}
    assert length(observed) >= 30
    for {elapsed, digest} <- observed, do: assert({elapsed, digest} == {elapsed, @recorded[elapsed]})
    assert :sys.get_state(w).thermal_work.sights == %{}
  end

  @tag :thermal_radiation
  test "同一热源在石壳内腔比空旷处更热，两处热账都闭合（对天空辐射记入环境账）", c do
    open = run(start(c, "open", 0.9, [], 1.0e9), 60.0)
    enclosed = run(start(c, "enclosed", 0.9, shell(), 1.0e9), 60.0)
    elapsed = MapSet.intersection(MapSet.new(Map.keys(open)), MapSet.new(Map.keys(enclosed))) |> Enum.max()
    assert elapsed >= 59.0
    t_open = temperature(open[elapsed], @source)
    t_enclosed = temperature(enclosed[elapsed], @source)
    IO.puts("RADIATION_ORDER elapsed=#{elapsed} open=#{t_open} enclosed=#{t_enclosed}")
    # 手算空旷平衡：20 kW = 10×6×(T−Ta) + 0.9σ×6×(T⁴−Ta⁴)，T=451.708 K 时 9 513 W + 10 487 W；
    # 60 s ≈ 10 个时间常数 C/(60+4×0.9σ×6×T³) ≈ 5.8 s。
    assert_in_delta t_open, 451.708, 0.05
    assert t_enclosed > t_open
    for s <- [open[elapsed], enclosed[elapsed]] do
      {accounted, stored} = ledger(s)
      assert s.thermal.environment_j < 0
      assert_in_delta accounted, stored, 1.0e-6 * s.thermal.supplied_j
    end
  end

  @tag :thermal_radiation
  test "视线伙伴入域但不入活动集、不传递扩域；视距内编辑使视线失效；热源结束后全部静止", c do
    w = start(c, "settle", 0.9, shell(), 100_000.0)
    run(w, 0.5)
    work = :sys.get_state(w).thermal_work
    partners = [{2, 2, 0}, {2, 2, 4}, {0, 2, 2}, {4, 2, 2}, {2, 0, 2}, {2, 4, 2}]
    assert Enum.all?(partners, &MapSet.member?(work.cells, &1))
    assert work.hot == MapSet.new([@source])
    # 伙伴自身的六邻域只在它真实升温越过容差后才扩入。
    refute MapSet.member?(work.cells, {1, 2, 0})
    refute Enum.any?(work.sights[@source], &match?({_, :sky, _}, &1))

    {:ok, _} = World.apply_edit(w, {2, 2, 4}, 0)
    assert :sys.get_state(w).thermal_work.sights == %{}
    run(w, 1.0)
    assert {_, :sky, 1.0} = Enum.find(:sys.get_state(w).thermal_work.sights[@source], &match?({_, :sky, _}, &1))

    settled = Enum.reduce_while(1..4000, nil, fn _, _ ->
      send(w, :thermal_commit)
      s = observe(w)
      if s.thermal.active, do: {:cont, s}, else: {:halt, s}
    end)
    refute settled.thermal.active
    assert :sys.get_state(w).thermal_work.hot == MapSet.new()
    {accounted, stored} = ledger(settled)
    assert_in_delta accounted, stored, 1.0e-6
    IO.puts("RADIATION_SETTLE elapsed=#{settled.thermal.elapsed_s} rows=#{map_size(settled.damage)}")
  end
end
