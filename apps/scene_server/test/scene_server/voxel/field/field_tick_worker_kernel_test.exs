defmodule SceneServer.Voxel.Field.FieldTickWorkerKernelTest do
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldCodec, FieldLayer, FieldRegion, FieldTickWorker}
  alias SceneServer.Voxel.Field.Kernels.ConductionPathKernel
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Combustion
  alias SceneServer.Voxel.Phenomenon.CombustionKernel
  alias SceneServer.Voxel.Storage
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

  defmodule WriteTemperatureEffectKernel do
    @behaviour SceneServer.Voxel.Field.Kernel

    def kernel_id, do: :write_temperature_effect
    def required_layers(_opts), do: [:temperature]

    def tick(region, _context, opts) do
      {:cont, region,
       [
         {:write_voxel_attribute,
          %{
            attribute: :temperature,
            macro_index: Map.fetch!(opts, :macro_index),
            target_temperature_celsius: Map.fetch!(opts, :target_temperature_celsius)
          }}
       ]}
    end
  end

  defmodule SlowTruthEffectKernel do
    @behaviour SceneServer.Voxel.Field.Kernel

    def kernel_id, do: :slow_truth_effect
    def required_layers(_opts), do: [:temperature]

    def tick(region, _context, opts) do
      {:cont, region,
       [
         {:write_voxel_attribute,
          %{
            attribute: :temperature,
            macro_index: Map.fetch!(opts, :macro_index),
            heat_energy_joules: 1.0
          }}
       ]}
    end
  end

  defmodule BlockingEffectChunk do
    use GenServer

    def start_link(parent) do
      GenServer.start_link(__MODULE__, parent)
    end

    @impl true
    def init(parent), do: {:ok, %{parent: parent}}

    @impl true
    def handle_cast({:push_field_snapshot_payload, payload}, state) do
      send(state.parent, {:blocking_chunk_snapshot, payload})
      {:noreply, state}
    end

    def handle_cast({:push_field_region_destroyed_payload, payload}, state) do
      send(state.parent, {:blocking_chunk_destroyed, payload})
      {:noreply, state}
    end

    @impl true
    def handle_call({:apply_field_effects, _effects, _context}, _from, state) do
      send(state.parent, :blocking_chunk_effect_call_started)

      receive do
        :release_blocking_effects -> :ok
      after
        1_000 -> :ok
      end

      send(state.parent, :blocking_chunk_effect_call_finished)

      {:reply, {:ok, %{applied_count: 1, rejected_count: 0, chunk_version: 1, results: []}},
       state}
    end
  end

  defmodule UnsupportedEffectKernel do
    @behaviour SceneServer.Voxel.Field.Kernel

    def kernel_id, do: :unsupported_effect
    def required_layers(_opts), do: [:temperature]

    def tick(region, _context, opts) do
      {:cont, region, [{:ignite, %{macro_index: Map.fetch!(opts, :macro_index)}}]}
    end
  end

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    path =
      Path.join(System.tmp_dir!(), "scene-field-kernel-#{System.unique_integer([:positive])}.log")

    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    SceneServer.TestVoxelRuntime.ensure_started!()

    # 阶段3.1：每个测试用隔离的 chunk 进程身份注册表，避免全局单例 {1, {0,0,0}}
    # 身份槽位在全量 mix test 中被跨文件 / 跨测试拆除竞态串扰成 {:already_started}。
    chunk_registry =
      :"field_tick_worker_kernel_test_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, keys: :unique, name: chunk_registry},
      id: {:registry, chunk_registry}
    )

    Process.put(:chunk_registry, chunk_registry)

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end

      File.rm(path)
    end)

    {:ok, observe_log: path, chunk_registry: chunk_registry}
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

  test "new regions dispatch their first snapshot immediately instead of waiting for the tick interval" do
    macro_index = Types.macro_index!({0, 0, 0})

    region =
      FieldRegion.new(%{
        region_id: 107,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :set_temperature,
            module: SetTemperatureKernel,
            opts: %{macro_index: macro_index, value: 321.0}
          }
        ],
        max_ticks: 1
      })

    {:ok, _pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: self(),
        storage_fn: fn -> nil end,
        logical_scene_id: 1,
        tick_interval_ms: 1_000
      )

    assert_receive {:"$gen_cast", {:push_field_snapshot_payload, payload}}, 50
    snapshot = FieldCodec.decode_snapshot_payload!(payload)

    assert snapshot.tick_count == 1
    assert_snapshot_temperature(snapshot, macro_index, 321.0)
  end

  test "first snapshots are dispatched before slow truth effects are applied" do
    macro_index = Types.macro_index!({0, 0, 0})
    chunk = start_supervised!({BlockingEffectChunk, self()})

    region =
      FieldRegion.new(%{
        region_id: 108,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :slow_truth_effect,
            module: SlowTruthEffectKernel,
            opts: %{macro_index: macro_index}
          }
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> nil end,
        logical_scene_id: 1,
        tick_interval_ms: 1_000
      )

    assert_receive {:blocking_chunk_snapshot, payload}, 50
    snapshot = FieldCodec.decode_snapshot_payload!(payload)
    assert snapshot.tick_count == 1

    assert_receive :blocking_chunk_effect_call_started, 50
    refute_receive :blocking_chunk_effect_call_finished, 0

    send(chunk, :release_blocking_effects)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
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

  test "reusing a field source refreshes the worker lifetime" do
    macro_index = Types.macro_index!({3, 3, 3})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    attrs = %{
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {3, 3, 3}},
      kernels: [
        %{
          id: :set_temperature,
          module: SetTemperatureKernel,
          opts: %{macro_index: macro_index, value: 10.0}
        }
      ],
      source_points: [
        %{
          macro_index: macro_index,
          field_type: :temperature,
          source_mode: :persistent,
          value: 10.0
        }
      ],
      source_points_mode: :replace,
      source_key: {:temperature, macro_index},
      max_ticks: 10
    }

    assert {:ok, first} = ChunkProcess.ensure_field_region(chunk, attrs)
    worker_pid = field_worker_pid!(chunk, first.region_id)

    :sys.replace_state(worker_pid, fn state ->
      %{state | region: %{state.region | tick_count: 9, max_ticks: 10}}
    end)

    refreshed_aabb = {{0, 0, 0}, {5, 5, 5}}

    assert {:ok, second} =
             ChunkProcess.ensure_field_region(chunk, %{
               attrs
               | aabb: refreshed_aabb,
                 max_ticks: 25
             })

    assert second.region_id == first.region_id
    assert second.region_action == :reused
    assert second.source_points_action == :replaced

    refreshed_state = :sys.get_state(worker_pid)
    assert refreshed_state.region.tick_count == 0
    assert refreshed_state.region.max_ticks == 25
    assert refreshed_state.region.aabb == refreshed_aabb
  end

  test "non-observe temperature effects are dispatched to chunk truth", %{
    observe_log: observe_log
  } do
    macro_index = Types.macro_index!({0, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, macro_index, NormalBlockData.new(1))

    region =
      FieldRegion.new(%{
        region_id: 104,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :write_temperature_effect,
            module: WriteTemperatureEffectKernel,
            opts: %{macro_index: macro_index, target_temperature_celsius: 120.0}
          }
        ],
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
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    storage = ChunkProcess.debug_state(chunk).storage
    assert Storage.effective_attribute_at(storage, macro_index, "temperature") == 7_864_320

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_field_effect_applied"
    assert observe_log_text =~ "kernel_id: :write_temperature_effect"
  end

  test "conduction path Joule heat effects are dispatched to chunk truth", %{
    observe_log: observe_log
  } do
    source_index = Types.macro_index!({0, 0, 0})
    target_index = Types.macro_index!({1, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, source_index, NormalBlockData.new(5))

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, target_index, NormalBlockData.new(5))

    initial_storage = ChunkProcess.debug_state(chunk).storage

    initial_source_temperature =
      Storage.effective_attribute_at(initial_storage, source_index, "temperature")

    initial_target_temperature =
      Storage.effective_attribute_at(initial_storage, target_index, "temperature")

    region =
      FieldRegion.new(%{
        region_id: 106,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {1, 0, 0}},
        kernels: [
          %{
            id: :conduction_path,
            module: ConductionPathKernel,
            opts: %{
              target_macro_index: target_index,
              power_source: %{
                output_mode: :dc,
                voltage: 120.0,
                current_limit_amps: 20.0,
                load_current_amps: 20.0
              },
              thermal_coupling: %{enabled: true, joule_scale: 100_000.0}
            }
          }
        ],
        source_points: [
          %{macro_index: source_index, field_type: :electric_potential, value: 120.0}
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    storage = ChunkProcess.debug_state(chunk).storage

    assert Storage.effective_attribute_at(storage, source_index, "temperature") >
             initial_source_temperature

    assert Storage.effective_attribute_at(storage, target_index, "temperature") >
             initial_target_temperature

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_field_effect_applied"
    assert observe_log_text =~ "kernel_id: :conduction_path"
    assert observe_log_text =~ "heat_energy_joules:"
  end

  test "combustion effects are dispatched to chunk truth and leave residue", %{
    observe_log: observe_log
  } do
    macro_index = Types.macro_index!({0, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               macro_index,
               NormalBlockData.new(MaterialCatalog.wood_material_id())
             )

    region =
      FieldRegion.new(%{
        region_id: 109,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 1.0, ambient_loss_per_second: 0.0}
          },
          %{
            id: :combustion,
            module: CombustionKernel,
            opts: %{
              profile: %{initial_fuel_mass_kg_per_m3: 1.0, burn_rate_kg_per_m3_second: 1000.0}
            }
          }
        ],
        source_points: [
          %{
            macro_index: macro_index,
            field_type: :temperature,
            source_mode: :impulse,
            value: 700.0
          }
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    storage = ChunkProcess.debug_state(chunk).storage

    assert Storage.normal_block_at(storage, macro_index).material_id ==
             MaterialCatalog.charcoal_material_id()

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_combustion_extinguished"
    assert observe_log_text =~ "transform_voxel_material"
  end

  test "combustion structural failure candidate is observable while integrity remains chunk truth",
       %{
         observe_log: observe_log
       } do
    macro_index = Types.macro_index!({0, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               macro_index,
               NormalBlockData.new(MaterialCatalog.wood_material_id())
             )

    region =
      FieldRegion.new(%{
        region_id: 112,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 1.0, ambient_loss_per_second: 0.0}
          },
          %{
            id: :combustion,
            module: CombustionKernel,
            opts: %{
              profile: %{
                initial_fuel_mass_kg_per_m3: 100.0,
                burn_rate_kg_per_m3_second: 10.0,
                structural_loss_percent_per_kg: 80.0,
                structural_failure_threshold_percent: 50.0
              }
            }
          }
        ],
        source_points: [
          %{
            macro_index: macro_index,
            field_type: :temperature,
            source_mode: :impulse,
            value: 700.0
          }
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    storage = ChunkProcess.debug_state(chunk).storage
    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert Storage.effective_attribute_at(storage, macro_index, "structural_integrity") <
             fixed32(50.0)

    assert observe_log_text =~ "voxel_structural_collapse_candidate"
    assert observe_log_text =~ "reason: :combustion_integrity_loss"
    assert observe_log_text =~ "voxel_field_effect_applied"
  end

  test "low oxygen heat carbonizes wood into charcoal through chunk authority", %{
    observe_log: observe_log
  } do
    macro_index = Types.macro_index!({0, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               macro_index,
               NormalBlockData.new(MaterialCatalog.wood_material_id())
             )

    assert {:ok, _summary} =
             ChunkProcess.apply_field_effects(
               chunk,
               [
                 {:write_voxel_attribute,
                  %{
                    macro_index: macro_index,
                    attribute: :oxygen,
                    raw_value: fixed32(2.0)
                  }}
               ],
               %{kernel_id: :test_setup}
             )

    region =
      FieldRegion.new(%{
        region_id: 113,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 1.0, ambient_loss_per_second: 0.0}
          },
          %{
            id: :combustion,
            module: CombustionKernel,
            opts: %{
              profile: %{
                oxygen_limited_carbonization_percent_per_second: 1_000.0,
                oxygen_limited_structural_loss_percent_per_second: 1.0,
                oxygen_limited_residue_threshold_percent: 50.0,
                oxygen_limited_residue: {:material, MaterialCatalog.charcoal_material_id()}
              }
            }
          }
        ],
        source_points: [
          %{
            macro_index: macro_index,
            field_type: :temperature,
            source_mode: :impulse,
            value: 700.0
          }
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    storage = ChunkProcess.debug_state(chunk).storage
    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert Storage.normal_block_at(storage, macro_index).material_id ==
             MaterialCatalog.charcoal_material_id()

    assert observe_log_text =~ "voxel_combustion_carbonized"
    assert observe_log_text =~ "oxygen_limited_carbonization"
    refute observe_log_text =~ "voxel_combustion_ignited"
  end

  test "combustion heat diffuses and ignites adjacent combustible material", %{
    observe_log: observe_log
  } do
    source_index = Types.macro_index!({0, 0, 0})
    target_index = Types.macro_index!({1, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    for macro_index <- [source_index, target_index] do
      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk,
                 macro_index,
                 NormalBlockData.new(MaterialCatalog.cloth_material_id())
               )
    end

    region =
      FieldRegion.new(%{
        region_id: 110,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {1, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 100_000_000.0, ambient_loss_per_second: 0.0}
          },
          %{
            id: :combustion,
            module: CombustionKernel,
            opts: %{}
          }
        ],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :temperature,
            source_mode: :impulse,
            value: 1_000.0
          }
        ],
        max_ticks: 3
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000

    storage = ChunkProcess.debug_state(chunk).storage
    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert Storage.effective_attribute_at(storage, source_index, "combustion_stage") ==
             Combustion.stage_burning()

    assert Storage.effective_attribute_at(storage, target_index, "combustion_stage") ==
             Combustion.stage_burning(),
           observe_log_text

    assert observe_log_text =~ "voxel_combustion_ignited"
    assert observe_log_text =~ "write_voxel_attribute"
  end

  test "combustion heat hands off across a chunk boundary and ignites the neighbor", %{
    observe_log: observe_log,
    chunk_registry: chunk_registry
  } do
    logical_scene_id = 81_000 + System.unique_integer([:positive])
    source_index = Types.macro_index!({15, 0, 0})
    target_index = Types.macro_index!({0, 0, 0})
    directory = :"field_tick_worker_kernel_test_directory_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ChunkDirectory, [name: directory, chunk_registry: chunk_registry]},
      id: {:chunk_directory, directory}
    )

    assert {:ok, source_chunk} =
             ChunkDirectory.ensure_chunk(directory, %{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, target_chunk} =
             ChunkDirectory.ensure_chunk(directory, %{
               logical_scene_id: logical_scene_id,
               chunk_coord: {1, 0, 0}
             })

    for {chunk, macro_index} <- [{source_chunk, source_index}, {target_chunk, target_index}] do
      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk,
                 macro_index,
                 NormalBlockData.new(MaterialCatalog.cloth_material_id())
               )
    end

    region =
      FieldRegion.new(%{
        region_id: 114,
        chunk_coord: {0, 0, 0},
        aabb: {{15, 0, 0}, {15, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 1.0, ambient_loss_per_second: 0.0}
          },
          %{
            id: :combustion,
            module: CombustionKernel,
            opts: %{boundary_max_ticks: 5}
          }
        ],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :temperature,
            source_mode: :impulse,
            value: 1_000.0
          }
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: source_chunk,
        storage_fn: fn -> ChunkProcess.debug_state(source_chunk).storage end,
        logical_scene_id: logical_scene_id,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert :ok =
             eventually(fn ->
               target_storage = ChunkProcess.debug_state(target_chunk).storage

               Storage.effective_attribute_at(target_storage, target_index, "combustion_stage") ==
                 Combustion.stage_burning()
             end)

    assert ChunkProcess.debug_state(target_chunk).field_region_count >= 1

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert observe_log_text =~ "voxel_field_region_handoff_applied"
    assert observe_log_text =~ "reason: :combustion_boundary_heat"
    assert observe_log_text =~ ~s(target_chunk_coord: "{1, 0, 0}")
    assert observe_log_text =~ "voxel_combustion_ignited"
  end

  test "wet combustible material dries on one field tick before later ignition", %{
    observe_log: observe_log
  } do
    macro_index = Types.macro_index!({0, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               macro_index,
               NormalBlockData.new(MaterialCatalog.wood_material_id())
             )

    assert {:ok, _summary} =
             ChunkProcess.apply_field_effects(
               chunk,
               [
                 {:write_voxel_attribute,
                  %{
                    macro_index: macro_index,
                    attribute: :moisture,
                    raw_value: fixed32(240.0)
                  }}
               ],
               %{kernel_id: :test_setup}
             )

    region =
      FieldRegion.new(%{
        region_id: 111,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: %{diffusion_time_scale: 1.0, ambient_loss_per_second: 0.0}
          },
          %{
            id: :combustion,
            module: CombustionKernel,
            opts: %{
              profile: %{
                drying_rate_kg_per_m3_second: 400.0,
                initial_fuel_mass_kg_per_m3: 10.0,
                burn_rate_kg_per_m3_second: 1.0
              }
            }
          }
        ],
        source_points: [
          %{
            macro_index: macro_index,
            field_type: :temperature,
            source_mode: :persistent,
            value: 700.0
          }
        ],
        max_ticks: 2
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 100
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    storage = ChunkProcess.debug_state(chunk).storage
    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert Storage.effective_attribute_at(storage, macro_index, "moisture") < fixed32(180.0)

    assert Storage.effective_attribute_at(storage, macro_index, "combustion_stage") ==
             Combustion.stage_burning()

    assert observe_log_text =~ "voxel_combustion_dried"
    assert observe_log_text =~ "voxel_combustion_ignited"
  end

  test "unsupported non-observe effects are explicitly rejected", %{
    observe_log: observe_log
  } do
    macro_index = Types.macro_index!({0, 0, 0})

    chunk =
      start_supervised!(
        {ChunkProcess,
         chunk_registry: Process.get(:chunk_registry), logical_scene_id: 1, chunk_coord: {0, 0, 0}}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, macro_index, NormalBlockData.new(1))

    region =
      FieldRegion.new(%{
        region_id: 105,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [
          %{
            id: :unsupported_effect,
            module: UnsupportedEffectKernel,
            opts: %{macro_index: macro_index}
          }
        ],
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
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert ChunkProcess.debug_state(chunk).chunk_version == 1

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_field_effect_rejected"
    assert observe_log_text =~ "reason: :unsupported_field_effect_action"
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

  defp field_worker_pid!(chunk_pid, region_id) do
    chunk_pid
    |> :sys.get_state()
    |> Map.fetch!(:field_regions)
    |> Map.fetch!(region_id)
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

  defp eventually(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          receive do
          after
            10 -> poll.(poll)
          end
        end
      end
    end

    poll.(poll)
  end

  defp fixed32(value), do: round(value * 65_536)
end
