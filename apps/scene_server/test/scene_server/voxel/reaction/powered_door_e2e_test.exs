defmodule SceneServer.Voxel.Reaction.PoweredDoorE2ETest do
  # 功能完善 · 反应层 R9b:通电门端到端——门(电负载)通电(模拟 R7 circuit 输出,R7 电路→:powered
  # 另由 circuit_current_kernel_test 证)→ door_open 规则置 :open → 碰撞查询视该格为可通行;失电 →
  # door_close 去 :open → 复阻挡。证 circuit→:powered→门开(可穿)/断电→门关 设备涌现链 + passability。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, FieldTickWorker, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
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

  # 模拟 R7 circuit 输出:置/去负载 :powered(本测聚焦 R9b 门状态机 + passability)。
  defp set_powered(chunk, macro, powered?) do
    {add, remove} = if powered?, do: {[:powered], []}, else: {[], [:powered]}

    {:ok, _} =
      ChunkProcess.apply_field_effects(
        chunk,
        [{:set_tag, %{macro_index: macro, add: add, remove: remove}}],
        %{}
      )
  end

  defp run_reaction_tick(chunk, region_id) do
    region =
      FieldRegion.new(%{
        region_id: region_id,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}],
        max_ticks: 1
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

  defp blocking?(chunk, macro) do
    {:ok, result} =
      ChunkProcess.collision_query(chunk, %{samples: [%{macro: macro, micro_slot: 0}]})

    result.occupied_count > 0
  end

  test "通电门:通电 → 开(碰撞可通行)→ 断电 → 关(复阻挡)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    door = Types.macro_index!({0, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        door,
        NormalBlockData.new(MaterialCatalog.material_id(:door))
      )

    # 关门(未通电)= 实心阻挡。
    assert blocking?(chunk, door)

    # 通电 → 反应 tick → door_open 置 :open → 碰撞可通行。
    set_powered(chunk, door, true)
    run_reaction_tick(chunk, 9601)
    refute blocking?(chunk, door), "通电门应打开(:open)→ 碰撞视为可通行"

    # 断电 → 反应 tick → door_close 去 :open → 复阻挡。
    set_powered(chunk, door, false)
    run_reaction_tick(chunk, 9602)
    assert blocking?(chunk, door), "失电门应关闭(去 :open)→ 复阻挡"
  end
end
