defmodule SceneServer.Voxel.Field.FieldTickWorkerKernelTest do
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.Field.{FieldCodec, FieldLayer, FieldRegion, FieldTickWorker}
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Types

  defmodule FailingKernel do
    @behaviour SceneServer.Voxel.Field.Kernel

    def kernel_id, do: :failing
    def required_layers(_opts), do: []
    def tick(_region, _context, _opts), do: raise("intentional kernel failure")
  end

  defmodule SetTemperatureKernel do
    @behaviour SceneServer.Voxel.Field.Kernel

    alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}

    def kernel_id, do: :set_temperature
    def required_layers(_opts), do: [:temperature]

    def tick(%FieldRegion{} = region, _context, opts) do
      macro_index = Map.fetch!(opts, :macro_index)
      value = Map.fetch!(opts, :value)

      layer =
        region
        |> FieldRegion.get_layer(:temperature)
        |> FieldLayer.put(macro_index, value)

      {:cont, FieldRegion.put_layer(region, :temperature, layer), []}
    end
  end

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    path =
      Path.join(System.tmp_dir!(), "scene-field-kernel-#{System.unique_integer([:positive])}.log")

    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end

      File.rm(path)
    end)

    {:ok, observe_log: path}
  end

  test "kernel failures are isolated and later kernels still update the snapshot", %{
    observe_log: observe_log
  } do
    macro_index = Types.macro_index!({0, 0, 0})

    region =
      FieldRegion.new(%{
        region_id: 100,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{id: :failing, module: FailingKernel},
          %{
            id: :set_temperature,
            module: SetTemperatureKernel,
            opts: %{macro_index: macro_index, value: 123.0}
          }
        ],
        max_ticks: 1
      })

    {:ok, _pid} = start_worker(region)

    snapshot = receive_snapshot!()
    assert_snapshot_temperature(snapshot, macro_index, 123.0)

    assert_receive {:"$gen_cast", {:push_field_region_destroyed_payload, destroyed_payload}},
                   1_000

    assert FieldCodec.decode_destroyed_payload!(destroyed_payload).destroy_reason == :expired

    CliObserve.flush()
    assert File.read!(observe_log) =~ "voxel_field_tick_failed"
  end

  test "custom kernel specs run in listed order" do
    macro_index = Types.macro_index!({0, 0, 0})

    region =
      FieldRegion.new(%{
        region_id: 101,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :first,
            module: SetTemperatureKernel,
            opts: %{macro_index: macro_index, value: 10.0}
          },
          %{
            id: :second,
            module: SetTemperatureKernel,
            opts: %{macro_index: macro_index, value: 22.0}
          }
        ],
        max_ticks: 1
      })

    {:ok, _pid} = start_worker(region)

    snapshot = receive_snapshot!()
    assert_snapshot_temperature(snapshot, macro_index, 22.0)
  end

  test "temperature kernel opts are applied by the worker dispatch path" do
    source_idx = Types.macro_index!({3, 3, 3})
    first_ring_idx = Types.macro_index!({4, 3, 3})

    region =
      FieldRegion.new(%{
        region_id: 103,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {7, 7, 7}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 20_000.0, ambient_loss_per_second: 0.08}
          }
        ],
        source_points: [
          %{
            macro_index: source_idx,
            field_type: :temperature,
            source_mode: :impulse,
            value: 800.0
          }
        ],
        max_ticks: 1
      })

    {:ok, _pid} = start_worker(region)

    snapshot = receive_snapshot!()
    assert_snapshot_temperature(snapshot, source_idx, 798.4, 1.0)
    assert_snapshot_temperature(snapshot, first_ring_idx, 20.26, 0.1)
  end

  test "an explicit empty kernel list is rejected" do
    assert_raise ArgumentError, ~r/kernels must be a non-empty list/, fn ->
      FieldRegion.new(%{
        region_id: 102,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [],
        max_ticks: 1
      })
    end
  end

  defp start_worker(region) do
    FieldTickWorker.start_link(
      region: region,
      chunk_pid: self(),
      storage_fn: fn -> nil end,
      logical_scene_id: 1,
      tick_interval_ms: 1
    )
  end

  defp receive_snapshot! do
    assert_receive {:"$gen_cast", {:push_field_snapshot_payload, payload}}, 1_000
    FieldCodec.decode_snapshot_payload!(payload)
  end

  defp assert_snapshot_temperature(snapshot, macro_index, expected) do
    assert_snapshot_temperature(snapshot, macro_index, expected, 0.001)
  end

  defp assert_snapshot_temperature(snapshot, macro_index, expected, delta) do
    assert snapshot.field_mask == FieldCodec.field_mask_temperature()
    assert snapshot.tick_count == 1
    assert macro_index in snapshot.macro_indices

    index = Enum.find_index(snapshot.macro_indices, &(&1 == macro_index))
    assert_in_delta Enum.at(snapshot.temperature_values, index), expected, delta
  end
end
