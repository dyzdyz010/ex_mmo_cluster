defmodule SceneServer.Voxel.Reaction.TransformMaterialTest do
  # 功能完善 · 反应层 R2:ChunkProcess 应用 {:transform_material} 落 truth(冰→水),
  # from 校验显式 reject。DB-backed,沿 chunk_process_test 同款 setup。
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

  defp ice_id, do: MaterialCatalog.material_id(:ice)
  defp water_id, do: MaterialCatalog.material_id(:water)

  defp start_chunk_with_ice do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    {:ok, _storage} =
      ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(ice_id()),
        cell_version: 1
      )

    chunk
  end

  defp material_at(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    %NormalBlockData{material_id: id} = Storage.normal_block_at(storage, macro_index)
    id
  end

  defp ctx, do: %{region_id: 1, chunk_coord: {0, 0, 0}, kernel_id: :reaction, source_tick: 1}

  defp transform(macro_index, from_id, to_id) do
    {:transform_material,
     %{macro_index: macro_index, from_material_id: from_id, to_material_id: to_id, rule_id: :demo}}
  end

  test "冰转变为水:材料改、chunk_version bump" do
    chunk = start_chunk_with_ice()
    macro = Types.macro_index!({0, 0, 0})
    assert material_at(chunk, macro) == ice_id()
    before_version = ChunkProcess.debug_state(chunk).storage.chunk_version

    assert {:ok, _summary} =
             ChunkProcess.apply_field_effects(
               chunk,
               [transform(macro, ice_id(), water_id())],
               ctx()
             )

    assert material_at(chunk, macro) == water_id()
    assert ChunkProcess.debug_state(chunk).storage.chunk_version == before_version + 1
  end

  test "from 不匹配显式 reject,材料不变" do
    chunk = start_chunk_with_ice()
    macro = Types.macro_index!({0, 0, 0})
    before_version = ChunkProcess.debug_state(chunk).storage.chunk_version

    # 现材料是冰(4),但 effect 声称 from=stone(2)→ from 校验失败 reject。
    assert {:ok, _summary} =
             ChunkProcess.apply_field_effects(chunk, [transform(macro, 2, water_id())], ctx())

    assert material_at(chunk, macro) == ice_id()
    assert ChunkProcess.debug_state(chunk).storage.chunk_version == before_version
  end

  test "转变后订阅者收到快照(下行可见)" do
    chunk = start_chunk_with_ice()
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _payload} = ChunkProcess.subscribe(chunk, self(), request_id: 1)
    assert_receive {:voxel_chunk_snapshot_payload, _initial}

    ChunkProcess.apply_field_effects(chunk, [transform(macro, ice_id(), water_id())], ctx())

    # 相变后 push_snapshot_fallbacks → 订阅者收到新快照。
    assert_receive {:voxel_chunk_snapshot_payload, _updated}
  end
end
