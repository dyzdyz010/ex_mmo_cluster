defmodule SceneServer.Voxel.Reaction.ReactionKernelE2ETest do
  # 功能完善 · 反应层 R3:端到端闭环——温度物理(写 truth)→ ReactionKernel 读 truth → Engine 规则
  # → transform_material → SystemActor 锁存 → ChunkProcess 落 truth → 快照下行。冰熔化 demo。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, FieldTickWorker, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.delete_env(:scene_server, :cli_observe_log)

    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    SceneServer.TestVoxelRuntime.ensure_started!()
    # 节点级 SystemActor 锁存跨测试持久:清,避免 latch_key 残留致提交被跳过。
    SystemActor.reset()

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    :ok
  end

  defp ice_id, do: MaterialCatalog.material_id(:ice)
  defp water_id, do: MaterialCatalog.material_id(:water)

  defp material_at(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    %NormalBlockData{material_id: id} = Storage.normal_block_at(storage, macro_index)
    id
  end

  defp set_temperature(chunk, macro_index, celsius) do
    {:ok, _} =
      ChunkProcess.write_temperature_attribute(chunk, %{
        macro_index: macro_index,
        target_temperature_celsius: celsius
      })
  end

  defp run_reaction_tick(chunk, region_id, max_ticks \\ 1) do
    region =
      FieldRegion.new(%{
        region_id: region_id,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}],
        max_ticks: max_ticks
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 1
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "冷冰(-10℃)反应 tick 不熔化(阈值门控)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(ice_id()))
    set_temperature(chunk, macro, -10.0)

    run_reaction_tick(chunk, 9001)

    assert material_at(chunk, macro) == ice_id()
  end

  test "加热冰(+5℃ ≥ melting_point 0℃)→ 反应 tick 熔化为水(闭环)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(ice_id()))

    # 先冷,确认未熔;再加热,确认熔化——证明温度物理 → 反应 → 材料转变的因果闭环。
    set_temperature(chunk, macro, -10.0)
    run_reaction_tick(chunk, 9002)
    assert material_at(chunk, macro) == ice_id()

    set_temperature(chunk, macro, 5.0)
    run_reaction_tick(chunk, 9003)
    assert material_at(chunk, macro) == water_id()
  end

  test "R4 反向:冷却水(-10℃ < freezing_point)→ 反应 tick 冻为冰(同 kernel 任意规则)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(water_id()))
    set_temperature(chunk, macro, -10.0)

    run_reaction_tick(chunk, 9101)

    assert material_at(chunk, macro) == ice_id()
  end

  test "熔化后订阅者收到下行快照(客户端可见)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(ice_id()))
    set_temperature(chunk, macro, 5.0)

    {:ok, _payload} = ChunkProcess.subscribe(chunk, self(), request_id: 1)
    assert_receive {:voxel_chunk_snapshot_payload, _initial}

    run_reaction_tick(chunk, 9004)

    assert material_at(chunk, macro) == water_id()
    assert_receive {:voxel_chunk_snapshot_payload, _after_melt}
  end
end
