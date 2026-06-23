defmodule SceneServer.Voxel.Stress.StructuralStressE2ETest do
  # 力学应力 端到端(生产路径,真 ChunkProcess + 异步 provisioning sweep + FieldTickWorker):
  # 订阅触发 sweep → StructuralStress provisioner 探到失支撑 → 起 [structural_stress] region →
  # worker 逐 tick 算失支撑 → 坍塌成 debris(truth 转 empty)。坐地结构无失支撑 → 无 region、
  # 存活。沿 chunk_process_test 的 storage 预置 + poll 范式(异步、确定终态)。
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.Types

  @stone 2

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

  defp storage_with(blocks) do
    Enum.reduce(blocks, Storage.empty(1, {0, 0, 0}), fn coord, acc ->
      Storage.put_solid_block(acc, coord, NormalBlockData.new(@stone))
    end)
  end

  defp start_chunk(storage, request_id) do
    chunk =
      start_supervised!(
        {ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}, storage: storage},
        id: {:chunk, request_id}
      )

    {:ok, payload} = ChunkProcess.subscribe(chunk, self(), request_id: request_id)
    assert_receive {:voxel_chunk_snapshot_payload, ^payload}
    chunk
  end

  defp solid?(chunk, coord) do
    storage = ChunkProcess.debug_state(chunk).storage
    match?(%NormalBlockData{}, Storage.normal_block_at(storage, Types.macro_index!(coord)))
  end

  defp poll_empty(chunk, coord, timeout_ms, waited \\ 0) do
    cond do
      not solid?(chunk, coord) ->
        true

      waited >= timeout_ms ->
        false

      true ->
        Process.sleep(25)
        poll_empty(chunk, coord, timeout_ms, waited + 25)
    end
  end

  test "坐地塔:全部连到地锚 → 无 stress region、结构存活" do
    chunk = start_chunk(storage_with([{0, 0, 0}, {0, 1, 0}, {0, 2, 0}]), 71)

    # 给 sweep + 潜在 tick 一点时间;坐地无失支撑 → 不该起任何 region。
    Process.sleep(300)

    assert ChunkProcess.debug_state(chunk).field_region_count == 0
    assert solid?(chunk, {0, 0, 0})
    assert solid?(chunk, {0, 1, 0})
    assert solid?(chunk, {0, 2, 0})
  end

  test "悬空块:失支撑 → 自动坍塌成 debris(转 empty),地锚列存活" do
    chunk =
      start_chunk(storage_with([{0, 0, 0}, {0, 1, 0}, {5, 5, 5}]), 72)

    # 悬空块 (5,5,5) 与地锚列不相连 → provisioner 起 region → worker 坍掉它。
    assert poll_empty(chunk, {5, 5, 5}, 5_000),
           "悬空块应被自动坍塌成 empty;实际仍实心"

    # 坐地列不受影响。
    assert solid?(chunk, {0, 0, 0})
    assert solid?(chunk, {0, 1, 0})
  end

  test "悬空岛:整块离地连通分量全坍,地锚 cell 存活" do
    # (5,5,5)-(5,6,5)-(6,5,5) 互相面相邻成岛,但整体不连到地锚 (0,0,0)。
    chunk =
      start_chunk(storage_with([{0, 0, 0}, {5, 5, 5}, {5, 6, 5}, {6, 5, 5}]), 73)

    assert poll_empty(chunk, {5, 5, 5}, 5_000)
    assert poll_empty(chunk, {5, 6, 5}, 5_000)
    assert poll_empty(chunk, {6, 5, 5}, 5_000)

    assert solid?(chunk, {0, 0, 0})
  end
end
