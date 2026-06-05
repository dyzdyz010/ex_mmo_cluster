# Test-only simulator modules at the top of the file so they live at the
# top level (`Elixir.SuccessSimulator` / `Elixir.FailSimulator`) and are
# compiled + loaded before any test body references them.

defmodule SceneServer.Voxel.SimulationTickTest.SuccessSimulator do
  @behaviour SceneServer.Voxel.Simulator

  @impl true
  def simulator_id, do: :test_success

  @impl true
  def tick(state, dirty, env) do
    case :persistent_term.get(
           {SceneServer.Voxel.SimulationTickTest, :tick_observer},
           nil
         ) do
      pid when is_pid(pid) ->
        send(pid, {:simulator_tick_called, simulator_id(), dirty, env})

      _ ->
        :ok
    end

    next_state =
      case state do
        nil -> %{calls: 1}
        %{calls: n} -> %{calls: n + 1}
      end

    {:ok, next_state, %{cells_updated: 1, env_delta: nil}}
  end
end

defmodule SceneServer.Voxel.SimulationTickTest.FailSimulator do
  @behaviour SceneServer.Voxel.Simulator

  @impl true
  def simulator_id, do: :test_fail

  @impl true
  def tick(_state, _dirty, _env), do: {:error, :test_failure}
end

defmodule SceneServer.Voxel.SimulationTickTest do
  # Phase 5.E: ChunkProcess 通过 DataService.Voxel.ChunkSnapshotStore 走 PG。
  # 与 chunk_process_test.exs 保持同等纪律：sync execution + 每测试清理。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.SimulationTick
  alias SceneServer.Voxel.SimulationTickTest.FailSimulator
  alias SceneServer.Voxel.SimulationTickTest.SuccessSimulator
  alias SceneServer.Voxel.Storage

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset(WriteTokenStore)

    # 阶段3.1：每个测试用隔离的 chunk 进程身份注册表。ChunkProcess 经 via-tuple
    # 注册进它指定的 :chunk_registry；不隔离时所有测试都注册进全局单例的同一身份
    # 槽位（如 {1, {0,0,0}}），跨测试的拆除竞态 / 同测试内复用同身份会撞
    # {:already_started}。隔离后每个进程身份只属于本测试，互不串扰。
    %{chunk_registry: start_isolated_chunk_registry!()}
  end

  describe "SimulationTick state helpers" do
    test "new/1 with empty simulators yields tick_seq=0 + any_simulator? false" do
      state = SimulationTick.new([])
      assert state.tick_seq == 0
      refute SimulationTick.any_simulator?(state)
      assert SimulationTick.simulator_ids(state) == []
    end

    test "new/1 with simulators initializes per-simulator state to nil" do
      state = SimulationTick.new([SuccessSimulator, FailSimulator])
      assert SimulationTick.any_simulator?(state)
      assert SimulationTick.simulator_ids(state) == [:test_success, :test_fail]
      assert Map.fetch!(state.simulator_states, :test_success) == nil
      assert Map.fetch!(state.simulator_states, :test_fail) == nil
    end
  end

  describe "DirtyMacroBounds helpers" do
    test "empty?/1 reports half-open empty" do
      assert DirtyMacroBounds.empty?(DirtyMacroBounds.empty())
    end

    test "add_macro/3 with empty bounds covers exactly one macro cell" do
      bounds =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro({2, 3, 4}, DirtyMacroBounds.reason_attribute_write())

      assert bounds.min_macro == {2, 3, 4}
      assert bounds.max_macro == {3, 4, 5}
      refute DirtyMacroBounds.empty?(bounds)
      assert DirtyMacroBounds.reason_set?(bounds, DirtyMacroBounds.reason_attribute_write())
    end

    test "add_macro/3 expands min/max + OR-merges reason flags" do
      bounds =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro({1, 1, 1}, DirtyMacroBounds.reason_attribute_write())
        |> DirtyMacroBounds.add_macro({5, 5, 5}, DirtyMacroBounds.reason_cross_chunk_boundary())

      assert bounds.min_macro == {1, 1, 1}
      assert bounds.max_macro == {6, 6, 6}
      assert DirtyMacroBounds.reason_set?(bounds, DirtyMacroBounds.reason_attribute_write())
      assert DirtyMacroBounds.reason_set?(bounds, DirtyMacroBounds.reason_cross_chunk_boundary())
    end

    test "clear/1 returns empty bounds" do
      bounds =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(0, DirtyMacroBounds.reason_attribute_write())

      assert DirtyMacroBounds.empty?(DirtyMacroBounds.clear(bounds))
    end
  end

  describe "Storage mutation marks dirty bounds" do
    test "put_solid_block marks the macro cell dirty with reason_attribute_write" do
      storage = Storage.empty(1, {0, 0, 0})
      assert DirtyMacroBounds.empty?(storage.dirty_bounds)

      next = Storage.put_solid_block(storage, {2, 0, 0}, NormalBlockData.new(7))

      refute DirtyMacroBounds.empty?(next.dirty_bounds)

      assert DirtyMacroBounds.reason_set?(
               next.dirty_bounds,
               DirtyMacroBounds.reason_attribute_write()
             )

      assert next.dirty_bounds.min_macro == {2, 0, 0}
      assert next.dirty_bounds.max_macro == {3, 1, 1}
    end

    test "Storage.clear_dirty_bounds wipes the dirty window" do
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_solid_block({0, 0, 0}, NormalBlockData.new(2))

      refute DirtyMacroBounds.empty?(storage.dirty_bounds)
      cleared = Storage.clear_dirty_bounds(storage)
      assert DirtyMacroBounds.empty?(cleared.dirty_bounds)
    end
  end

  describe "SimulationTick.output_hash determinism" do
    test "same inputs produce same hash" do
      dirty =
        DirtyMacroBounds.empty()
        |> DirtyMacroBounds.add_macro(0, DirtyMacroBounds.reason_attribute_write())

      h1 = SimulationTick.output_hash(0xCAFE_BABE_DEAD_BEEF, dirty, 7, [:sim_a, :sim_b])
      h2 = SimulationTick.output_hash(0xCAFE_BABE_DEAD_BEEF, dirty, 7, [:sim_a, :sim_b])
      assert h1 == h2
    end

    test "different dirty bounds yield different hash" do
      base = DirtyMacroBounds.add_macro(DirtyMacroBounds.empty(), 0, 0x01)
      grown = DirtyMacroBounds.add_macro(base, 5, 0x01)

      h_base = SimulationTick.output_hash(0, base, 1, [:sim_a])
      h_grown = SimulationTick.output_hash(0, grown, 1, [:sim_a])
      refute h_base == h_grown
    end

    test "different tick_seq yield different hash" do
      dirty = DirtyMacroBounds.add_macro(DirtyMacroBounds.empty(), 0, 0x01)

      assert SimulationTick.output_hash(0, dirty, 1, [:sim_a]) !=
               SimulationTick.output_hash(0, dirty, 2, [:sim_a])
    end

    test "different simulator id list yields different hash" do
      dirty = DirtyMacroBounds.add_macro(DirtyMacroBounds.empty(), 0, 0x01)

      assert SimulationTick.output_hash(0, dirty, 1, [:sim_a]) !=
               SimulationTick.output_hash(0, dirty, 1, [:sim_b])
    end
  end

  describe "ChunkProcess simulation tick scheduling" do
    test "ChunkProcess starts with tick_seq=0 + no simulators by default", %{
      chunk_registry: registry
    } do
      chunk =
        start_chunk!([logical_scene_id: 1, chunk_coord: {0, 0, 0}], registry)

      sim_state = simulation_tick_state(chunk)
      assert sim_state.tick_seq == 0
      assert sim_state.simulators == []
      refute SimulationTick.any_simulator?(sim_state)
    end

    test "default empty simulators path → tick skipped, dirty_bounds untouched", %{
      chunk_registry: registry
    } do
      chunk =
        start_chunk!([logical_scene_id: 1, chunk_coord: {0, 0, 0}], registry)

      # 写入一个 cell → dirty 应该被打上
      {:ok, _} =
        ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(7))

      refute DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)

      # 等到下一个 tick 触发(100ms),应该 skip (no_simulators) 且 dirty 保留
      Process.sleep(150)

      assert DirtyMacroBounds.reason_set?(
               debug_storage(chunk).dirty_bounds,
               DirtyMacroBounds.reason_attribute_write()
             )

      assert simulation_tick_state(chunk).tick_seq == 0
    end

    test "no_dirty skip path → tick increments not, dirty stays empty", %{
      chunk_registry: registry
    } do
      chunk =
        start_chunk!(
          [
            logical_scene_id: 1,
            chunk_coord: {0, 0, 0},
            lease: valid_lease(),
            simulators: [SuccessSimulator]
          ],
          registry
        )

      assert DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)
      Process.sleep(150)
      assert DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)
      assert simulation_tick_state(chunk).tick_seq == 0
    end

    test "dirty + simulator → tick runs, dirty cleared, tick_seq increments", %{
      chunk_registry: registry
    } do
      :persistent_term.put({__MODULE__, :tick_observer}, self())

      chunk =
        start_chunk!(
          [
            logical_scene_id: 1,
            chunk_coord: {0, 0, 0},
            lease: valid_lease(),
            simulators: [SuccessSimulator]
          ],
          registry
        )

      _ = ChunkProcess.put_solid_block(chunk, {3, 4, 5}, NormalBlockData.new(7))
      refute DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)

      assert_receive {:simulator_tick_called, :test_success, observed_dirty, observed_env}, 1_000

      # simulator 看到的 dirty 含本次写入
      assert observed_dirty.min_macro == {3, 4, 5}
      assert observed_dirty.max_macro == {4, 5, 6}

      assert DirtyMacroBounds.reason_set?(
               observed_dirty,
               DirtyMacroBounds.reason_attribute_write()
             )

      assert observed_env.chunk_coord == {0, 0, 0}
      assert observed_env.logical_scene_id == 1
      assert is_struct(observed_env.storage, Storage)

      # tick 完成后 dirty 应当被清空
      assert_eventually(fn ->
        DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)
      end)

      assert_eventually(fn ->
        simulation_tick_state(chunk).tick_seq >= 1
      end)
    after
      :persistent_term.erase({__MODULE__, :tick_observer})
    end

    test "lease_stale skip path → expired lease causes :lease_stale skip", %{
      chunk_registry: registry
    } do
      expired_lease = %{
        logical_scene_id: 1,
        region_id: 10,
        lease_id: 100,
        owner_scene_instance_ref: 1_000,
        owner_epoch: 1,
        bounds_chunk_min: {0, 0, 0},
        bounds_chunk_max: {4, 4, 4},
        expires_at_ms: System.system_time(:millisecond) - 60_000
      }

      chunk =
        start_chunk!(
          [
            logical_scene_id: 1,
            chunk_coord: {0, 0, 0},
            lease: expired_lease,
            simulators: [SuccessSimulator]
          ],
          registry
        )

      # 触发 dirty:lease 仍 stale,即使 dirty 也应该 skip
      # 注意:put_solid_block 是直接调,不走 lease 校验,但下方 tick 会校验 lease
      _ = ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(7))
      refute DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)

      Process.sleep(150)

      # 失败 + skip → dirty 保留,tick_seq 不增
      refute DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)
      assert simulation_tick_state(chunk).tick_seq == 0
    end

    test "simulator failure isolation → dirty cleared, tick_seq increments, other simulator runs",
         %{chunk_registry: registry} do
      :persistent_term.put({__MODULE__, :tick_observer}, self())

      chunk =
        start_chunk!(
          [
            logical_scene_id: 1,
            chunk_coord: {0, 0, 0},
            lease: valid_lease(),
            simulators: [FailSimulator, SuccessSimulator]
          ],
          registry
        )

      _ = ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(7))

      # success simulator 仍应该被调
      assert_receive {:simulator_tick_called, :test_success, _, _}, 1_000

      # dirty 在 tick 后清空(Phase 5.E 简化策略:失败不阻塞清理)
      assert_eventually(fn ->
        DirtyMacroBounds.empty?(debug_storage(chunk).dirty_bounds)
      end)

      assert_eventually(fn ->
        simulation_tick_state(chunk).tick_seq >= 1
      end)
    after
      :persistent_term.erase({__MODULE__, :tick_observer})
    end

    test "output_hash determinism across runs with same input", %{chunk_registry: registry} do
      :persistent_term.put({__MODULE__, :tick_observer}, self())

      # 两个独立 chunk,相同初始 storage + 相同写入 + 相同 simulator → 相同 output_hash。
      # 阶段3.1：两个进程是**同一身份** {1, {0,0,0}}，注册表 :unique 保证同一表里只能有
      # 一个权威。这里它们代表"同一身份在两次独立运行中"的对照，因此分别注册进**两张**
      # 隔离注册表，使二者得以共存做确定性对照（而非互相去重）。
      registry2 = start_isolated_chunk_registry!()

      chunk1 =
        start_chunk!(
          [
            logical_scene_id: 1,
            chunk_coord: {0, 0, 0},
            lease: valid_lease(),
            simulators: [SuccessSimulator]
          ],
          registry,
          id: :chunk1
        )

      chunk2 =
        start_chunk!(
          [
            logical_scene_id: 1,
            chunk_coord: {0, 0, 0},
            lease: valid_lease(),
            simulators: [SuccessSimulator]
          ],
          registry2,
          id: :chunk2
        )

      _ = ChunkProcess.put_solid_block(chunk1, {0, 0, 0}, NormalBlockData.new(7))
      _ = ChunkProcess.put_solid_block(chunk2, {0, 0, 0}, NormalBlockData.new(7))

      assert_eventually(fn ->
        simulation_tick_state(chunk1).tick_seq >= 1 and
          simulation_tick_state(chunk2).tick_seq >= 1
      end)

      h1 = simulation_tick_state(chunk1).last_output_hash
      h2 = simulation_tick_state(chunk2).last_output_hash
      assert h1 == h2
      assert h1 != 0
    after
      :persistent_term.erase({__MODULE__, :tick_observer})
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp start_isolated_chunk_registry! do
    name = :"simulation_tick_test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: name}, id: {:registry, name})
    name
  end

  # 在隔离注册表里 start_supervised 一个 ChunkProcess，避免全局单例身份槽位冲突。
  defp start_chunk!(chunk_opts, registry, supervised_opts \\ []) do
    start_supervised!(
      {ChunkProcess, Keyword.put(chunk_opts, :chunk_registry, registry)},
      supervised_opts
    )
  end

  defp valid_lease do
    %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }
  end

  defp simulation_tick_state(chunk) do
    :sys.get_state(chunk).simulation_tick
  end

  defp debug_storage(chunk) do
    :sys.get_state(chunk).storage
  end

  defp assert_eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    assert_eventually(fun, deadline, timeout_ms)
  end

  defp assert_eventually(fun, deadline, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true within #{timeout_ms}ms")
      else
        Process.sleep(20)
        assert_eventually(fun, deadline, timeout_ms)
      end
    end
  end
end
