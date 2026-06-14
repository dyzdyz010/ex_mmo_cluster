defmodule SceneServer.Voxel.Reaction.CombustionE2ETest do
  # 功能完善 · 反应层 R5c:燃烧端到端闭环(旗舰涌现)——点燃 → 自维持燃烧放热 + 进度 → 燃尽成 ash;
  # burning cell 辐射热点燃相邻木 → 火蔓延。全链:truth 温度/tag → ReactionKernel 读 truth →
  # Engine 规则 → set_tag/heat/transform → SystemActor 分流 → ChunkProcess 落 truth → 反馈下一 tick。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, FieldTickWorker, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
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

  defp wood_id, do: MaterialCatalog.material_id(:wood)
  defp ash_id, do: MaterialCatalog.material_id(:ash)
  defp burning_id, do: with({:ok, id, _} <- TagCatalog.lookup_by_name("burning"), do: id)

  defp start_chunk,
    do: start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

  defp place_wood(chunk, coord) do
    macro = Types.macro_index!(coord)
    {:ok, _} = ChunkProcess.put_solid_block(chunk, macro, NormalBlockData.new(wood_id()))
    macro
  end

  defp set_temperature(chunk, macro, celsius) do
    {:ok, _} =
      ChunkProcess.write_temperature_attribute(chunk, %{
        macro_index: macro,
        target_temperature_celsius: celsius
      })
  end

  defp material_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    %NormalBlockData{material_id: id} = Storage.normal_block_at(storage, macro)
    id
  end

  defp burning?(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    block = Storage.normal_block_at(storage, macro)

    case block.tag_set_ref do
      0 -> false
      ref -> burning_id() in Enum.at(storage.tag_sets, ref - 1).tag_ids
    end
  end

  defp run_reaction(chunk, region_id, aabb, max_ticks) do
    region =
      FieldRegion.new(%{
        region_id: region_id,
        chunk_coord: {0, 0, 0},
        aabb: aabb,
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
    # 多 tick × 多效果(含每效果快照编码)需较多墙钟,给足超时。
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
  end

  test "点燃:木 ≥ ignition(350℃)→ 一次反应 tick 获 :burning" do
    chunk = start_chunk()
    macro = place_wood(chunk, {0, 0, 0})
    set_temperature(chunk, macro, 350.0)
    refute burning?(chunk, macro)

    run_reaction(chunk, 9201, {{0, 0, 0}, {0, 0, 0}}, 1)

    assert burning?(chunk, macro)
  end

  test "燃尽:点燃的木持续燃烧 → burn_progress 满 → 变 ash(消耗)" do
    chunk = start_chunk()
    macro = place_wood(chunk, {0, 0, 0})
    set_temperature(chunk, macro, 350.0)

    # 1 tick 点燃 + ~40 tick 烧(burn_progress +0.025/tick)→ 满 → ash。给足 50 tick。
    run_reaction(chunk, 9202, {{0, 0, 0}, {0, 0, 0}}, 50)

    assert material_at(chunk, macro) == ash_id()
    refute burning?(chunk, macro)
  end

  test "蔓延(旗舰):点燃一块木 → 辐射热点燃相邻木(火扩散)" do
    chunk = start_chunk()
    macro_a = place_wood(chunk, {0, 0, 0})
    macro_b = place_wood(chunk, {1, 0, 0})
    set_temperature(chunk, macro_a, 350.0)
    refute burning?(chunk, macro_b)

    # cell A 点燃 → 每 tick 辐射 15MJ 给 B → B ~20 tick 后达 ignition 点燃。给足 40 tick。
    run_reaction(chunk, 9203, {{0, 0, 0}, {1, 0, 0}}, 40)

    assert burning?(chunk, macro_a) or material_at(chunk, macro_a) == ash_id()
    assert burning?(chunk, macro_b), "相邻木应被辐射热点燃(火蔓延)"
  end
end
