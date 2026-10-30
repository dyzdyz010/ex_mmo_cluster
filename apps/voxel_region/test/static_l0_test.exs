defmodule VoxelRegion.StaticL0Test do
  @moduledoc "只测试：纯资格算法；完整 core、XYZ 邻域与已接纳物性，无 World、数据库或网络。"
  use ExUnit.Case, async: true
  alias VoxelRegion.World.StaticL0.Index, as: StaticIndex
  alias VoxelRegion.World.{Pages, StaticL0}
  alias MmoContracts.Voxel.Payload

  setup_all do
    catalog = VoxelRegion.Damage.load(VoxelRegion.TestSupport.catalog())

    # 与 PhaseMaterialTest 相同的冻结物性；纯计算合法输入，不修改运行中的 World。
    basalt =
      Map.merge(catalog.materials[13], %{
        "phase_peer_material_id" => 22,
        "phase_transition_kelvin" => 1268.15,
        "latent_heat_per_macro_j" => 10_150_000.0,
        "heat_capacity_per_macro" => 31_900.0
      })

    %{catalog: %{catalog | materials: Map.put(catalog.materials, 13, basalt)}}
  end

  test "空气、岩层和未点燃可燃物允许；雪冰液体与未知材料拒绝", c do
    for id <- [0, 1, 13, 19] do
      assert StaticL0.material(id, c.catalog.materials, 293.15) == :ok
    end

    combustible =
      for {id, m} <- c.catalog.materials, VoxelRegion.Combustion.combustible?(m), do: id

    assert combustible != []
    for id <- combustible, do: assert(StaticL0.material(id, c.catalog.materials, 293.15) == :ok)

    for id <- [4, 20, 21, 22, 65535],
        do: refute(StaticL0.material(id, c.catalog.materials, 293.15) == :ok)
  end

  test "阈值不以热模拟的 1 K 容差放行", c do
    for {id, m} <- c.catalog.materials do
      if VoxelRegion.Combustion.combustible?(m) do
        refute StaticL0.material(id, c.catalog.materials, m["ignition_kelvin"]) == :ok
      end

      if VoxelRegion.Transform.enabled?(m) do
        refute StaticL0.material(id, c.catalog.materials, m["transform_kelvin"]) == :ok
      end
    end

    threshold = c.catalog.materials[13]["phase_transition_kelvin"]
    refute StaticL0.material(13, c.catalog.materials, threshold) == :ok
    refute StaticL0.material(13, c.catalog.materials, threshold + 0.1) == :ok
  end

  test "完整 core 各角、边、最后格的唯一风险不能被抽样漏掉；ring 不归本页" do
    cells = :binary.copy(<<0, 0>>, 66 * 66 * 66)

    for x <- [1, 64], y <- [1, 64], z <- [1, 64] do
      assert StaticL0.core_materials(put_cell(cells, {x, y, z}, 4)) == [0, 4]
    end

    for pos <- [{32, 1, 32}, {1, 32, 32}, {32, 32, 64}] do
      assert StaticL0.core_materials(put_cell(cells, pos, 22)) == [0, 22]
    end

    assert StaticL0.core_materials(put_cell(cells, {0, 0, 0}, 4)) == [0]
    assert StaticL0.core_materials(:binary.copy(<<19, 0>>, 66 * 66 * 66)) == [19]
  end

  test "负 XYZ 的 27 个 core 任一缺失或拒绝都阻退，halo 不递归" do
    key = {0, {-3, -5, -7}}
    keys = Pages.expand([key])
    cores = Map.new(keys, &{&1, :ok})
    assert length(keys) == 27
    assert StaticL0.neighborhood(key, cores) == :ok

    for q <- keys do
      refute StaticL0.neighborhood(key, Map.delete(cores, q)) == :ok
      refute StaticL0.neighborhood(key, Map.put(cores, q, :recorded_page)) == :ok
    end

    assert StaticL0.neighborhood({1, {-3, -5, -7}}, cores) == :coarse_page
  end

  test "固定种子单调收紧，风险或缺证不能令拒绝变允许" do
    :rand.seed(:exsss, {2026, 10, 30})

    for _ <- 1..40 do
      key = {0, {:rand.uniform(20) - 10, :rand.uniform(20) - 10, :rand.uniform(20) - 10}}
      keys = Pages.expand([key])
      [a, b | _] = Enum.shuffle(keys)
      cores = Map.new(keys, &{&1, :ok}) |> Map.put(a, :recorded_page)
      refute StaticL0.neighborhood(key, cores) == :ok
      refute StaticL0.neighborhood(key, Map.delete(cores, b)) == :ok
    end
  end

  test "空 tombstone、false activity 与片段均为记录；无行才是无记录" do
    assert Pages.recorded_keys([]) == MapSet.new()

    assert Pages.recorded_keys([
             {{:page, :activity, {0, {-1, -2, -3}}}, false},
             {{:chunk, :liquid_active, {-8, -8, -8}}, MapSet.new()},
             {{:fragment, :structure, {4, {-9, -10, -11}}}, %{}},
             {{:fragment, :canopy, {5, {-12, -13, -14}}}, %{}}
           ]) ==
             MapSet.new([
               {0, {-1, -2, -3}},
               {0, {-2, -2, -2}},
               {0, {-9, -10, -11}},
               {0, {-12, -13, -14}}
             ])
  end

  test "重复写同一 dirty 单元仍撤销，影响仅反向 N；迟到同代摘要不能复活资格", c do
    {state, fact} = admitted(c.catalog)
    q = {0, {0, 0, 0}}
    eligible = state.static_l0.eligible
    assert MapSet.size(eligible) == 27
    unit = {:page, :base, q}
    next = Pages.mark(state, unit)

    assert next.static_l0.eligible ==
             MapSet.difference(eligible, MapSet.new(Pages.expand([q])))

    assert next.static_l0.cores[q].source_only == false
    next = StaticIndex.adopt(next, [{q, 0, fact}]) |> Pages.mark(unit)
    assert next.static_l0.cores[q].core == :recorded_page
    refute MapSet.member?(next.static_l0.eligible, q)
    assert MapSet.member?(next.page_dirty, unit)
  end

  test "退休只删除自身证明；新代、错源与取消结果不能恢复旧资格", c do
    {state, fact} = admitted(c.catalog)
    q = {0, {0, 0, 0}}
    kept = MapSet.delete(state.static_l0.eligible, q)
    retired = state |> StaticIndex.forget([q]) |> put_in([:page_generation, q], 1)
    assert retired.static_l0.eligible == kept
    refute Map.has_key?(retired.static_l0.cores, q)
    assert StaticIndex.adopt(retired, [{q, 0, fact}]) == retired
    assert StaticIndex.adopt(retired, [{q, 1, %{fact | source: :wrong_source}}]) == retired

    assert {retired, [], []} ==
             VoxelRegion.World.PageLoad.stage(retired, self(), [], [], [q], [{q, 1, fact}])

    reloaded = StaticIndex.adopt(retired, [{q, 1, fact}])
    assert reloaded.static_l0.cores[q].generation == 1
    assert reloaded.static_l0.cores[q].source_only
    assert MapSet.member?(reloaded.static_l0.eligible, q)
  end

  test "最终环境和目录参与绑定，未知环境／材料语义拒绝", c do
    {state, _} = admitted(c.catalog)
    assert {:ok, context} = StaticL0.context(state)
    assert {:ok, changed} = StaticL0.context(put_in(state.properties.digest, <<1>>))
    refute context.binding == changed.binding

    assert {:ok, changed} =
             StaticL0.context(put_in(state.thermal.config["ambient_kelvin"], 300.0))

    refute context.binding == changed.binding

    assert {:error, :static_l0_nonuniform_environment} =
             StaticL0.context(put_in(state.thermal.config["climate_zones"], [%{}]))

    assert {:error, :static_l0_read_footprint_exceeds_halo} =
             StaticL0.context(put_in(state.thermal.config["view_range_cells"], 65))

    unknown = put_in(c.catalog.materials[19]["new_default_power"], 1.0)
    assert :unknown_material_semantics = StaticL0.material(19, unknown.catalog.materials, 293.15)
  end

  defp admitted(catalog) do
    keys = for x <- -2..2, y <- -2..2, z <- -2..2, do: {0, {x, y, z}}

    state = %{
      static_l0_retirement: true,
      source: VoxelRegion.GeneratedStore,
      source_state: %{identity: {:kernel, :config, :computed, :pinned}},
      properties: catalog,
      thermal: %{config: %{"ambient_kelvin" => 293.15, "view_range_cells" => 8}},
      pages: Pages.new(),
      static_l0: StaticIndex.new(),
      resident: MapSet.new(keys),
      page_generation: %{},
      page_load: VoxelRegion.World.PageLoad.new(),
      page_dirty: MapSet.new()
    }

    {:ok, state} = StaticIndex.start(state)

    fact = %{
      source: state.source_state.identity,
      materials: [0],
      body: {:uniform, 0},
      generated: 0,
      elapsed_us: 0
    }

    {StaticIndex.adopt(state, Enum.map(keys, &{&1, 0, fact})), fact}
  end

  defp put_cell(cells, pos, material) do
    offset = Payload.cell_index(pos) * 2
    <<head::binary-size(offset), _::16, tail::binary>> = cells
    head <> <<material::16-little>> <> tail
  end

  test "维护入口临时 resident=:all 也必须撤销此前已发出的证明", c do
    {state, _fact} = admitted(c.catalog)
    key = {0, {0, 0, 0}}
    assert MapSet.member?(state.static_l0.eligible, key)
    next = Pages.mark(%{state | resident: :all}, {:page, :base, key})
    assert next.static_l0.cores[key].core == :recorded_page
    refute MapSet.member?(next.static_l0.eligible, key)
  end

  test "不支持的最终环境返回明确原因而非 MatchError；普通观测声明未估算堆", c do
    {state, _} = admitted(c.catalog)
    assert {:error, {:static_l0_start_failed, :static_l0_read_footprint_exceeds_halo}} =
      StaticIndex.start(put_in(state.thermal.config["view_range_cells"], 65))
    assert %{static_l0_metadata_bytes: nil, static_l0_metadata_measurement: :debug_audit_only} =
      StaticIndex.observe(state)
  end

  for owner <- [:observation, :preparing, :liquid, :projectiles, :casting, :thermal_pending, :thermal_continuing] do
    test "#{owner} 独自需要已合格页时不能退休，释放该需求才解除", c do
      alias VoxelRegion.World.Residency
      {state, _} = admitted(c.catalog)
      state = ownership_state(state)
      key = {0, {0, 0, 0}}
      assert MapSet.member?(state.static_l0.eligible, key)
      assert {:ok, free, _} = Residency.required(state)
      refute MapSet.member?(free, key)
      {needed, released, reason} = owner_case(state, unquote(owner), key)
      assert MapSet.member?(needed.static_l0.eligible, key)
      assert {:ok, required, reasons} = Residency.required(needed)
      assert MapSet.member?(required, key)
      assert reasons[reason] > 0
      assert {:ok, after_release, _} = Residency.required(released)
      refute MapSet.member?(after_release, key)
    end
  end

  # 纯 owner 契约矩阵：构造已接纳的合法值调用真实投影模块，不回填任何运行中的 World。
  defp ownership_state(state) do
    Map.merge(state, %{thermal_work: VoxelRegion.ThermalWork.new(), thermal_run: nil,
      thermal: Map.merge(state.thermal, %{active: false, sources: %{}, semblances: %{}}),
      thermal_quiet_seq: 0, seq: 0, damage: %{}, bodies: %{}, attachments: %{}, instances: %{},
      attachment_owners: %{}, refined_region_owners: %{}, macro_owner_regions: %{}, attachment_regions: %{},
      canonical_subs: %{}, replica_subs: %{}, simulation_windows: %{}, input_ready: :queue.new(),
      input_current: nil, pending_casts: %{}, magic: nil, liquid_active: MapSet.new(), liquid_bounds: nil,
      liquid_units: %{}})
  end

  defp owner_case(state, :observation, _key) do
    {put_in(state.canonical_subs, %{self() => {{0,0,0},{1,1,1}}}), state, :observation}
  end
  defp owner_case(state, :preparing, key) do
    preparation = %{caller: self(), monitor: make_ref(), request: make_ref(), needs: {Pages.with_ancestors([key]), [], []}}
    {put_in(state.page_load.preparations, %{make_ref() => preparation}), state, :preparing}
  end
  defp owner_case(state, :liquid, _key) do
    cell = {-65, 1, 1}
    # 实际有记录的前沿在目标 halo 外，下一步两层读集跨边界；目标资格仍成立。
    state = state |> Pages.mark(Pages.cell_unit(:liquid_active, cell))
      |> Map.put(:liquid_bounds, {{-256,-256,-256},{256,256,256}})
      |> Map.put(:liquid_units, %{cell => 512})
    {put_in(state.liquid_active, MapSet.new([cell])), state, :liquid}
  end
  defp owner_case(state, :projectiles, _key) do
    shot = %{projectile_source: %{}, origin: {-128.0,1.0,1.0}, velocity: {6400.0,0.0,0.0},
      age_s: 0.0, lifetime_s: 0.05, t0_us: 0, radius_m: 0.1}
    {put_in(state.thermal.semblances, %{{1,0} => shot}), state, :projectiles}
  end
  defp owner_case(state, :casting, _key) do
    actor = %{eye: {1.5,2.5,1.5}, feet: {1.5,1.0,1.5}}
    state = %{state | magic: %{range_m: 2.0}}
    {%{state | pending_casts: %{1 => %{actor: actor, request: %{action: 1}}}}, state, :casting}
  end
  defp owner_case(state, :thermal_pending, _key) do
    domain = state.thermal_work.domain |> Map.put(:pending, true) |> Map.put(:cells, %{{1,1,1} => 0})
    {put_in(state.thermal_work.domain, domain), state, :thermal}
  end
  defp owner_case(state, :thermal_continuing, _key) do
    active = state |> put_in([:thermal, :active], true) |> put_in([:thermal_work, :cells], MapSet.new([{1,1,1}]))
    {active, state, :thermal}
  end
end
