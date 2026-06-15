defmodule SceneServer.Voxel.Reaction.ElectricDischargeDamageE2ETest do
  # 功能完善 · 反应层 R8:放电击穿伤害端到端——放电沿击穿路径逐 tick 减路径方块 health,归零毁块,
  # 经 SystemActor(always-commit)→ ChunkProcess → truth → 快照反映。证"电离/放电"派生计算接到
  # 世界后果(同 R7 电路驱动负载,把一直在算却无后果的电计算落地)。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, FieldTickWorker, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.ElectricDischargeKernel
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

  defp solid?(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    match?(%NormalBlockData{}, Storage.normal_block_at(storage, macro))
  end

  defp health_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage

    case Storage.normal_block_at(storage, macro) do
      %NormalBlockData{health: health} -> health
      _other -> nil
    end
  end

  test "放电击穿:沿路径减方块 health → 归零毁块(电→世界后果)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 7, chunk_coord: {0, 0, 0}})
    source = Types.macro_index!({0, 0, 0})
    mid = Types.macro_index!({1, 0, 0})
    target = Types.macro_index!({2, 0, 0})

    iron = MaterialCatalog.material_id(:iron)
    power_block = MaterialCatalog.material_id(:power_block)

    {:ok, _} = ChunkProcess.put_solid_block(chunk, source, NormalBlockData.new(power_block))
    # 路径中段:带 health 的实心块,放电沿击穿路径逐 tick 减 health 直至毁。
    {:ok, _} = ChunkProcess.put_solid_block(chunk, mid, NormalBlockData.new(iron, health: 60))
    {:ok, _} = ChunkProcess.put_solid_block(chunk, target, NormalBlockData.new(iron))

    assert solid?(chunk, mid)
    assert health_at(chunk, mid) == 60

    region =
      FieldRegion.new(%{
        region_id: 9501,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 0, 0}},
        kernels: [
          %{
            id: :electric_discharge,
            module: ElectricDischargeKernel,
            opts: %{
              target_macro_index: target,
              max_frontier: 32,
              power_source: %{voltage: 120.0, load_current_amps: 8.0},
              # 30/tick × 2 tick → 60 health 归零毁块(确定性,避开默认 amount 漂移)。
              breakdown_damage: %{damage_per_tick: 30}
            }
          }
        ],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}],
        max_ticks: 10
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 7,
        tick_interval_ms: 1
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000

    # 60 health / 30 per tick → 2 tick 归零毁块:中段 cell 不再实心。
    refute solid?(chunk, mid),
           "放电击穿应逐 tick 减 health 至毁;现 health=#{inspect(health_at(chunk, mid))}"
  end
end
