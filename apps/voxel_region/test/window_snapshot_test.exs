defmodule VoxelRegion.WindowSnapshotTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{Cache, Payloads, WindowSnapshot}

  @box {{0, 0, 0}, {1, 1, 1}}

  # 只测试：纯输入抽取／运输算法，不启动 World、数据库或生成器。所有远处记录均在窗口及 ring 之外。
  test "固定窗口的冻结成本不随远处互不相交的叶子数增长" do
    base = empty()

    far =
      Enum.reduce(1..2_000, base, fn n, s ->
        cell = {n * 128, 0, 0}
        owner = {1, n}
        slots = %{0 => {11, owner}}

        %{
          s
          | refined: Map.put(s.refined, cell, slots),
            refined_regions: Map.put(s.refined_regions, {n * 2, 0, 0}, %{cell => slots}),
            refined_region_owners: Map.put(s.refined_region_owners, {n * 2, 0, 0}, %{owner => 1}),
            refined_owners: Map.put(s.refined_owners, owner, MapSet.new([cell])),
            instances: Map.put(s.instances, owner, %{parent: nil, definition_id: 1})
        }
      end)

    WindowSnapshot.freeze(base, @box)
    small = reductions(fn -> WindowSnapshot.freeze(base, @box) end)
    large = reductions(fn -> WindowSnapshot.freeze(far, @box) end)
    assert large < small * 2 + 2_000

    assert transfer(WindowSnapshot.freeze(far, @box)) ==
             transfer(WindowSnapshot.freeze(base, @box))
  end

  test "保护区按自然记录运输，不复制无消费方的查询索引或整张嵌套表" do
    regions = Map.new(1..1_000, fn n -> {n, %{holder: n, rect: {n, n, n + 1, n + 1}}} end)
    state = %{empty() | protection: %{regions: regions, index: %{unused: regions}}}
    {view, max_words} = transfer(WindowSnapshot.freeze(state, @box))
    assert view.protection == %{regions: regions}
    assert max_words < div(:erts_debug.flat_size(regions), 2)
  end

  test "冻结只定位整件，不因相同宏格内微格变稠密而重复展开槽" do
    make = fn count ->
      owner = {1, 1}
      slots = Map.new(0..(count - 1), &{&1, {11, owner}})

      state = %{
        empty()
        | refined: Map.new(0..63, &{{&1, 0, 0}, slots}),
          instances: %{owner => %{definition_id: 1}},
          prefabs: %{1 => %{definition: %{}}}
      }

      VoxelRegion.World.Canonical.index_refined(state)
    end

    sparse = make.(1)
    dense = make.(512)
    WindowSnapshot.freeze(sparse, @box)
    small = reductions(fn -> WindowSnapshot.freeze(sparse, @box) end)
    large = reductions(fn -> WindowSnapshot.freeze(dense, @box) end)
    assert large < small * 2 + 2_000
  end

  defp reductions(fun) do
    :erlang.garbage_collect()
    {:reductions, before} = Process.info(self(), :reductions)
    for _ <- 1..10, do: fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    div(after_count - before, 10)
  end

  test "GeneratedStore 的 index.bounds 按自然记录运输并保留 extent 与 nil" do
    bounds = Map.new(1..1_000, fn n -> {{n, n}, {n, n + 1}} end)
    source = %{index: %{extent: 64, bounds: bounds}}
    {view, max_words} = transfer(WindowSnapshot.freeze(%{empty() | source_state: source}, @box))
    assert view.source_state == source
    assert max_words < div(:erts_debug.flat_size(bounds), 2)
    {view, _} = transfer(WindowSnapshot.freeze(%{empty() | source_state: %{index: nil}}, @box))
    assert view.source_state == %{index: nil}
  end

  test "窗口树冠保留呈现绑定，但不携带无消费方的模板几何" do
    owner = {1, 1}
    cell = {0, 0, 0}

    state = %{
      empty()
      | macro_owner_regions: %{{0, 0, 0} => %{cell => owner}},
        instances: %{owner => %{definition_id: 7}},
        prefabs: %{
          # 生产 prefabs 条目是 Prefab.Catalog.Descriptor：呈现绑定在顶层，summary 等无窗口消费方。
          7 => %{
            presentation_bindings: %{58 => 2},
            summary: %{geometry: List.duplicate({cell, 58}, 1_000)}
          }
        },
        overlay: %{{0, cell} => {58, MmoContracts.Voxel.Skins.uniform(58)}},
        overlay_regions: %{{0, {0, 0, 0}} => MapSet.new([cell])}
    }

    {view, _} = transfer(WindowSnapshot.freeze(state, @box))
    assert :erts_debug.flat_size(view.prefabs) < 100
    view = VoxelRegion.World.Canonical.index_macro_owners(view)
    {anchors, _, _, _, _} = VoxelRegion.World.Canopy.project(view, 0, {0, 0, 0})
    assert anchors == %{cell => {58, owner, 2}}
  end

  test "完整载荷与整件几何均命中时不搬微格，几何或目录改变后重新取完整输入" do
    owner = {1, 1}
    cell = {0, 0, 0}
    properties = %{digest: <<1::256>>, materials: %{11 => %{"max_hp_per_macro" => 512.0}}}

    {:ok, bytes, header} =
      VoxelRegion.TestSupport.Source.read(%{observer: self(), root: "unused"}, 0, {0, 0, 0})

    state =
      %{
        empty()
        | properties: properties,
          refined: %{cell => %{0 => {11, owner}}},
          instances: %{owner => %{definition_id: 7}},
          prefabs: %{7 => %{presentation_bindings: %{}}}
      }
      |> Payloads.cache_put({0, {0, 0, 0}}, bytes, header)
      |> VoxelRegion.World.Canonical.index_refined()
      |> VoxelRegion.World.Observation.prepare_component_cache(@box)

    {warm, _} = transfer(WindowSnapshot.freeze(state, @box))
    assert warm.refined == %{}
    assert elem(warm.snapshot_geometry[owner], 0) == 1.0

    changed =
      VoxelRegion.World.Canonical.put_refined(state, cell, %{0 => {11, owner}, 1 => {11, owner}})

    {edited, _} = transfer(WindowSnapshot.freeze(Payloads.cache_delete(changed, {0, {0, 0, 0}}), @box))
    assert edited.refined == changed.refined
    assert edited.snapshot_geometry == %{}

    {catalog_changed, _} =
      transfer(
        WindowSnapshot.freeze(%{state | properties: %{properties | digest: <<2::256>>}}, @box)
      )

    assert catalog_changed.refined == state.refined
    assert catalog_changed.snapshot_geometry == %{}
  end

  test "组装的临时 LRU 淘汰不能丢掉已经冻结的完整区域字节" do
    alias MmoContracts.Voxel.{Payload, Codec}
    source = %{observer: self(), root: "unused"}
    owner = {1, 0}
    definition = <<7::256>>

    record = %{
      definition_id: definition,
      anchor: {1536, 0, 0},
      orientation: 0,
      parent_id: {0, 0},
      component_slot: 0
    }

    slots = %{0 => {11, owner}}
    {:ok, bytes, header} = VoxelRegion.TestSupport.Source.read(source, 0, {3, 0, 0})
    {:ok, base} = Payload.decode(bytes)

    payload = %{
      base
      | refined: %{Payload.cell_index({1, 1, 1}) => slots},
        instances: %{owner => record},
        format_version: 5
    }

    frozen = Payload.encode(payload, %{}, 0, header.content_version)
    {:ok, frozen_header} = Codec.decode_payload_header(frozen)

    cached =
      Map.new([1, 2], fn x ->
        {:ok, bytes, h} = VoxelRegion.TestSupport.Source.read(source, 0, {x, 0, 0})
        {{0, {x, 0, 0}}, {bytes, h}}
      end)
      |> Map.put({0, {3, 0, 0}}, {frozen, frozen_header})

    put_all = fn state ->
      Enum.reduce(cached, state, fn {key, {bytes, h}}, acc -> Payloads.cache_put(acc, key, bytes, h) end)
    end

    # 预算恰好容纳三条已缓存载荷（含 Cache 元信息权重）；组装端再生成区域 0 必然触发 LRU 淘汰。
    limit = Cache.stats(put_all.(%{empty() | cache: Cache.new(1_073_741_824)}).cache).bytes

    state =
      %{
        empty()
        | source: VoxelRegion.TestSupport.Source,
          source_state: source,
          cv: header.content_version,
          cache: Cache.new(limit),
          refined: %{{192, 0, 0} => slots},
          instances: %{owner => record},
          prefabs: %{definition => %{presentation_bindings: %{}}},
          snapshots: MapSet.new([{0, {3, 0, 0}}])
      }
      |> put_all.()
      |> VoxelRegion.World.Canonical.index_refined()

    assert Enum.sort(Payloads.cached_keys(state)) == Enum.sort(Map.keys(cached))
    box = {{0, 0, 0}, {4, 1, 1}}
    {view, _} = transfer(WindowSnapshot.freeze(state, box))
    assert view.refined == %{}
    assert {:ok, snapshot, _} = WindowSnapshot.build(view, box)
    assert Map.new(snapshot.regions)[{3, 0, 0}] == frozen
  end

  test "异步几何缓存接纳拒绝旧切点和旧目录，不把旧汇总标成新输入的缓存" do
    # 只测试：纯 World 回调的缓存接纳边界，不启动服务，不给运行中的 authority 注入状态。
    owner = {1, 0}
    old = %{digest: <<1::256>>, materials: %{}}
    token = make_ref()

    state =
      %{empty() | properties: old, seq: 1, refined: %{{0, 0, 0} => %{0 => {11, owner}}}}
      |> VoxelRegion.World.Canonical.index_refined()
      |> Map.put(:canonical_snapshots, %{token => %{feed: self(), seq: 1, properties: old}})
      |> Map.merge(%{clock: {VoxelRegion.World.Clock, nil}, input_ready: :queue.new(),
        input_scheduled: false, thermal_run: nil, thermal_due: nil, liquid_due: nil,
        page_load: VoxelRegion.World.PageLoad.new(), page_store: %{level: :ok},
        residency: VoxelRegion.World.Residency.new()})

    for current <- [%{state | seq: 2}, %{state | properties: %{old | digest: <<2::256>>}}] do
      assert {:reply, :ok, next} =
               VoxelRegion.World.handle_call(
                 {:window_geometry, token, [{owner, {1.0, MapSet.new(), []}}]},
                 {self(), make_ref()},
                 current
               )

      assert Map.get(next, :component_cache, %{}) == %{}
    end
  end

  defp transfer(cursor, view \\ %{}, max_words \\ 0) do
    case WindowSnapshot.next(cursor) do
      :done ->
        {view, max_words}

      {items, next} ->
        transfer(
          next,
          WindowSnapshot.accept(view, items),
          max(max_words, :erts_debug.flat_size(items))
        )
    end
  end

  defp empty do
    %{
      cv: 1,
      seq: 0,
      source: nil,
      source_state: %{},
      cache: Cache.new(1_048_576),
      material_units_per_micro: 1,
      properties: nil,
      food_receipts: %{},
      protection: %{regions: %{}},
      refined: %{},
      refined_regions: %{},
      refined_region_owners: %{},
      refined_owners: %{},
      macro_owner_regions: %{},
      instances: %{},
      prefabs: %{},
      attachment_regions: %{},
      attachments: %{},
      aid_regions: %{},
      liquid_regions: %{},
      overlay: %{},
      overlay_regions: %{},
      region_bases: %{},
      decoded: %{},
      snapshots: MapSet.new(),
      damage: %{},
      epochs: %{},
      thermal: nil,
      pending_casts: %{},
      pages: %{unit_damage: %{}}
    }
  end
end
