defmodule SceneServer.Voxel.Stress.BurnCollapseChainE2ETest do
  # 力学应力 step5:field-commit 触发重 sweep(provisioning 局限②)闭合**跨系统链**。
  # 一个系统的 field 效果改了块拓扑/材料(化学把承重梁烧成灰 / 放电毁掉梁)→ ChunkProcess
  # 去抖重跑 provisioning sweep → 力学 provisioner 按新 truth 探到上方失支撑 → 起 region 坍塌。
  # 只经 committed truth 耦合,无任何「烧了就塌」的硬规则。真 ChunkProcess + 异步 sweep + worker。
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
  @wood 3
  @iron 5
  @ash 10

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

  # 承重梁结构:地锚 (2,0,2) — 梁 (2,1,2) — 上方块 (2,2,2)。上方块仅经梁连到地。
  defp tower_storage(beam_material, beam_opts) do
    Storage.empty(1, {0, 0, 0})
    |> Storage.put_solid_block({2, 0, 2}, NormalBlockData.new(@stone))
    |> Storage.put_solid_block({2, 1, 2}, NormalBlockData.new(beam_material, beam_opts))
    |> Storage.put_solid_block({2, 2, 2}, NormalBlockData.new(@stone))
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

  defp material_at(chunk, coord) do
    storage = ChunkProcess.debug_state(chunk).storage

    case Storage.normal_block_at(storage, Types.macro_index!(coord)) do
      %NormalBlockData{material_id: id} -> id
      _other -> nil
    end
  end

  defp solid?(chunk, coord), do: material_at(chunk, coord) != nil

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

  defp ctx, do: %{region_id: 1, chunk_coord: {0, 0, 0}, kernel_id: :reaction, source_tick: 1}

  test "烧梁→坍塌:化学把承重木梁烧成灰(transform)→ 重 sweep → 上方失支撑坍塌" do
    chunk = start_chunk(tower_storage(@wood, []), 81)

    # 初始全连地(木梁 structural)→ 给 sweep 一点时间,确认稳定:上方块仍在。
    Process.sleep(200)
    assert solid?(chunk, {2, 2, 2})
    assert ChunkProcess.debug_state(chunk).field_region_count == 0

    # 燃烧产物:木梁 → 灰(field 效果提交 truth)。灰 structural=0 → 承载断。
    transform =
      {:transform_material,
       %{macro_index: Types.macro_index!({2, 1, 2}), from: @wood, to: @ash, rule_id: :combustion}}

    assert {:ok, %{applied_count: 1}} = ChunkProcess.apply_field_effects(chunk, [transform], ctx())

    # field-commit 重 sweep → 力学探到上方失支撑 → 坍塌。
    assert poll_empty(chunk, {2, 2, 2}, 5_000),
           "烧梁后上方块应失支撑坍塌;实际仍实心"

    # 地锚存活;梁原位变成灰(非承重,不算失支撑结构,留存)。
    assert material_at(chunk, {2, 0, 2}) == @stone
    assert material_at(chunk, {2, 1, 2}) == @ash
  end

  test "毁梁→坍塌:放电毁掉承重梁(damage_block 归零)→ 重 sweep → 上方坍塌" do
    # 铁梁带耐久,放电击穿毁之(另一系统经 truth 触发力学,验证机制不限于化学)。
    chunk = start_chunk(tower_storage(@iron, health: 20), 82)

    Process.sleep(200)
    assert solid?(chunk, {2, 2, 2})

    damage =
      {:damage_block,
       %{macro_index: Types.macro_index!({2, 1, 2}), amount: 25, source: :electric_discharge}}

    assert {:ok, %{applied_count: 1}} = ChunkProcess.apply_field_effects(chunk, [damage], ctx())

    # 梁被毁成空 → 重 sweep → 上方失支撑坍塌。
    assert poll_empty(chunk, {2, 1, 2}, 5_000)
    assert poll_empty(chunk, {2, 2, 2}, 5_000)
    assert material_at(chunk, {2, 0, 2}) == @stone
  end
end
