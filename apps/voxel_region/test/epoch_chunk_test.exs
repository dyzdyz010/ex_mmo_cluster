defmodule VoxelRegion.EpochChunkTest do
  @moduledoc "只测试：自然chunk世代紧凑表示、真实页接纳与有限File冷恢复；不启动数据库。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{EpochChunk, OverlayLog, World}
  alias VoxelRegion.World.Pages

  test "旧epoch页接纳后不再保留逐格map，原坐标与完整u64字节保持" do
    coord = {-2, 3, -4}
    for count <- [1, 32, 33, 4096] do
      cells = Map.new(0..(count - 1), &{cell(coord, &1), if(&1 == 0, do: 0, else: 18_446_744_073_709_551_615)})
      {unit, value} = Pages.unit_value(stored(coord, cells))
      assert is_struct(value, EpochChunk)
      assert EpochChunk.size(value) == count
      assert Map.new(value) == cells
      assert byte_size(value.data) == count * 10
      assert :binary.referenced_byte_size(value.data) == byte_size(value.data)
      if count == 4096, do: assert(:erts_debug.flat_size(value) * 4 < :erts_debug.flat_size(cells))
      assert Pages.decode(Pages.row(unit, value).payload) == cells
      assert Pages.unit_value(Pages.row(unit, value)) == {unit, value}
    end
  end

  test "稀疏洞与显式0不同，负XYZ和窗口按完整三维定位" do
    a = {-17, 48, -64}
    b = {-32, 63, -49}
    far = {-17, 128, -64}
    values = EpochChunk.merge(%{}, %{a => 0, b => 9, far => 11})
    assert EpochChunk.get(values, a, :absent) == 0
    assert EpochChunk.get(values, {-18, 48, -64}, :absent) == :absent
    assert EpochChunk.get(values, {0, 0, 0}, :absent) == :absent
    assert EpochChunk.flat(values, {{-1, 0, -1}, {0, 1, 0}}) == %{a => 0, b => 9}
    assert EpochChunk.flat(values) == %{a => 0, b => 9, far => 11}
    assert Enum.to_list(EpochChunk.empty({0, 0, 0})) == []
  end

  test "同chunk批量覆盖只构造一次，旧值与其他chunk保持且新旧记录有序合并" do
    coord = {-2, 3, -4}
    other = cell({3, -2, 4}, 4095)
    old_cells = %{cell(coord, 0) => 1, cell(coord, 2) => 2, cell(coord, 4095) => 3, other => 8}
    before = EpochChunk.merge(%{}, old_cells)
    delta = %{cell(coord, 0) => 11, cell(coord, 1) => 12, cell(coord, 2) => 0, cell(coord, 2048) => 14}
    {after_state, builds} = count_builds(fn -> EpochChunk.merge(before, delta) end)
    assert builds == 1
    assert EpochChunk.flat(before) == old_cells
    assert EpochChunk.flat(after_state) == Map.merge(old_cells, delta)
    assert Map.fetch!(before, {3, -2, 4}) == Map.fetch!(after_state, {3, -2, 4})
    for {key, expected} <- Map.merge(old_cells, delta), do: assert(EpochChunk.get(after_state, key) == expected)
  end

  test "旧持久输入在唯一接纳边界拒绝越界世代、错chunk与伪造struct" do
    coord = {0, 0, 0}
    for bad <- [%{{0, 0, 0} => -1}, %{{0, 0, 0} => 18_446_744_073_709_551_616},
                %{{0, 0, 0} => 1.0}, %{{0.0, 0, 0} => 1}, %{{16, 0, 0} => 1},
                %{__struct__: EpochChunk, coord: coord, count: 1, data: <<>>}] do
      assert_raise ArgumentError, fn -> Pages.unit_value(stored(coord, bad)) end
    end
    for bad <- [%{{0, 0, 0} => -1}, %{{0, 0, 0} => 18_446_744_073_709_551_616}] do
      assert_raise ArgumentError, fn -> EpochChunk.merge(%{}, bad) end
    end
  end

  test "作者编辑经真实File发布、冷重启与后缀回放保持世代，换回同材质仍换身份" do
    root = Path.join(System.tmp_dir!(), "epoch_chunk_#{System.pid()}_#{System.unique_integer([:positive])}")
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [source: VoxelRegion.TestSupport.Source, log: OverlayLog.File, root: root,
      observer: self(), name: nil, prefab_catalog_path: prefabs, production_materials: [11, 19]]
    world = start_supervised!({World, opts})
    a = {-17, 2, -17}
    b = {17, 2, 17}
    box = {{-1, 0, -1}, {1, 1, 1}}
    assert :ok = World.set_simulation_windows(world, [box])
    assert {:ok, 1} = World.apply_edits(world, [{a, 11}, {b, 19}])
    assert World.simulation_snapshot(world, [], box).epochs == %{a => 1, b => 1}
    assert :ok = World.compact(world)
    %{rows: rows} = OverlayLog.File.read_pages(Path.join(root, "overlay.log"), [{0, {-1, 0, -1}}, {0, {0, 0, 0}}], [])
    stored_epochs = for %{segment: 6, payload: bytes} <- rows, row <- Pages.decode(bytes), into: %{}, do: row
    assert stored_epochs == %{a => 1, b => 1}
    # 这一笔不压实，重启必须从既有页接纳再回放合法epoch后缀。
    assert {:ok, 2} = World.apply_edits(world, [{a, 19}])
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert :ok = World.set_simulation_windows(world, [box])
    assert World.simulation_snapshot(world, [], box).epochs == %{a => 2, b => 1}
    assert {:ok, 3} = World.apply_edits(world, [{a, 11}])
    assert World.simulation_snapshot(world, [], box).epochs == %{a => 3, b => 1}
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert World.simulation_snapshot(world, [], box).epochs == %{a => 3, b => 1}
  end

  defp cell({x, y, z}, index), do: {x * 16 + rem(index, 16), y * 16 + rem(div(index, 16), 16), z * 16 + div(index, 256)}
  defp stored({x, y, z} = chunk, cells), do: %{level: 0,
    region: {Integer.floor_div(x, 4), Integer.floor_div(y, 4), Integer.floor_div(z, 4)}, segment: 6, chunk: chunk,
    payload: :erlang.term_to_binary(%{format: 1, value: cells}, compressed: 6)}

  defp count_builds(action) do
    mfa = {EpochChunk, :build, 2}
    assert {:module, EpochChunk} = Code.ensure_loaded(EpochChunk)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:epoch_chunk_builds, self(), [])
    try do
      assert :trace.function(session, mfa, true, [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("epoch批量构造没有完成")
      end
      marker = :trace.delivered(session, worker)
      {result, drain(worker, mfa, marker, 0)}
    after
      :trace.process(session, worker, false, [:call, :arity])
      assert :trace.function(session, mfa, false, [:local]) == 1
      assert :trace.info(session, worker, :flags) == {:flags, []}
      assert :trace.info(session, mfa, :traced) == {:traced, false}
      marker = :trace.delivered(session, worker)
      assert drain(worker, mfa, marker, 0) == 0
      assert :trace.session_destroy(session)
      assert :trace.session_info(worker) == []
      assert :trace.session_info(:all) == sessions
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  defp drain(worker, mfa, marker, count) do
    receive do
      {:trace, ^worker, :call, ^mfa} -> drain(worker, mfa, marker, count + 1)
      {:trace_delivered, ^worker, ^marker} -> count
    after
      1_000 -> flunk("epoch构造trace投递屏障未完成")
    end
  end
end
