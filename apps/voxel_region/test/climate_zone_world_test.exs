defmodule VoxelRegion.ClimateZoneWorldTest do
  @moduledoc """
  只测试：热环境“气候区”（低于 0 °C 的冷源，Voxim Docs/Magic.md §6）经真实 World 入口。

  气候区 = 大气边界（无限热库，与全局 ambient 同性质）：区内未记录格默认温度、相变天然温度、空气换热、对天辐射与
  静止判据都取区温；区边界是热分区边界（与受保护区域同为理想绝热镜面）——导热、辐射视线都不跨。

  目录 `b1aca503…`（石 11：C 21360 J/K、k 25；冰 20：C 1.93 MJ/K、转变 273.15 K、潜热 334 MJ）。地形是天然地形
  （NaturalSource，世界生成替身；未记录 = 静止），热脉冲只经 Test-only `thermal_experiment`（有限源），
  时间只经 `:thermal_commit` 推进。期望来自手算集总模型、目录算术与账目恒等式；“无气候区逐位不变”的哈希取自
  引入气候区之前的 master d6695e86 对同一场景的实跑（冻结样本）。
  """
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.{Damage, World}
  alias VoxelRegion.TestSupport.{Actor, Log}

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @wood 19
  @ice 20
  @warm 293.15
  @cold 248.15
  @stone_c 21_360.0
  @ice_c 1_930_000.0
  @box {{0, 0, 0}, {40, 16, 40}}

  defmodule NaturalSource do
    @moduledoc "Test-only：世界生成替身，区域 {0,0,0} 的天然地形来自 root/natural.term（宏格 => 材质），其余为空气。"
    @extent 66
    def open(opts), do: {:ok, %{root: Keyword.fetch!(opts, :root)}}
    def content_version(_), do: 123
    def world_dir(s), do: s.root
    def generated(_), do: 0
    def ensure(_, _, _), do: :ok

    def read(s, level, region) do
      natural = :erlang.binary_to_term(File.read!(Path.join(s.root, "natural.term")))

      cells =
        if level == 0 and region == {0, 0, 0} do
          for lz <- 0..(@extent - 1), ly <- 0..(@extent - 1), lx <- 0..(@extent - 1), into: <<>>,
            do: <<Map.get(natural, {lx - 1, ly - 1, lz - 1}, 0)::16-little>>
        else
          :binary.copy(<<0, 0>>, @extent * @extent * @extent)
        end

      bytes = Payload.encode(%Payload{level: level, region: region, cells: cells}, %{}, 0, 123)
      {:ok, h} = Codec.decode_payload_header(bytes)
      {:ok, bytes, h}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "climate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @catalog <> ".json"]), Path.join(root, "properties.json"))
    %{root: root}
  end

  defp start(c, name, natural, opts \\ []) do
    dir = Path.join(c.root, "#{name}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "natural.term"), :erlang.term_to_binary(Map.new(natural)))
    opts = Keyword.merge([source: NaturalSource, log: Log, root: dir, observer: self(), name: nil,
      property_catalog_path: Path.join(c.root, "properties.json")], opts)
    start_supervised!({World, opts}, id: name)
  end

  # Test-only 热脉冲环境：有限源 power_w × energy_j 装在 source_macro 宏格。
  defp pulse(c, name, env) do
    path = Path.join(c.root, "#{name}-pulse.json")
    File.write!(path, Jason.encode!(Map.merge(%{classification: "Test-only", environment_w_per_m2_k: 10.0,
      ambient_kelvin: @warm, tolerance_kelvin: 1.0, emissivity: 0.9, view_range_cells: 8}, env)))
    path
  end

  defp zone({x0, z0}, {x1, z1}, k), do: %{min: [x0, z0], max: [x1, z1], ambient_kelvin: k}
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [], @box)
  defp rows(s), do: Map.values(s.damage)
  defp at(s, cell), do: Enum.find(rows(s), &(&1.granularity == 0 and Damage.macro(&1) == cell))

  # 推进到落定（不再活动）或模拟时间到 until；返回终态与途经的每个观察。
  defp run_until(w, until, seen \\ []) do
    s = observe(w)

    if not s.thermal.active or s.thermal.elapsed_s >= until - 1.0e-9 do
      {s, Enum.reverse([s | seen])}
    else
      send(w, :thermal_commit)
      run_until(w, until, [s | seen])
    end
  end

  # 冻结样本：去掉事务序号，按键排序的属性行 + 热账（不含配置）。
  defp digest(s) do
    rows = s.damage |> Enum.sort() |> Enum.map(fn {k, r} -> {k, Map.drop(r, [:seq, :request_id])} end)
    ledger = Map.drop(s.thermal, [:sources])
    Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({rows, ledger}, [:deterministic])), case: :lower)
  end

  # 眼睛射线查询一格的属性行（正式 tool_intent 只读查询），眼睛在格正上方 2.5 m。
  defp query(w, {x, y, z}) do
    eye = {x + 0.5, y + 2.5, z + 0.5}
    a = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
    seq = System.unique_integer([:positive, :monotonic])
    {:ok, row} = World.tool_intent(w, a, %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0,
      tool_id: 1, direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0},
      material: 0})
    row
  end

  # 场景 A：石板 y=4（x,z ∈ 5..11），源格 (8,4,8)，其上木 (7,5,8)、冰 (9,5,8)；ε 0.9、容差 1 K、20 kW × 200 kJ。
  defp slab_pulse(c, name, extra) do
    natural = (for x <- 5..11, z <- 5..11, do: {{x, 4, z}, @stone}) ++ [{{7, 5, 8}, @wood}, {{9, 5, 8}, @ice}]
    w = start(c, name, natural)
    env = Map.merge(%{source_macro: [8, 4, 8], power_w: 20_000.0, energy_j: 200_000.0}, extra)
    :ok = World.thermal_experiment(w, pulse(c, name, env))
    {settled, _} = run_until(w, 20_000.0)
    refute settled.thermal.active
    settled
  end

  @master_digest "b05f8a87c7ee894f8088bff9cc96d3952143e4ddf4af17c2a855125c6d7b7b5c"

  test "无气候区：热脉冲落定后的属性行与热账和 master d6695e86 逐位相同；远处气候区（不含场景）结果同样逐位相同", c do
    plain = slab_pulse(c, :plain, %{})
    assert digest(plain) == @master_digest
    far = slab_pulse(c, :far, %{climate_zones: [zone({100, 100}, {120, 120}, @cold)]})
    assert digest(far) == @master_digest
    # 样本非平凡：源格与邻格有温度行、木格被辐射/导热触及；暖环境下天然冰（273.15 K ≠ 293.15 K）保持静止、无行。
    assert at(plain, {8, 4, 8}) && at(plain, {7, 5, 8})
    assert at(plain, {9, 5, 8}) == nil
  end

  # 集总模型（同 thermal_static_phase_test）：孤立石格 C = 21360 J/K，六面空气 h = 10 → hA = 60 W/K，τ = 356 s。
  # 1 kW 源 10 s：ΔT(10) = (1000/60)(1 − e^(−10/356))，之后按 e^(−(t−10)/356) 回落到“区温”；0.01 K 容差的离开时刻
  # t* = 10 + 356·ln(ΔT(10)/0.01) = 1374.27 s。若空气换热误用全局 293.15 K，石格会向 +45 K 漂移，模型整体不成立。
  test "寒区孤立石格：从区温 248.15 K 起热，按手算指数律回落到区温并在 t* 落定；热账相对区温闭合", c do
    w = start(c, :lumped, [{{8, 8, 8}, @stone}])
    env = %{tolerance_kelvin: 0.01, emissivity: 0.0, source_macro: [8, 8, 8], power_w: 1000.0, energy_j: 10_000.0,
      climate_zones: [zone({0, 0}, {63, 63}, @cold)]}
    :ok = World.thermal_experiment(w, pulse(c, :lumped, env))
    tau = @stone_c / 60.0
    peak = 1000.0 / 60.0 * (1 - :math.exp(-10.0 / tau))
    excess = fn t -> peak * :math.exp(-(t - 10.0) / tau) end

    {warm, _} = run_until(w, 600.0)
    t = warm.thermal.elapsed_s
    assert t >= 600.0 and t < 1300.0
    assert_in_delta (at(warm, {8, 8, 8}).temperature_kelvin - @cold) / excess.(t), 1.0, 1.0e-3

    {settled, _} = run_until(w, 3000.0)
    refute settled.thermal.active
    exit = 10.0 + tau * :math.log(peak / 0.01)
    assert_in_delta exit, 1374.27, 0.01
    assert settled.thermal.elapsed_s >= exit - 0.7 and settled.thermal.elapsed_s <= exit + 0.8
    stone = at(settled, {8, 8, 8})
    assert stone.temperature_kelvin - @cold <= 0.01 and stone.temperature_kelvin > @cold
    assert_in_delta settled.thermal.supplied_j, 10_000.0, 1.0e-6
    assert_in_delta settled.thermal.supplied_j + settled.thermal.environment_j,
      @stone_c * (stone.temperature_kelvin - @cold), 1.0e-3
  end

  # 寒区天然冰默认焓 = C·(248.15 − 273.15) = −48 250 000 J/格 → 温度 248.15 K = 区温：静止，可作邻居入域（暖区同一块冰
  # 会被排除，见 thermal_static_phase_test）。脉冲 200 kJ 远小于把冰升到 273.15 K 所需 48.25 MJ，冰保持固态。
  test "寒区天然冰：默认在区温、作为邻居入域吸热、始终是冰，落定后回到区温 ±1 K；热账（显热 + 相态焓）闭合", c do
    natural = (for x <- 5..11, z <- 5..11, do: {{x, 4, z}, @stone}) ++
      [{{8, 5, 8}, @ice}, {{9, 5, 8}, @ice}, {{11, 5, 11}, @ice}]
    w = start(c, :ice, natural)
    env = %{source_macro: [8, 4, 8], power_w: 20_000.0, energy_j: 200_000.0,
      climate_zones: [zone({0, 0}, {63, 63}, @cold)]}
    :ok = World.thermal_experiment(w, pulse(c, :ice, env))

    untouched = query(w, {11, 5, 11})
    assert untouched.material == @ice
    assert_in_delta untouched.temperature_kelvin, @cold, 1.0e-9
    assert_in_delta query(w, {5, 4, 5}).temperature_kelvin, @cold, 1.0e-9

    {settled, trail} = run_until(w, 20_000.0)
    refute settled.thermal.active

    for s <- trail, cell <- [{8, 5, 8}, {9, 5, 8}], row = at(s, cell), do: assert(row.material == @ice)
    ice = at(settled, {8, 5, 8})
    assert ice.phase_energy_j > -48_250_000.0
    assert ice.temperature_kelvin < 273.15 and abs(ice.temperature_kelvin - @cold) <= 1.0
    assert at(settled, {11, 5, 11}) == nil

    stored =
      Enum.reduce(rows(settled), 0.0, fn row, sum ->
        case row.material do
          @ice -> sum + row.phase_energy_j - @ice_c * (@cold - 273.15)
          @stone -> sum + @stone_c * (row.temperature_kelvin - @cold)
        end
      end)

    assert_in_delta settled.thermal.supplied_j, 200_000.0, 1.0e-6
    assert_in_delta settled.thermal.supplied_j + settled.thermal.environment_j, stored, 1.0e-3
  end

  # 边界：x ≤ 7 为寒区。区内外相邻的未记录格各在自己的环境温度静止；若跨区导热，(7,4,8) 与 (8,4,8) 之间 45 K 温差
  # 经 G = 25 W/K 以约 1.1 kW 持续流动，两侧都会偏离各自环境、被拉入活动集合并沿边界扩散，永不落定。
  test "寒区边界不热失控：暖侧脉冲不跨界导热，寒侧格始终无属性行；暖侧邻格升温；脉冲落定后活动集合清空", c do
    natural = for x <- 4..12, do: {{x, 4, 8}, @stone}
    w = start(c, :boundary, natural)
    env = %{source_macro: [8, 4, 8], power_w: 20_000.0, energy_j: 200_000.0,
      climate_zones: [zone({0, 0}, {7, 63}, @cold)]}
    :ok = World.thermal_experiment(w, pulse(c, :boundary, env))
    {settled, trail} = run_until(w, 20_000.0)

    refute settled.thermal.active
    for s <- trail, row <- rows(s), do: assert(elem(Damage.macro(row), 0) >= 8)
    assert Enum.any?(trail, &(at(&1, {9, 4, 8}) && at(&1, {9, 4, 8}).temperature_kelvin > @warm + 1.0))
    for row <- rows(settled), do: assert(abs(row.temperature_kelvin - @warm) <= 1.0)
  end

  test "寒区边界不跨辐射：暖侧热石隔一格空气面对寒区石头，寒区石头无属性行；对照：暖侧同距石头被辐射加热", c do
    natural = [{{6, 8, 8}, @stone}, {{8, 8, 8}, @stone}, {{10, 8, 8}, @stone}]
    w = start(c, :radiation, natural)
    env = %{source_macro: [8, 8, 8], power_w: 50_000.0, energy_j: 1_000_000.0,
      climate_zones: [zone({0, 0}, {7, 63}, @cold)]}
    :ok = World.thermal_experiment(w, pulse(c, :radiation, env))
    {settled, trail} = run_until(w, 20_000.0)

    refute settled.thermal.active
    for s <- trail, do: assert(at(s, {6, 8, 8}) == nil)
    assert Enum.any?(trail, &(at(&1, {10, 8, 8}) && at(&1, {10, 8, 8}).temperature_kelvin > @warm))
  end

  # 生产热环境资产形态：气候区写在 environment.json（DA_ThermalEnvironment 发布）；资产是唯一来源，冷重启以资产为准。
  test "资产气候区：未记录格按所在区取默认温度，快照带同一份区表；站在区温地面无鞋底接触；资产去掉气候区后冷重启即恢复", c do
    zones = [%{"min" => [0, 0], "max" => [7, 63], "ambient_kelvin" => @cold}]
    env = Path.join(c.root, "environment.json")
    File.write!(env, Jason.encode!(%{classification: "Global system", ambient_kelvin: @warm, environment_w_per_m2_k: 10,
      tolerance_kelvin: 1, emissivity: 0.9, view_range_cells: 8, climate_zones: zones}))
    natural = for x <- 4..12, z <- 6..10, do: {{x, 4, z}, @stone}
    w = start(c, :asset, natural, thermal_environment_path: env)

    assert_in_delta query(w, {6, 4, 8}).temperature_kelvin, @cold, 1.0e-9
    assert_in_delta query(w, {9, 4, 8}).temperature_kelvin, @warm, 1.0e-9
    assert World.simulation_snapshot(w, [], @box).property_context.climate_zones == zones

    # 身体脚踩寒区石（区温 248.15 K）：与环境无温差，不进内核；若按全局 293.15 K 判据会是 45 K 温差的接触。
    send(w, {:body_contact, 1001, self(), %{feet: {6.5, 5.0, 8.5}, height: 1.8, radius: 0.3, skin_k: 307.15,
      capacity: 24_430.0, area: 1.8}})
    send(w, :thermal_commit)
    _ = observe(w)
    refute_received {:body_heat, _}

    :ok = stop_supervised(:asset)
    File.write!(env, Jason.encode!(%{classification: "Global system", ambient_kelvin: @warm, environment_w_per_m2_k: 10,
      tolerance_kelvin: 1, emissivity: 0.9, view_range_cells: 8}))
    w = start(c, :asset, natural, thermal_environment_path: env)
    assert_in_delta query(w, {6, 4, 8}).temperature_kelvin, @warm, 1.0e-9
    refute Map.has_key?(World.simulation_snapshot(w, [], @box).property_context, :climate_zones)
  end
end
