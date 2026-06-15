defmodule SceneServer.Voxel.Reaction.DamageBlockTest do
  # 功能完善 · 反应层 R8:ChunkProcess 应用 {:damage_block} 落 truth(减 health,归零毁块),
  # 权威重校非实心/无耐久显式 reject。DB-backed,沿 transform_material_test 同款 setup。
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

  defp iron_id, do: MaterialCatalog.material_id(:iron)

  defp start_chunk_with_block(opts) do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    {:ok, _storage} =
      ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(iron_id(), opts),
        cell_version: 1
      )

    chunk
  end

  defp block_at(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.normal_block_at(storage, macro_index)
  end

  defp ctx,
    do: %{region_id: 1, chunk_coord: {0, 0, 0}, kernel_id: :electric_discharge, source_tick: 1}

  defp damage(macro_index, amount) do
    {:damage_block, %{macro_index: macro_index, amount: amount, source: :electric_discharge}}
  end

  test "减 health:健康块受击穿伤害降 health、chunk_version bump" do
    chunk = start_chunk_with_block(health: 60)
    macro = Types.macro_index!({0, 0, 0})
    before_version = ChunkProcess.debug_state(chunk).storage.chunk_version

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [damage(macro, 25)], ctx())

    assert summary.applied_count == 1
    assert %NormalBlockData{health: 35} = block_at(chunk, macro)
    assert ChunkProcess.debug_state(chunk).storage.chunk_version == before_version + 1
  end

  test "归零毁块:health 降至 ≤0 → clear macro cell(转 empty,destroyed?)" do
    chunk = start_chunk_with_block(health: 20)
    macro = Types.macro_index!({0, 0, 0})

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [damage(macro, 25)], ctx())

    assert summary.applied_count == 1
    assert [%{status: :applied, action: :damage_block, destroyed?: true}] = summary.results
    # 毁块后该 cell 非实心(empty)。
    refute match?(%NormalBlockData{}, block_at(chunk, macro))
  end

  test "health=0 块显式 reject(无耐久不可电毁),不变、不 bump" do
    chunk = start_chunk_with_block([])
    macro = Types.macro_index!({0, 0, 0})
    before_version = ChunkProcess.debug_state(chunk).storage.chunk_version

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [damage(macro, 25)], ctx())

    assert summary.rejected_count == 1
    assert [%{status: :rejected, reason: :damage_target_no_health}] = summary.results
    assert %NormalBlockData{health: 0} = block_at(chunk, macro)
    assert ChunkProcess.debug_state(chunk).storage.chunk_version == before_version
  end

  test "非实心(空)cell 显式 reject" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({5, 0, 0})

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [damage(macro, 25)], ctx())

    assert summary.rejected_count == 1
    assert [%{status: :rejected, reason: :damage_target_not_solid}] = summary.results
  end

  test "非法 amount(0/负)显式 reject" do
    chunk = start_chunk_with_block(health: 60)
    macro = Types.macro_index!({0, 0, 0})

    assert {:ok, summary} = ChunkProcess.apply_field_effects(chunk, [damage(macro, 0)], ctx())

    assert summary.rejected_count == 1
    assert [%{status: :rejected, reason: :invalid_damage_amount}] = summary.results
    assert %NormalBlockData{health: 60} = block_at(chunk, macro)
  end

  test "毁块后订阅者收到快照(下行可见)" do
    chunk = start_chunk_with_block(health: 10)
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _payload} = ChunkProcess.subscribe(chunk, self(), request_id: 1)
    assert_receive {:voxel_chunk_snapshot_payload, _initial}

    ChunkProcess.apply_field_effects(chunk, [damage(macro, 25)], ctx())

    assert_receive {:voxel_chunk_snapshot_payload, _updated}
  end
end
