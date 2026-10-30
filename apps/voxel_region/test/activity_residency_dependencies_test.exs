defmodule VoxelRegion.ActivityResidencyDependenciesTest do
  @moduledoc "只测试：物理 owner 的驻留种子投影，不启动 World、数据库或网络。"
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{Casting, Liquids, Projectiles, Thermal}

  defp thermal_state do
    %{thermal: %{active: false, sources: %{}, semblances: %{}, config: %{"view_range_cells" => 0}},
      thermal_work: %{hot: MapSet.new(), hot_rows: %{}, touched: MapSet.new(), pending: MapSet.new(),
        due: MapSet.new(), electric: MapSet.new(), burning: %{}, cells: MapSet.new(), geometry: %{},
        sights: %{}, exact: false, domain: %{pending: false, table: %{}, finite: MapSet.new(), seen: nil}},
      thermal_run: nil, bodies: %{}, damage: %{}, attachments: %{},
      properties: %{materials: %{}}, source: __MODULE__, liquid_units: %{}, seq: 0, thermal_quiet_seq: 0}
  end

  test "休眠后的历史计算域不永久保留，无窗有限热源仍保留完整XYZ与祖页" do
    state = thermal_state()
    state = put_in(state.thermal_work.cells, MapSet.new([{4096, -4096, 4096}]))
    assert {:ok, {[], [], []}} = Thermal.residency_dependencies(state)
    assert Thermal.seed_keys(state) == []
    state = put_in(state.thermal.sources, %{{-65, 130, -193} => %{remaining_j: 3.0}})
    assert {:ok, {keys, [], []}} = Thermal.residency_dependencies(state)
    assert {0, {-2, 2, -4}} in keys
    assert {5, {-1, 0, -1}} in keys
    refute {0, {64, -64, 64}} in keys
    assert Thermal.seed_keys(state) == keys
    # 热活动未自然结束：下一提交续行检查仍读的当前计算域由热 owner 保有，提交间不退休；步前准备不因此提前读取。
    state = put_in(state.thermal.active, true)
    assert {:ok, {keys, [], []}} = Thermal.residency_dependencies(state)
    assert {0, {64, -64, 64}} in keys
    refute {0, {64, -64, 64}} in Thermal.seed_keys(state)
  end

  test "进行中的热步保持计算域，未结算行与未来转化保留原身份" do
    state = thermal_state()
    row = %{micro: {5120, -5120, 1024}, granularity: 2, owner: {71, 2}, incarnation: 0, material: 11}
    key = VoxelRegion.Damage.key(row)
    state = %{state | damage: %{key => row}, thermal_run: %{visited: MapSet.new()},
      thermal_work: %{state.thermal_work | cells: MapSet.new([{192, -192, 320}]), due: MapSet.new([key])}}
    assert {:ok, {keys, [], ids}} = Thermal.residency_dependencies(state)
    assert {0, {3, -3, 5}} in keys
    assert {71, 2} in ids
    assert {0, {3, -3, 5}} in Thermal.seed_keys(state)
    state = %{state | thermal_run: nil,
      thermal_work: %{state.thermal_work | domain: Map.merge(state.thermal_work.domain,
        %{pending: true, cells: %{{-320, 192, -192} => 0}})}}
    assert {:ok, {pending_keys, [], _}} = Thermal.residency_dependencies(state)
    for key <- [{0, {3, -3, 5}}, {0, {-5, 3, -3}}] do
      assert key in pending_keys
      assert key in Thermal.seed_keys(state)
    end
  end

  test "未落地拟态保留未来接触及到期释放位置，不能因当前无热格而退休" do
    state = thermal_state()
    s = %{origin: {0.5, 0.5, 0.5}, velocity: {1.0, 0.0, 0.0}, age_s: 0.0,
      flight_s: 3.0, rest: {130.5, -65.5, 192.5}, radius_m: 0.1,
      contact: %{target: %{granularity: 0, micro: {1040, -528, 1536}, owner: {0, 0}}}}
    state = put_in(state.thermal.semblances, %{{12, 0} => s})
    assert {:ok, {keys, [], _ids}} = Thermal.residency_dependencies(state)
    assert {0, {2, -2, 3}} in keys
  end

  test "天然活动尚未发布不能伪装成空依赖" do
    assert {:error, {:natural_activity_unregistered, VoxelRegion.GeneratedStore}} =
      Thermal.residency_dependencies(%{thermal_state() | source: VoxelRegion.GeneratedStore})
  end

  test "静态资格只解除自身 exact pin，未知页不全局阻退且真实热域继续保有" do
    alias VoxelRegion.World.{Pages, PageLoad}
    p = {0, {-2, -3, -4}}
    unknown = {0, {8, 9, 10}}
    coarse = {5, {-1, -1, -1}}
    state = thermal_state() |> Map.merge(%{source: VoxelRegion.GeneratedStore, static_l0_retirement: true,
      resident: MapSet.new([p, unknown, coarse]), page_load: PageLoad.new(),
      pages: Pages.new(), static_l0: %{VoxelRegion.World.StaticL0.Index.new() | eligible: MapSet.new([p])}})
    assert {:ok, {[], exact, []}} = Thermal.residency_dependencies(state)
    assert MapSet.new(exact) == MapSet.new([unknown, coarse])
    # 原生未写回域与持续活动域各自足以 pin 已有资格的页，保留原祖页和扩邻语义。
    pending = put_in(state.thermal_work.domain, %{state.thermal_work.domain | pending: true} |> Map.put(:cells, %{{-128, -192, -256} => 0}))
    assert {:ok, {keys, ^exact, []}} = Thermal.residency_dependencies(pending)
    assert p in keys
    assert coarse in keys
    active = state |> put_in([:thermal, :active], true) |> put_in([:thermal_work, :cells], MapSet.new([{-128, -192, -256}]))
    assert {:ok, {keys, ^exact, []}} = Thermal.residency_dependencies(active)
    assert p in keys
  end

  test "真实电动势种子保留页，图准备owner维护实际跨页依赖，附件存在本身不阻塞" do
    state = thermal_state()
    row = %{micro: {0, 0, 0}, granularity: 0, owner: {0, 0}, incarnation: 0, material: 42, stored_j: 3.0}
    key = VoxelRegion.Damage.key(row)
    state = %{state | properties: %{materials: %{42 => %{"battery_volts_per_m" => 24}}},
      attachments: %{{1, 0, {512, 0, 0}} => {2, 19}}, damage: %{key => row},
      thermal_work: %{state.thermal_work | electric: MapSet.new([key])}}
    assert {:ok, {keys, [], []}} = Thermal.residency_dependencies(state)
    assert {0, {0, 0, 0}} in keys
    state = %{state | damage: %{}, thermal_work: %{state.thermal_work | electric: MapSet.new()}}
    assert {:ok, {[], [], []}} = Thermal.residency_dependencies(state)
  end

  test "退休历史页只裁剪seen无关记录，保留活域的旧比较值与待转化集合" do
    state = thermal_state()
    live = %{micro: {0, 0, 0}, granularity: 0, owner: {0, 0}, incarnation: 0, material: 11, temperature_kelvin: 310.0}
    old_key = VoxelRegion.Damage.key(live)
    gone_key = {:retired, 1}
    old = %{old_key => live, gone_key => %{data: :old_page}}
    state = %{state | damage: %{old_key => %{live | temperature_kelvin: 350.0}},
      thermal_work: %{state.thermal_work | cells: MapSet.new([{0, 0, 0}]),
        geometry: %{{256, 0, 0} => []}, due: MapSet.new([old_key]),
        domain: %{state.thermal_work.domain | table: %{{0, {0, 0, 0}} => %{damage_key: old_key, cell: {0, 0, 0}}},
          finite: MapSet.new([{0, {0, 0, 0}}]), seen: {old, %{{0, 0, 0} => 7, {256, 0, 0} => 9}}}}}
    next = Thermal.release_residency(state, [{0, {4, 0, 0}}])
    assert next.thermal_work.domain.seen == {%{old_key => live}, %{{0, 0, 0} => 7}}
    assert next.thermal_work.geometry == %{}
    assert next.thermal_work.due == MapSet.new([old_key])
    assert next.damage[old_key].temperature_kelvin == 350.0
  end

  test "电动势源耗尽后，别处仍有余热也不永久保留已消费旧图" do
    state = thermal_state()
    work = state.thermal_work |> Map.put(:circuit, %{status: :complete, seq: 3, keys: MapSet.new([{0, {64, 64, 64}}])})
      |> Map.put(:hot, MapSet.new([{0, 0, 0}]))
    assert {:ok, {keys, [], []}} = Thermal.residency_dependencies(%{state | thermal_work: work})
    assert {0, {0, 0, 0}} in keys
    refute {0, {64, 64, 64}} in keys
  end

  test "自由附件待结算只有足迹页，不能要求不存在的有主locator" do
    state = thermal_state()
    row = %{micro: {1040, 16, 16}, granularity: 3, owner: {3, 4}, incarnation: 3, material: 24}
    key = VoxelRegion.Damage.key(row)
    work = %{state.thermal_work | pending: MapSet.new([key])}
    state = state |> Map.put(:attachment_owners, %{}) |> Map.put(:damage, %{key => row}) |> Map.put(:thermal_work, work)
    assert {:ok, {keys, [], []}} = Thermal.residency_dependencies(state)
    assert {0, {2, 0, 0}} in keys
  end

  test "液体活动在边界两层邻域仍保留，失败或due不改变原需求" do
    state = %{liquid_active: MapSet.new([{64, 64, -64}]), liquid_bounds: {{-256, -256, -256}, {256, 256, 256}},
      liquid_due: 1, page_load: %{sim: %{status: :failed}}}
    assert {:ok, {keys, [], []}} = Liquids.residency_dependencies(state)
    assert {0, {0, 1, -1}} in keys
    assert {0, {1, 0, -1}} in keys
    assert {0, {1, 1, -2}} in keys
  end

  test "液体域外唤醒格的步前准备只保留实际域内读取页" do
    state = %{liquid_active: MapSet.new([{63, 193, 2}, {64, 192, 2}]),
      liquid_bounds: {{64, 0, 2}, {65, 196, 3}}}
    assert {:ok, {keys, [], []}} = Liquids.residency_dependencies(state)
    assert Liquids.seed_keys(state) == keys
    refute {0, {0, 3, 0}} in keys
    assert {0, {1, 2, 0}} in keys
    assert {0, {1, 3, 0}} in keys
  end

  test "飞行投射物保留未来真实弦段的中间区域，不仅是origin和rest" do
    shot = %{projectile_source: %{}, origin: {0.0, 0.0, 0.0}, velocity: {6400.0, 0.0, 0.0},
      age_s: 0.0, lifetime_s: 0.05, t0_us: 0, radius_m: 0.1}
    state = %{thermal: %{semblances: %{{1, 0} => shot}}}
    assert {:ok, {keys, [], []}} = Projectiles.residency_dependencies(state)
    assert {0, {2, -1, 0}} in keys
    assert {0, {5, -1, 0}} in keys
    assert {0, {0, 0, 0}} in keys
    refute {0, {0, 2, 0}} in keys
  end

  test "已冻结身体交付不再读取飞行几何" do
    state = %{thermal: %{semblances: %{{1, 0} => %{projectile_source: %{}, impact_delivery: %{}}}}}
    assert {:ok, {[], [], []}} = Projectiles.residency_dependencies(state)
  end

  test "前摇保留脚下与重新裁决射程，不依赖玩家窗口或定时租约" do
    actor = %{eye: {128.0, 65.0, -64.0}, feet: {128.0, 1.0, -64.0}}
    state = %{magic: %{range_m: 2.0}, pending_casts: %{1 => %{actor: actor, request: %{action: 1}}}, thermal: nil}
    assert {:ok, {keys, [], []}} = Casting.residency_dependencies(state)
    assert {0, {2, 0, -1}} in keys
    assert {0, {1, 1, -2}} in keys
  end
end
