defmodule SceneServer.Voxel.ChunkProcessSurfaceElementTest do
  # 形态轨 · 表面元件层 M3:经权威 ChunkProcess 放置/清除/查询表面元件,版本 bump + 重快照;
  # 零 occupancy 在活进程级别——贴面不计碰撞、不改宿主块。rust_decal 作 PoC(接 S4 皮相化:
  # 锈渍作面 truth,清氧化=clear)。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.SystemActor
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.SurfaceCatalog
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.Types

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.delete_env(:scene_server, :cli_observe_log)

    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    SceneServer.TestVoxelRuntime.ensure_started!()
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

  defp chunk_version(chunk), do: ChunkProcess.debug_state(chunk).storage.chunk_version

  defp occupied?(chunk, macro) do
    {:ok, result} =
      ChunkProcess.collision_query(chunk, %{samples: [%{macro: macro, micro_slot: 0}]})

    result.occupied_count > 0
  end

  test "放置 / 查询 / 清除表面元件 + 版本 bump" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({1, 0, 0})
    rust_decal = SurfaceCatalog.surface_type_id(:rust_decal)

    v0 = chunk_version(chunk)

    {:ok, _} =
      ChunkProcess.put_surface_element(chunk, %{
        macro_index: macro,
        face: :x_pos,
        surface_type_id: rust_decal
      })

    assert chunk_version(chunk) > v0
    el = ChunkProcess.surface_element_at(chunk, macro, :x_pos)
    assert el.surface_type_id == rust_decal
    assert ChunkProcess.surface_element_at(chunk, macro, :x_neg) == nil

    v1 = chunk_version(chunk)
    {:ok, _} = ChunkProcess.clear_surface_element(chunk, macro, :x_pos)
    assert chunk_version(chunk) > v1
    assert ChunkProcess.surface_element_at(chunk, macro, :x_pos) == nil
  end

  test "清除空面 = no-op,不 bump 版本" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({2, 0, 0})

    v0 = chunk_version(chunk)
    {:ok, _} = ChunkProcess.clear_surface_element(chunk, macro, :x_pos)
    assert chunk_version(chunk) == v0
  end

  test "零 occupancy:空宏格放贴面 → 碰撞仍不占用(贴面不阻挡)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({3, 0, 0})

    refute occupied?(chunk, macro)

    {:ok, _} =
      ChunkProcess.put_surface_element(chunk, %{
        macro_index: macro,
        face: :x_pos,
        surface_type_id: SurfaceCatalog.surface_type_id(:rust_decal)
      })

    refute occupied?(chunk, macro), "贴面零 occupancy,不应使空格变可碰撞"
  end

  test "实心块贴面:本体仍碰撞、材料不变(贴面与本体正交);清贴面后本体依旧" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({4, 0, 0})
    iron = MaterialCatalog.material_id(:iron)

    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(iron))
    assert occupied?(chunk, macro)

    {:ok, _} =
      ChunkProcess.put_surface_element(chunk, %{
        macro_index: macro,
        face: :x_pos,
        surface_type_id: SurfaceCatalog.surface_type_id(:rust_decal)
      })

    assert occupied?(chunk, macro), "实心块贴面后仍应碰撞"

    storage = ChunkProcess.debug_state(chunk).storage
    assert SceneServer.Voxel.Storage.normal_block_at(storage, macro).material_id == iron

    {:ok, _} = ChunkProcess.clear_surface_element(chunk, macro, :x_pos)
    assert occupied?(chunk, macro)

    storage2 = ChunkProcess.debug_state(chunk).storage
    assert SceneServer.Voxel.Storage.normal_block_at(storage2, macro).material_id == iron
  end
end
