defmodule SceneServer.Voxel.Reaction.CombustionEffectsTest do
  # 功能完善 · 反应层 R5b:ChunkProcess set_tag(:burning)+ 动态属性 delta(burn_progress 累进/clip)
  # 效果落 truth。DB-backed,沿 chunk_process_test 同款 setup。
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
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.Types

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    WriteTokenStore.reset()

    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.delete_env(:scene_server, :cli_observe_log)

    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
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

  defp wood_id, do: MaterialCatalog.material_id(:wood)
  defp burning_id, do: with({:ok, id, _} <- TagCatalog.lookup_by_name("burning"), do: id)

  defp start_chunk_with_wood do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro = Types.macro_index!({0, 0, 0})
    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(wood_id()))
    {chunk, macro}
  end

  defp tag_ids_at(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    block = Storage.normal_block_at(storage, macro_index)

    case block.tag_set_ref do
      0 -> []
      ref -> Enum.at(storage.tag_sets, ref - 1).tag_ids
    end
  end

  defp burn_progress_at(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro_index, "burn_progress") / 65_536
  end

  defp ctx, do: %{region_id: 1, chunk_coord: {0, 0, 0}, kernel_id: :reaction, source_tick: 1}

  defp apply_effects(chunk, effects), do: ChunkProcess.apply_field_effects(chunk, effects, ctx())

  test "set_tag 加 :burning → tag 落 truth" do
    {chunk, macro} = start_chunk_with_wood()
    assert tag_ids_at(chunk, macro) == []

    assert {:ok, _} =
             apply_effects(chunk, [{:set_tag, %{macro_index: macro, add: [:burning], remove: []}}])

    assert burning_id() in tag_ids_at(chunk, macro)
  end

  test "set_tag 去 :burning → tag 移除" do
    {chunk, macro} = start_chunk_with_wood()
    apply_effects(chunk, [{:set_tag, %{macro_index: macro, add: [:burning], remove: []}}])
    assert burning_id() in tag_ids_at(chunk, macro)

    apply_effects(chunk, [{:set_tag, %{macro_index: macro, add: [], remove: [:burning]}}])
    refute burning_id() in tag_ids_at(chunk, macro)
  end

  test "set_tag 重复加同 tag 幂等(不变,不 bump 版本)" do
    {chunk, macro} = start_chunk_with_wood()
    apply_effects(chunk, [{:set_tag, %{macro_index: macro, add: [:burning], remove: []}}])
    v1 = ChunkProcess.debug_state(chunk).storage.chunk_version

    apply_effects(chunk, [{:set_tag, %{macro_index: macro, add: [:burning], remove: []}}])
    v2 = ChunkProcess.debug_state(chunk).storage.chunk_version

    assert v2 == v1
    assert tag_ids_at(chunk, macro) == [burning_id()]
  end

  test "burn_progress delta 累进(0.025 ×2 ≈ 0.05)" do
    {chunk, macro} = start_chunk_with_wood()
    assert burn_progress_at(chunk, macro) == 0.0

    apply_effects(chunk, [
      {:write_voxel_attribute, %{attribute: "burn_progress", macro_index: macro, delta: 0.025}}
    ])

    apply_effects(chunk, [
      {:write_voxel_attribute, %{attribute: "burn_progress", macro_index: macro, delta: 0.025}}
    ])

    assert_in_delta burn_progress_at(chunk, macro), 0.05, 0.001
  end

  test "burn_progress clip 到 1.0(0.6 ×2 不超 1.0)" do
    {chunk, macro} = start_chunk_with_wood()

    apply_effects(chunk, [
      {:write_voxel_attribute, %{attribute: "burn_progress", macro_index: macro, delta: 0.6}}
    ])

    apply_effects(chunk, [
      {:write_voxel_attribute, %{attribute: "burn_progress", macro_index: macro, delta: 0.6}}
    ])

    assert_in_delta burn_progress_at(chunk, macro), 1.0, 0.001
  end
end
