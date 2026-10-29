defmodule VoxelRegion.CollisionCompactTest do
  @moduledoc """
  只测试：合法紧凑槽的碰撞投影不得为判空重复解码首槽。

  纯输入与真实投影，不启动 World／数据库；单 MFA 只记录独立测试进程的调用次数。
  完整字节期望来自两个阻挡槽的手算位置，原 map 路径另作直接兼容对照。
  """
  use ExUnit.Case, async: false

  alias VoxelRegion.{CollisionSource, RefinedSlots}
  alias VoxelRegion.World.{Canonical, Observation}
  alias MmoContracts.Voxel.Payload

  test "空值不细化，非空紧凑槽各只解码一次且保持完整 XYZ 占用" do
    coord = {-2, 2, -3}
    macro = {-31, 33, -47}
    slots = %{0 => {11, {7, 0}}, 9 => {21, {7, 0}}, 511 => {12, {8, 1}}}
    compact = RefinedSlots.from_map(slots)
    empty = RefinedSlots.empty()
    reader = fn values -> fn cell -> {0, if(cell == macro, do: values, else: %{})} end end

    expected = CollisionSource.capture(coord, reader.(slots))
    assert expected.coord == coord
    assert expected.origin_m == {-32.0, 32.0, -48.0}
    assert expected.n == 128
    assert expected.scale_m == 0.125
    first = 8 + 128 * (8 + 128 * 8)
    last = 15 + 128 * (15 + 128 * 15)
    assert expected.cells == IO.iodata_to_binary([
      :binary.copy(<<0>>, first), <<1>>, :binary.copy(<<0>>, last - first - 1),
      <<1>>, :binary.copy(<<0>>, 128 * 128 * 128 - last - 1)
    ])

    {{actual, plain}, reads} = count_slot_reads(fn ->
      {CollisionSource.capture(coord, reader.(compact)),
       CollisionSource.capture(coord, fn _ -> {0, empty} end)}
    end)
    assert actual == expected
    assert plain == CollisionSource.capture(coord, fn _ -> {0, %{}} end)
    assert plain.n == 16
    assert plain.cells == :binary.copy(<<0>>, 16 * 16 * 16)
    assert reads == map_size(slots)
  end

  @tag :changed_projection
  test "真实宏编辑只为 new 构造完整 chunk，未改槽不再为 old 全量解码" do
    changed = {-30, 34, -46}
    before = collision_state() |> Canonical.put_refined({-31, 33, -47}, %{0 => {11, {7, 0}}, 511 => {12, {7, 0}}})
    after_state = put_in(before.overlay, %{{0, changed} => {11, MmoContracts.Voxel.Skins.uniform(11)}})
      |> Map.put(:seq, 1)
    {{:ok, [chunk]}, reads} = count_slot_reads(fn ->
      Observation.canonical_changes(before, after_state, [{0, changed}])
    end)
    assert chunk.coord == {-2, 2, -3}
    assert chunk.n == 128
    assert :binary.at(chunk.cells, 16 + 128 * (16 + 128 * 16)) == 1
    assert :binary.at(chunk.cells, 23 + 128 * (23 + 128 * 23)) == 1
    assert :binary.at(chunk.cells, 8 + 128 * (8 + 128 * 8)) == 1
    assert :binary.at(chunk.cells, 15 + 128 * (15 + 128 * 15)) == 1
    assert Enum.sum(:binary.bin_to_list(chunk.cells)) == 514
    assert reads == 2
  end

  @tag :changed_projection
  test "同阻挡材质的真实提交不解码未改槽或物化完整 chunk" do
    changed = {-30, 34, -46}
    before = collision_state() |> Canonical.put_refined({-31, 33, -47}, %{0 => {11, {7, 0}}, 511 => {12, {7, 0}}})
      |> Map.put(:overlay, %{{0, changed} => {11, MmoContracts.Voxel.Skins.uniform(11)}})
    after_state = put_in(before.overlay, %{{0, changed} => {12, MmoContracts.Voxel.Skins.uniform(12)}})
      |> Map.put(:seq, 1)
    {{:ok, chunks}, reads} = count_slot_reads(fn ->
      Observation.canonical_changes(before, after_state, [{0, changed}])
    end)
    assert chunks == []
    assert reads == 0
  end

  test "首末非空槽保持分辨率变化，另有未改细化格或同笔迁移时不误发等价占用" do
    cell = {-31, 33, -47}
    other = {-30, 34, -46}
    solid = {11, %{}}
    refined_solid = {11, %{0 => {11, {7, 0}}}}
    plain = %{cell => solid}
    refined = %{cell => refined_solid}

    first = assert_projection(plain, refined, [cell], true)
    assert first.n == 128 and first.scale_m == 0.125
    last = assert_projection(refined, plain, [cell], true)
    assert last.n == 16 and last.scale_m == 1.0
    assert Enum.sum(:binary.bin_to_list(first.cells)) == 512
    assert Enum.sum(:binary.bin_to_list(last.cells)) == 1

    assert_projection(Map.put(plain, other, refined_solid), Map.put(refined, other, refined_solid), [cell], false)
    assert_projection(%{cell => refined_solid, other => solid}, %{cell => solid, other => refined_solid}, [cell, other], false)
  end

  test "实际覆盖而非槽结构决定相等，全512覆盖可屏蔽底材且允许显式空气" do
    cell = {-31, 33, -47}
    full_solid = RefinedSlots.from_map(Map.new(0..511, &{&1, {11, {7, 0}}}))
    full_air = Map.new(0..511, &{&1, {0, {0, 0}}})
    assert_projection(%{cell => {0, full_solid}}, %{cell => {12, full_solid}}, [cell], false)
    assert_projection(%{cell => {11, full_air}}, %{cell => {12, full_air}}, [cell], false)
    assert_projection(%{cell => {11, full_air}}, %{cell => {0, %{0 => {0, {0, 0}}}}}, [cell], false)

    old_slots = RefinedSlots.from_map(%{511 => {11, {7, 0}}})
    new_slots = RefinedSlots.from_map(%{511 => {12, {8, 1}}})
    assert_projection(%{cell => {0, old_slots}}, %{cell => {0, new_slots}}, [cell], false)
    hollowed = assert_projection(%{cell => {11, full_solid}}, %{cell => {11, full_air}}, [cell], true)
    assert hollowed.cells == :binary.copy(<<0>>, 128 ** 3)
  end

  test "有限数量同层不发占用，跨层按现 phase_slots 投影，水仍不阻挡" do
    cell = {-31, 33, -47}
    before = collision_state() |> Map.put(:material_units_per_micro, 1)
      |> Map.put(:overlay, %{{0, cell} => {20, MmoContracts.Voxel.Skins.uniform(20)}})
      |> Map.put(:liquid_units, %{cell => 17})
    same_layer = %{before | seq: 1, liquid_units: %{cell => 64}}
    next_layer = %{before | seq: 1, liquid_units: %{cell => 65}}
    assert {:ok, []} = Observation.canonical_changes(before, same_layer, [{0, cell}])
    assert {:ok, [chunk]} = Observation.canonical_changes(before, next_layer, [{0, cell}])
    assert chunk.n == 128
    assert Enum.sum(:binary.bin_to_list(chunk.cells)) == 128
    assert :binary.at(chunk.cells, 8 + 128 * (9 + 128 * 8)) == 1
    assert :binary.at(chunk.cells, 8 + 128 * (10 + 128 * 8)) == 0
    water = %{before | overlay: %{{0, cell} => {21, MmoContracts.Voxel.Skins.uniform(21)}}}
    assert {:ok, []} = Observation.canonical_changes(water, %{water | liquid_units: %{cell => 65}}, [{0, cell}])
  end

  test "变化集合去重、完整XYZ与订阅过滤保持，缺任一来源显式失败" do
    left = {-31, 33, -47}
    right = {-15, 34, -46}
    outside = {0, 34, -46}
    before = collision_state()
    next = %{before | seq: 1, overlay: Map.new([left, right, outside], &{{0, &1}, {11, MmoContracts.Voxel.Skins.uniform(11)}})}
    assert {:ok, [a, b]} = Observation.canonical_changes(before, next, Enum.map([right, left, outside, left], &{0, &1}))
    assert [a.coord, b.coord] == [{-2, 2, -3}, {-1, 2, -3}]
    assert a.n == 16 and b.n == 16
    assert Enum.sum(:binary.bin_to_list(a.cells)) == 1
    assert Enum.sum(:binary.bin_to_list(b.cells)) == 1

    missing = before |> Map.put(:decoded, %{}) |> Map.put(:source, __MODULE__.MissingSource) |> Map.put(:source_state, nil)
    assert {:error, :canonical_incomplete} = Observation.canonical_changes(missing, next, [{0, left}])
    assert {:error, :canonical_incomplete} = Observation.canonical_changes(before, missing, [{0, left}])
    assert {:ok, []} = Observation.canonical_changes(%{missing | canonical_subs: %{}}, missing, [{0, left}])
  end

  defmodule MissingSource do
    @moduledoc "只测试：来源失败必须保留，不能把未加载的几何当空气。"
    def read(_, _, _), do: {:error, :missing}
  end

  defp assert_projection(before, after_state, changed, different?) do
    coord = {-2, 2, -3}
    old_at = &Map.get(before, &1, {0, %{}})
    new_at = &Map.get(after_state, &1, {0, %{}})
    old = CollisionSource.capture(coord, old_at)
    new = CollisionSource.capture(coord, new_at)
    assert (old.cells != new.cells) == different?
    result = CollisionSource.capture_changed(coord, old_at, new_at, changed)
    assert result == if(different?, do: new, else: nil)
    result
  end

  # 只测试：纯状态函数的合法已接纳输入，不注入运行中的 World。
  defp collision_state do
    region = {-1, 0, -1}
    payload = %Payload{region: region, cells: :binary.copy(<<0, 0>>, Payload.extent() ** 3)}
    %{seq: 0, canonical_subs: %{self() => {{-1, 0, -1}, {0, 1, 0}}}, replica_subs: %{},
      overlay: %{}, decoded: %{{0, region} => payload}, region_bases: %{},
      refined: %{}, refined_owners: %{}, refined_regions: %{},
      liquid_units: %{}, material_units_per_micro: 4096}
  end

  # 只测试：单个实际记录解码 MFA，arity-only；不采参数、返回值、堆或运行时 World。
  defp count_slot_reads(action) do
    mfa = {RefinedSlots, :row, 2}
    assert {:module, RefinedSlots} = Code.ensure_loaded(RefinedSlots)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:collision_compact_reads, self(), [])

    try do
      assert :trace.function(session, mfa, true, [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("碰撞纯投影没有完成")
      end
      marker = :trace.delivered(session, worker)
      {result, drain_reads(worker, mfa, marker, 0)}
    after
      :trace.process(session, worker, false, [:call, :arity])
      assert :trace.function(session, mfa, false, [:local]) == 1
      assert :trace.info(session, worker, :flags) == {:flags, []}
      assert :trace.info(session, mfa, :traced) == {:traced, false}
      marker = :trace.delivered(session, worker)
      assert drain_reads(worker, mfa, marker, 0) == 0
      assert :trace.session_destroy(session)
      assert :trace.session_info(worker) == []
      assert :trace.session_info(:all) == sessions
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  defp drain_reads(worker, mfa, marker, reads) do
    receive do
      {:trace, ^worker, :call, ^mfa} -> drain_reads(worker, mfa, marker, reads + 1)
      {:trace_delivered, ^worker, ^marker} -> reads
    after
      1_000 -> flunk("碰撞记录读取 trace 的投递屏障未完成")
    end
  end
end
