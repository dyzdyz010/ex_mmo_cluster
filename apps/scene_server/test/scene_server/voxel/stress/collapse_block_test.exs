defmodule SceneServer.Voxel.Stress.CollapseBlockTest do
  # 力学应力:ChunkProcess 应用 {:collapse_block} 落 truth(无视 health 清掉实心 cell →
  # ChunkDelta,客户端渲 debris)。非实心显式 reject(幂等)。DB-backed,沿 damage_block_test
  # 同款 setup。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset()

    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.delete_env(:scene_server, :cli_observe_log)

    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    SceneServer.TestVoxelRuntime.ensure_started!()

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    :ok
  end

  defp stone_id, do: MaterialCatalog.material_id(:stone)

  defp start_chunk_with_block(opts) do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    {:ok, _storage} =
      ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(stone_id(), opts),
        cell_version: 1
      )

    chunk
  end

  defp block_at(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.normal_block_at(storage, macro_index)
  end

  defp ctx,
    do: %{region_id: 1, chunk_coord: {0, 0, 0}, kernel_id: :structural_stress, source_tick: 1}

  defp collapse(macro_index) do
    {:collapse_block, %{macro_index: macro_index, source: :structural_collapse}}
  end

  test "坍塌实心块:无视 health 清掉 cell(转 empty,destroyed?),chunk_version bump" do
    # health 满(60)也照坍——坍塌不是伤害,是失支撑。
    chunk = start_chunk_with_block(health: 60)
    macro = Types.macro_index!({0, 0, 0})
    before_version = ChunkProcess.debug_state(chunk).storage.chunk_version

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [collapse(macro)], ctx())

    assert summary.applied_count == 1
    assert [%{status: :applied, action: :collapse_block, destroyed?: true}] = summary.results
    # 坍塌后该 cell 非实心(empty)。
    refute match?(%NormalBlockData{}, block_at(chunk, macro))
    assert ChunkProcess.debug_state(chunk).storage.chunk_version > before_version
  end

  test "非实心(空)cell 显式 reject(幂等)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({5, 0, 0})
    before_version = ChunkProcess.debug_state(chunk).storage.chunk_version

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [collapse(macro)], ctx())

    assert summary.rejected_count == 1

    assert [%{status: :rejected, action: :collapse_block, reason: :collapse_target_not_solid}] =
             summary.results

    assert ChunkProcess.debug_state(chunk).storage.chunk_version == before_version
  end

  test "坍塌后订阅者收到快照(debris 下行可见)" do
    chunk = start_chunk_with_block(health: 10)
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _payload} = ChunkProcess.subscribe(chunk, self(), request_id: 1)
    assert_receive {:voxel_chunk_snapshot_payload, _initial}

    ChunkProcess.apply_field_effects(chunk, [collapse(macro)], ctx())

    assert_receive {:voxel_chunk_snapshot_payload, _updated}
  end
end
