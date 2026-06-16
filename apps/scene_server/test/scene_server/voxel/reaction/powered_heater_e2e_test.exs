defmodule SceneServer.Voxel.Reaction.PoweredHeaterE2ETest do
  # 功能完善 · 反应层 R9a:通电设备(加热器)端到端——给负载置 :powered(模拟 R7 circuit 输出,
  # R7 电路→:powered 另由 circuit_current_kernel_test 证),ReactionKernel 读 truth → powered_heater
  # 放热 → R6c 守恒热扩散传相邻冷冰 → 冰升过 0℃ 熔为水。证 circuit→:powered→热→熔 设备涌现链。
  # 受控:加热器与冰均起于 -10℃(扩散本身不会熔冰),唯一能量源是通电加热器。
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

  defp material_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.normal_block_at(storage, macro).material_id
  end

  defp temperature_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro, "temperature") / 65_536
  end

  defp set_temperature(chunk, macro, celsius) do
    {:ok, _} =
      ChunkProcess.write_temperature_attribute(chunk, %{
        macro_index: macro,
        target_temperature_celsius: celsius
      })
  end

  test "通电加热器:通电负载放热 → 热扩散熔化相邻冷冰(circuit→:powered→热→熔)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    load = Types.macro_index!({0, 0, 0})
    ice = Types.macro_index!({1, 0, 0})

    ice_id = MaterialCatalog.material_id(:ice)
    water_id = MaterialCatalog.material_id(:water)

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        load,
        NormalBlockData.new(MaterialCatalog.material_id(:electric_load))
      )

    {:ok, _} = ChunkProcess.put_solid_block(chunk, ice, NormalBlockData.new(ice_id))

    # 受控:加热器与冰均起于 -10℃ → 无温度梯度,扩散本身不会把冰升过 0℃(R3 已证冷冰不自熔)。
    set_temperature(chunk, load, -10.0)
    set_temperature(chunk, ice, -10.0)

    # 模拟 R7 circuit 输出:给负载置 :powered(本测聚焦 R9a 加热器链)。
    {:ok, _} =
      ChunkProcess.apply_field_effects(
        chunk,
        [{:set_tag, %{macro_index: load, add: [:powered], remove: []}}],
        %{}
      )

    assert material_at(chunk, ice) == ice_id

    region =
      FieldRegion.new(%{
        region_id: 9501,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {1, 0, 0}},
        kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}],
        source_points: [],
        max_ticks: 80
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 9,
        tick_interval_ms: 1
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000

    assert material_at(chunk, ice) == water_id,
           "通电加热器放热经热扩散应把相邻冷冰熔为水;加热器温=#{temperature_at(chunk, load)}℃ 冰温=#{temperature_at(chunk, ice)}℃"
  end
end
