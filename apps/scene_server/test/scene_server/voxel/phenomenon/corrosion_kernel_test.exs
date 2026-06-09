defmodule SceneServer.Voxel.Phenomenon.CorrosionKernelTest do
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Field.FieldTickWorker
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Corrosion
  alias SceneServer.Voxel.Phenomenon.CorrosionKernel
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @fixed32_scale 65_536

  setup_all do
    {:ok, _} = Application.ensure_all_started(:scene_server)
    :ok
  end

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-corrosion-kernel-#{System.unique_integer([:positive])}.log"
      )

    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    File.rm(observe_log)
    Application.put_env(:scene_server, :cli_observe_log, observe_log)

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    %{observe_log: observe_log}
  end

  test "corrosion kernel writes material weakening through chunk authority", %{
    observe_log: observe_log
  } do
    logical_scene_id = 86_200 + System.unique_integer([:positive])
    macro_coord = {0, 0, 0}
    macro_index = Types.macro_index!(macro_coord)

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk_pid, macro_coord, NormalBlockData.new(5))

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 {:write_voxel_attribute,
                  %{macro_index: macro_index, attribute: :moisture, raw_value: fixed32(120.0)}},
                 {:write_voxel_attribute,
                  %{
                    macro_index: macro_index,
                    attribute: :chemical_concentration,
                    raw_value: fixed32(45.0)
                  }}
               ],
               %{kernel_id: :test_setup}
             )

    conductivity_before =
      chunk_pid
      |> ChunkProcess.debug_state()
      |> Map.fetch!(:storage)
      |> Storage.effective_attribute_at_normalized(macro_index, "electric_conductivity")

    region =
      FieldRegion.new(%{
        region_id: 301,
        chunk_coord: {0, 0, 0},
        aabb: {macro_coord, macro_coord},
        kernels: [%{id: :corrosion, module: CorrosionKernel, opts: %{}}],
        source_points: [],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk_pid,
        storage_fn: fn -> ChunkProcess.debug_state(chunk_pid).storage end,
        logical_scene_id: logical_scene_id,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    storage = ChunkProcess.debug_state(chunk_pid).storage

    assert Storage.effective_attribute_at(storage, macro_index, "surface_state") ==
             Corrosion.surface_corroding()

    assert Storage.effective_attribute_at(storage, macro_index, "corrosion") > 0

    assert Storage.effective_attribute_at(storage, macro_index, "structural_integrity") <
             fixed32(100.0)

    assert Storage.effective_attribute_at_normalized(
             storage,
             macro_index,
             "electric_conductivity"
           ) < conductivity_before

    CliObserve.flush_path(observe_log)
    log = File.read!(observe_log)
    assert log =~ ~s(event="voxel_corrosion_advanced")
    assert log =~ "attribute: \"corrosion\""
    assert log =~ "attribute: \"surface_state\""
    assert log =~ "attribute: \"electric_conductivity\""
    assert log =~ "voxel_phenomenon_instance_upserted"
  end

  defp fixed32(value), do: round(value * @fixed32_scale)
end
