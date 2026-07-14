defmodule SceneServer.Voxel.ChunkProcessTest do
  # Phase 1d: ChunkSnapshotStore writes through DataService.Repo. The shared
  # voxel_chunks table forces sync execution + per-test cleanup.
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.LodHeightmapStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Field.FieldCodec
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.Types

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    Repo.delete_all(VoxelChunkPendingTransaction)
    LodHeightmapStore.reset()
    WriteTokenStore.reset()

    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    path =
      Path.join(
        System.tmp_dir!(),
        "scene-chunk-process-#{System.unique_integer([:positive])}.log"
      )

    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # set_tag 落 truth(C4b step0 signal_high 回归)走 TagCatalog 名→id 解析。
    case start_supervised({TagCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    SceneServer.TestVoxelRuntime.ensure_started!()

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

  test "builds snapshot payloads from hot chunk truth" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2, health: 50),
               cell_version: 1
             )

    assert storage.chunk_version == 1

    assert {:ok, payload} = ChunkProcess.snapshot_payload(chunk, 44)

    assert {:ok, %{request_id: 44, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert decoded_storage.chunk_version == 1

    assert Storage.macro_header_at(decoded_storage, 0).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "subscribe immediately sends the current snapshot payload" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, payload} = ChunkProcess.subscribe(chunk, self(), request_id: 55)
    assert_receive {:voxel_chunk_snapshot_payload, ^payload}

    assert {:ok, %{request_id: 55, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert decoded_storage.chunk_version == 0
    assert ChunkProcess.debug_state(chunk).subscriber_count == 1
  end

  test "put_solid_block pushes a second snapshot fallback payload to subscribers" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 56)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2, health: 50),
               cell_version: 1
             )

    assert_receive {:voxel_chunk_snapshot_payload, updated_payload}
    assert updated_payload != initial_payload

    assert {:ok, %{request_id: 0, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(updated_payload)

    assert decoded_storage.chunk_version == 1

    assert Storage.macro_header_at(decoded_storage, 0).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "add_heat_energy_attribute stores computed temperature on voxel truth and pushes a snapshot" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2, health: 50),
               cell_version: 1
             )

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 57)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok,
            %{
              changed?: true,
              heat_energy_joules: 80_000.0,
              previous_temperature: 20.0,
              temperature_delta: temperature_delta,
              effective_temperature: effective_temperature,
              storage: storage
            }} =
             ChunkProcess.add_heat_energy_attribute(chunk, %{
               macro: {0, 0, 0},
               heat_energy_joules: 80_000
             })

    assert_in_delta temperature_delta, 0.03750586, 0.000001
    assert_in_delta effective_temperature, 20.03750586, 0.000001
    assert storage.chunk_version == 2
    assert Storage.effective_attribute_at(storage, {0, 0, 0}, "temperature") == 1_313_178

    assert_receive {:voxel_chunk_snapshot_payload, updated_payload}
    assert updated_payload != initial_payload

    assert {:ok, %{request_id: 0, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(updated_payload)

    assert decoded_storage.chunk_version == 2
    assert Storage.effective_attribute_at(decoded_storage, {0, 0, 0}, "temperature") == 1_313_178
  end

  test "write_temperature_attribute reports real iron heat budget for an 800C target" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(5, health: 100),
               cell_version: 1
             )

    assert {:ok,
            %{
              changed?: true,
              previous_temperature: 20.0,
              target_temperature: 800.0,
              effective_temperature: 800.0,
              density: 7_870.0,
              specific_heat_capacity: 449.0,
              heat_capacity_j_per_k: heat_capacity,
              heat_energy_joules: heat_energy_joules,
              storage: storage
            }} =
             ChunkProcess.write_temperature_attribute(chunk, %{
               macro: {0, 0, 0},
               target_temperature: 800.0
             })

    assert_in_delta heat_capacity, 3_533_630.0, 0.1
    assert_in_delta heat_energy_joules, 2_756_231_400.0, 1.0
    assert Storage.effective_attribute_at(storage, {0, 0, 0}, "temperature") == 52_428_800
  end

  test "apply_field_effects writes temperature through chunk authority", %{
    observe_log: observe_log
  } do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro_index = Types.macro_index!({0, 0, 0})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, macro_index, NormalBlockData.new(1))

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 188)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok,
            %{
              applied_count: 1,
              rejected_count: 0,
              chunk_version: 2,
              results: [
                %{
                  status: :applied,
                  action: :write_voxel_attribute,
                  attribute: :temperature,
                  macro_index: ^macro_index,
                  target_value: 120.0,
                  chunk_version: 2
                }
              ]
            }} =
             ChunkProcess.apply_field_effects(
               chunk,
               [
                 {:write_voxel_attribute,
                  %{
                    attribute: :temperature,
                    macro_index: macro_index,
                    target_temperature_celsius: 120.0
                  }}
               ],
               %{region_id: 701, kernel_id: :test_kernel}
             )

    assert_receive {:voxel_chunk_snapshot_payload, updated_payload}
    assert updated_payload != initial_payload

    storage = ChunkProcess.debug_state(chunk).storage
    assert Storage.effective_attribute_at(storage, macro_index, "temperature") == 7_864_320

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_field_effect_applied"
    assert observe_log_text =~ "region_id: 701"
    assert observe_log_text =~ "kernel_id: :test_kernel"
  end

  test "apply_field_effects can inject heat energy through chunk authority", %{
    observe_log: observe_log
  } do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro_index = Types.macro_index!({0, 0, 0})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, macro_index, NormalBlockData.new(5))

    assert {:ok,
            %{
              applied_count: 1,
              rejected_count: 0,
              chunk_version: 2,
              results: [
                %{
                  status: :applied,
                  action: :write_voxel_attribute,
                  attribute: :temperature,
                  macro_index: ^macro_index,
                  heat_energy_joules: 3_533_630.0,
                  temperature_delta: 1.0,
                  target_value: 21.0,
                  chunk_version: 2
                }
              ]
            }} =
             ChunkProcess.apply_field_effects(
               chunk,
               [
                 {:write_voxel_attribute,
                  %{
                    attribute: :temperature,
                    macro_index: macro_index,
                    heat_energy_joules: 3_533_630.0
                  }}
               ],
               %{region_id: 703, kernel_id: :test_kernel}
             )

    storage = ChunkProcess.debug_state(chunk).storage
    assert Storage.effective_attribute_at(storage, macro_index, "temperature") == 1_376_256

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_field_effect_applied"
    assert observe_log_text =~ "heat_energy_joules: 3533630.0"
    assert observe_log_text =~ "region_id: 703"
  end

  test "apply_field_effects rejects unsupported effects without mutating", %{
    observe_log: observe_log
  } do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, {0, 0, 0}, NormalBlockData.new(1))

    assert {:ok,
            %{
              applied_count: 0,
              rejected_count: 1,
              chunk_version: 1,
              results: [
                %{
                  status: :rejected,
                  reason: :unsupported_field_effect_action,
                  action: :ignite
                }
              ]
            }} =
             ChunkProcess.apply_field_effects(
               chunk,
               [{:ignite, %{macro_index: 0}}],
               %{region_id: 702, kernel_id: :test_kernel}
             )

    assert ChunkProcess.debug_state(chunk).chunk_version == 1

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)
    assert observe_log_text =~ "voxel_field_effect_rejected"
    assert observe_log_text =~ "reason: :unsupported_field_effect_action"
  end

  # C4b step0:补 C4a 断点回归。CircuitCurrentKernel 早已对 comparator 发
  # {:set_tag, add: [:signal_high]},但 :signal_high 未登记 tag_catalog → resolve_tag_ids
  # 名→id 失败 → reject_set_tag → 信号从未落 truth(comparator_test 只验 kernel 发了 effect,
  # 没验落 truth,故一直看似过测)。补 tag_catalog v6 id13 后,本测断言它真正进 tag_set_ref。
  test "apply_field_effects set_tag :signal_high lands in truth (C4a 断点回归)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    macro_index = Types.macro_index!({0, 0, 0})

    # comparator(id21)实心块——signal_high 是它的权威输出。
    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, macro_index, NormalBlockData.new(21))

    # 补 catalog 前这条会是 rejected_count: 1;补后 applied + changed?。
    assert {:ok,
            %{
              applied_count: 1,
              rejected_count: 0,
              results: [
                %{
                  status: :applied,
                  action: :set_tag,
                  macro_index: ^macro_index,
                  changed?: true
                }
              ]
            }} =
             ChunkProcess.apply_field_effects(
               chunk,
               [{:set_tag, %{macro_index: macro_index, add: [:signal_high], remove: []}}],
               %{region_id: 704, kernel_id: :circuit_current}
             )

    # 真落 truth:该宏格 tag_set_ref 解出的 tag_ids 含 signal_high 的 id 13。
    storage = ChunkProcess.debug_state(chunk).storage
    block = Storage.normal_block_at(storage, macro_index)
    assert block.tag_set_ref > 0
    tag_ids = Enum.at(storage.tag_sets, block.tag_set_ref - 1).tag_ids
    assert 13 in tag_ids
  end

  test "ensure_field_region reuses an active source and emits source lifecycle observability", %{
    observe_log: observe_log
  } do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    source_index = Types.macro_index!({0, 0, 0})

    attrs = %{
      source_key: {:temperature, source_index},
      aabb: {{0, 0, 0}, {1, 1, 1}},
      kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
      source_points: [%{macro_index: source_index, field_type: :temperature, value: 100.0}],
      max_ticks: 100
    }

    assert {:ok,
            %{
              created?: true,
              region_id: region_id,
              region_action: :created,
              source_points_action: :seeded
            }} =
             ChunkProcess.ensure_field_region(chunk, attrs)

    assert {:ok,
            %{
              created?: false,
              region_id: ^region_id,
              region_action: :reused,
              source_points_action: :appended
            }} =
             ChunkProcess.ensure_field_region(chunk, %{
               attrs
               | source_points: [
                   %{macro_index: source_index, field_type: :temperature, value: 120.0}
                 ]
             })

    assert {:ok,
            %{
              created?: false,
              region_id: ^region_id,
              region_action: :reused,
              source_points_action: :rejected,
              source_points_rejection_reason: :missing_source_points
            }} =
             ChunkProcess.ensure_field_region(chunk, Map.delete(attrs, :source_points))

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 1
    assert debug.field_source_count == 1

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert observe_log_text =~ ~s(event="voxel_field_source_lifecycle")
    assert observe_log_text =~ "region_action: :created"
    assert observe_log_text =~ "region_action: :reused"
    assert observe_log_text =~ "source_points_action: :appended"
    assert observe_log_text =~ "source_points_action: :rejected"
    assert observe_log_text =~ "source_points_rejection_reason: :missing_source_points"
  end

  test "ensure_field_region reuses a stable region_id without registering a field source", %{
    observe_log: observe_log
  } do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    source_index = Types.macro_index!({0, 0, 0})

    attrs = %{
      region_id: 91_001,
      aabb: {{0, 0, 0}, {1, 1, 1}},
      kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
      source_points: [%{macro_index: source_index, field_type: :temperature, value: 100.0}],
      source_points_mode: :replace,
      max_ticks: 100
    }

    assert {:ok,
            %{
              created?: true,
              region_id: 91_001,
              region_action: :created,
              source_points_action: :seeded
            }} =
             ChunkProcess.ensure_field_region(chunk, attrs)

    assert {:ok,
            %{
              created?: false,
              region_id: 91_001,
              region_action: :reused,
              source_points_action: :replaced
            }} =
             ChunkProcess.ensure_field_region(chunk, %{
               attrs
               | source_points: [
                   %{macro_index: source_index, field_type: :temperature, value: 140.0}
                 ]
             })

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 1
    assert debug.field_source_count == 0

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert observe_log_text =~ ~s(event="voxel_field_source_lifecycle")
    assert observe_log_text =~ "region_id: 91001"
    assert observe_log_text =~ "region_action: :created"
    assert observe_log_text =~ "region_action: :reused"
    assert observe_log_text =~ "field_source_count: 0"
  end

  test "release_field_region_source destroys an active region by source key and releases its source",
       %{
         observe_log: observe_log
       } do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 58)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    source_index = Types.macro_index!({0, 0, 0})
    source_key = {:temperature, source_index}

    attrs = %{
      source_key: source_key,
      aabb: {{0, 0, 0}, {1, 1, 1}},
      kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
      source_points: [%{macro_index: source_index, field_type: :temperature, value: 100.0}],
      max_ticks: 100
    }

    assert {:ok, %{created?: true, region_id: region_id}} =
             ChunkProcess.ensure_field_region(chunk, attrs)

    assert {:ok,
            %{
              region_id: ^region_id,
              source_key: ^source_key,
              region_action: :destroyed,
              source_action: :released,
              destroy_reason: :temperature_within_environment_threshold
            }} =
             ChunkProcess.release_field_region_source(
               chunk,
               source_key,
               :temperature_within_environment_threshold
             )

    assert_receive {:voxel_field_region_destroyed_payload, destroyed_payload}
    destroyed = FieldCodec.decode_destroyed_payload!(destroyed_payload)
    assert destroyed.region_id == region_id
    assert destroyed.destroy_reason == :explicit

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 0
    assert debug.field_source_count == 0

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert observe_log_text =~ ~s(event="voxel_field_source_lifecycle")
    assert observe_log_text =~ "region_action: :destroyed"
    assert observe_log_text =~ "source_action: :released"
    assert observe_log_text =~ "destroy_reason: :temperature_within_environment_threshold"
    assert observe_log_text =~ ~s(event="voxel_field_region_destroyed_fanout")
  end

  test "expired field workers release their active source and emit lifecycle observability",
       %{observe_log: observe_log} do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 59)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    source_index = Types.macro_index!({0, 0, 0})
    target_index = Types.macro_index!({1, 0, 0})
    source_key = {:electric, {:device, "coil-7"}, source_index, target_index}

    attrs = %{
      source_key: source_key,
      aabb: {{0, 0, 0}, {1, 1, 1}},
      kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
      source_points: [%{macro_index: source_index, field_type: :temperature, value: 100.0}],
      max_ticks: 1
    }

    assert {:ok, %{created?: true, region_id: region_id}} =
             ChunkProcess.ensure_field_region(chunk, attrs)

    assert_receive {:voxel_field_region_destroyed_payload, destroyed_payload}, 1_000
    destroyed = FieldCodec.decode_destroyed_payload!(destroyed_payload)
    assert destroyed.region_id == region_id
    assert destroyed.destroy_reason == :expired

    assert_eventually(fn ->
      debug = ChunkProcess.debug_state(chunk)
      debug.field_region_count == 0 and debug.field_source_count == 0
    end)

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert observe_log_text =~ ~s(event="voxel_field_source_lifecycle")
    assert observe_log_text =~ ~s(source_key: "{:electric, {:device, \\"coil-7\\"})
    assert observe_log_text =~ "region_action: :expired"
    assert observe_log_text =~ "source_action: :expired"
    assert observe_log_text =~ "destroy_reason: :expired"
  end

  test "apply_intent writes a solid block, increments versions, and persists snapshots" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:ok,
            %{
              chunk_version: 1,
              persist_result: :inserted,
              snapshot_payload: first_payload
            }} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease,
                 request_id: 70,
                 macro: {0, 0, 0},
                 block: NormalBlockData.new(7, health: 25)
               )
             )

    assert {:ok, %{request_id: 70, storage: first_storage}} =
             Codec.decode_chunk_snapshot_payload(first_payload)

    assert first_storage.chunk_version == 1

    assert Storage.macro_header_at(first_storage, {0, 0, 0}).mode ==
             MacroCellHeader.cell_mode_solid_block()

    assert {:ok, %{chunk_version: 2, persist_result: :updated}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease,
                 request_id: 71,
                 macro: {1, 0, 0},
                 block: NormalBlockData.new(8, health: 30)
               )
             )

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
    assert snapshot.chunk_version == 2
    assert byte_size(snapshot.chunk_hash) == 8
    assert {:ok, %{storage: stored_storage}} = Codec.decode_chunk_snapshot_payload(snapshot.data)
    assert stored_storage.chunk_version == 2

    assert {:error, {:missing_lod_heightmap_cells, _meta}} =
             LodHeightmapStore.heightmap_region(1, 16, 16, 16, 1, 1)

    debug = ChunkProcess.debug_state(chunk)
    assert debug.chunk_version == 2
    assert debug.lease.lease_id == lease.lease_id
  end

  test "apply_intent reply carries the edited macro's authoritative cell state (point-correction channel)" do
    lease = start_snapshot_store()
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    macro_index = Types.macro_index!({0, 0, 0})

    # put_solid → authoritative reports the macro SOLID (payload_kind 1, non-empty payload).
    assert {:ok, %{changed?: true, chunk_version: 1, authoritative: [solid_cell]}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease,
                 request_id: 70,
                 macro: {0, 0, 0},
                 block: NormalBlockData.new(7)
               )
             )

    assert solid_cell.macro_index == macro_index
    assert solid_cell.payload_kind == 1
    assert solid_cell.chunk_version == 1
    assert byte_size(solid_cell.cell_payload) > 0

    # break (solid → air) → authoritative reports the macro EMPTY (payload_kind 0).
    assert {:ok, %{changed?: true, authoritative: [empty_cell]}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, request_id: 71, operation: :break_block, macro: {0, 0, 0})
             )

    assert empty_cell.macro_index == macro_index
    assert empty_cell.payload_kind == 0
    assert empty_cell.cell_payload == <<>>

    # NO-OP break on an already-empty macro (THE ghost case): even with changed?=false the reply
    # still carries authoritative=EMPTY, so a client holding a phantom solid there can self-correct
    # without a full-chunk resync. This is the explicit-contract fix for 2026-06-27 ghost blocks.
    assert {:ok, %{changed?: false, authoritative: [noop_cell]}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, request_id: 72, operation: :break_block, macro: {0, 0, 0})
             )

    assert noop_cell.macro_index == macro_index
    assert noop_cell.payload_kind == 0
    assert noop_cell.cell_payload == <<>>
  end

  test "subscribe re-sends the snapshot only when known_version is stale (resync version-dedup)" do
    lease = start_snapshot_store()
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    # Advance the chunk to version 1 (no subscriber yet → no stray push).
    assert {:ok, %{chunk_version: 1}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease,
                 request_id: 60,
                 macro: {0, 0, 0},
                 block: NormalBlockData.new(3)
               )
             )

    # known_version == current (1): subscription established WITHOUT re-snapshot. This is what makes a
    # known_version-carrying resubscribe (the Step B resync path) cheap when the client is already current.
    assert {:ok, _payload} =
             ChunkProcess.subscribe(chunk, self(), request_id: 80, known_version: 1)

    refute_receive {:voxel_chunk_snapshot_payload, _}

    # known_version stale (0 < current 1): the snapshot IS re-pushed — the version-driven re-snapshot the
    # resync path relies on to heal a diverged client without a full unsubscribe/resubscribe dance.
    assert {:ok, fresh} = ChunkProcess.subscribe(chunk, self(), request_id: 81, known_version: 0)
    assert_receive {:voxel_chunk_snapshot_payload, ^fresh}
    assert {:ok, %{storage: decoded}} = Codec.decode_chunk_snapshot_payload(fresh)
    assert decoded.chunk_version == 1

    # Missing-client sentinel: version 0 is a valid chunk version, so a client
    # cannot use 0 to mean "I do not have this chunk". The u64 max sentinel
    # must force a snapshot even when the authoritative chunk is still version 0.
    empty =
      start_supervised!(
        Supervisor.child_spec(
          {ChunkProcess, logical_scene_id: 1, chunk_coord: {91, 92, 93}},
          id: {:chunk_process_empty_sentinel, 91, 92, 93}
        )
      )

    assert {:ok, empty_payload} =
             ChunkProcess.subscribe(empty, self(),
               request_id: 82,
               known_version: 0xFFFF_FFFF_FFFF_FFFF
             )

    assert_receive {:voxel_chunk_snapshot_payload, ^empty_payload}
    assert {:ok, %{storage: empty_decoded}} = Codec.decode_chunk_snapshot_payload(empty_payload)
    assert empty_decoded.chunk_version == 0
  end

  test "apply_intent skips identical solid cells without persisting or pushing deltas" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    block = NormalBlockData.new(7)

    assert {:ok, %{chunk_version: 1, changed?: true}} =
             ChunkProcess.apply_intent(chunk, intent_attrs(lease, macro: {0, 0, 0}, block: block))

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 72)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok,
            %{
              chunk_version: 1,
              changed?: false,
              persist_result: :unchanged,
              snapshot_payload: noop_payload
            }} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, request_id: 73, macro: {0, 0, 0}, block: block)
             )

    refute_received {:voxel_chunk_delta_payload, _payload}
    refute_received {:voxel_chunk_snapshot_payload, _payload}

    assert {:ok, %{request_id: 73, storage: noop_storage}} =
             Codec.decode_chunk_snapshot_payload(noop_payload)

    assert noop_storage.chunk_version == 1
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
    assert snapshot.chunk_version == 1
  end

  test "apply_intents batches many cells into one chunk version and one persist" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    attrs =
      for x <- 0..2 do
        intent_attrs(lease, request_id: 80 + x, macro: {x, 0, 0}, block: NormalBlockData.new(5))
      end

    assert {:ok,
            %{
              chunk_version: 1,
              changed?: true,
              changed_count: 3,
              skipped_count: 0,
              # D-4(AUTH-2):durable-before-ack —— 同步落库后返回真实 persist_result(不再异步 :queued)
              persist_result: :inserted,
              persist_ref: persist_ref,
              snapshot_payload: payload
            }} = ChunkProcess.apply_intents(chunk, attrs)

    assert is_integer(persist_ref)
    assert {:ok, %{storage: storage}} = Codec.decode_chunk_snapshot_payload(payload)
    assert storage.chunk_version == 1

    Enum.each(0..2, fn x ->
      assert Storage.macro_header_at(storage, {x, 0, 0}).mode ==
               MacroCellHeader.cell_mode_solid_block()
    end)

    assert :ok = ChunkProcess.flush_persistence(chunk)
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
    assert snapshot.chunk_version == 1
  end

  test "apply_intents automatically starts current for closed source-load loop topology" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 81)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    attrs = closed_loop_intents(lease, 81)

    assert {:ok, %{changed?: true, changed_count: 8}} = ChunkProcess.apply_intents(chunk, attrs)
    assert_receive {:voxel_chunk_delta_payload, _delta_payload}, 1_000

    assert_receive {:voxel_field_region_snapshot_payload, field_payload}, 1_000
    decoded = FieldCodec.decode_snapshot_payload!(field_payload)

    assert Bitwise.band(decoded.field_mask, FieldCodec.field_mask_electric_current()) != 0

    assert decoded.macro_indices == closed_loop_macro_indices()

    assert Enum.all?(decoded.electric_current_values, &(&1 > 0.0))

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 1
    assert debug.field_source_count == 1
  end

  test "subscribe rebuilds current overlay for an existing closed source-load loop topology" do
    storage =
      Storage.empty(1, {0, 0, 0})
      |> put_closed_loop_blocks()

    chunk =
      start_supervised!(
        {ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}, storage: storage}
      )

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 90)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert_receive {:voxel_field_region_snapshot_payload, field_payload}, 1_000
    decoded = FieldCodec.decode_snapshot_payload!(field_payload)

    assert Bitwise.band(decoded.field_mask, FieldCodec.field_mask_electric_current()) != 0
    assert Enum.all?(decoded.electric_current_values, &(&1 > 0.0))

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 1
    assert debug.field_source_count == 1
  end

  test "统一 sweep:闭合电路 + glowstone 共存 → 电路 region 与 Emergence region 同起(count==2)" do
    # 框架核心保证:一次 sweep 遍历全部 provisioner,各自独立 ensure(source_key 各异、
    # 互不干扰)。chunk 同时含闭合电路(power+load+回路 → electric)与 glowstone(发光体
    # → emergence)→ 两个 field region 共存。
    storage =
      Storage.empty(1, {0, 0, 0})
      |> put_closed_loop_blocks()
      # glowstone(id 19)放电路环外的低 index 自由格(不破回路、emergence AABB 小且快)。
      |> Storage.put_solid_block({4, 0, 0}, NormalBlockData.new(19))

    chunk =
      start_supervised!(
        {ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}, storage: storage}
      )

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 91)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    # 订阅触发 sweep → electric 与 emergence 都 active → 两个 region 共存。
    assert poll_field_region_count(chunk, 2, 5_000),
           "电路 + glowstone 应共存两个 field region;实际 " <>
             "#{ChunkProcess.debug_state(chunk).field_region_count}"

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 2
    assert debug.field_source_count == 2
  end

  test "apply_intent automatically releases the current field after the load is removed" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 84)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    attrs = closed_loop_intents(lease, 84)

    assert {:ok, %{changed?: true}} = ChunkProcess.apply_intents(chunk, attrs)
    assert_receive {:voxel_chunk_delta_payload, _delta_payload}, 1_000
    assert_receive {:voxel_field_region_snapshot_payload, _field_payload}, 1_000
    assert ChunkProcess.debug_state(chunk).field_region_count == 1

    assert {:ok, %{changed?: true}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, request_id: 87, operation: :break_block, macro: {2, 0, 0})
             )

    assert_receive {:voxel_field_region_destroyed_payload, destroyed_payload}, 1_000
    decoded = FieldCodec.decode_destroyed_payload!(destroyed_payload)
    assert decoded.chunk_coord == {1, 1, 1}
    assert decoded.destroy_reason == :explicit

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 0
    assert debug.field_source_count == 0
  end

  test "breaking a closed loop conductor destroys the automatic current field" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 91)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok, %{changed?: true}} =
             ChunkProcess.apply_intents(chunk, closed_loop_intents(lease, 91))

    assert_receive {:voxel_chunk_delta_payload, _delta_payload}, 1_000

    assert_receive {:voxel_field_region_snapshot_payload, active_payload}, 1_000
    active = FieldCodec.decode_snapshot_payload!(active_payload)
    assert active.macro_indices == closed_loop_macro_indices()
    assert Enum.all?(active.electric_current_values, &(&1 > 0.0))

    assert {:ok, %{changed?: true}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, request_id: 99, operation: :break_block, macro: {2, 1, 0})
             )

    assert_receive {:voxel_field_region_destroyed_payload, destroyed_payload}, 1_000
    destroyed = FieldCodec.decode_destroyed_payload!(destroyed_payload)
    assert destroyed.chunk_coord == {1, 1, 1}
    assert destroyed.destroy_reason == :explicit

    debug = ChunkProcess.debug_state(chunk)
    assert debug.field_region_count == 0
    assert debug.field_source_count == 0
  end

  test "auto circuit refresh coalesces adjacent open mutations without allocating a field",
       %{observe_log: observe_log} do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 88)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, {3, 0, 0}, NormalBlockData.new(6))

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, {4, 0, 0}, NormalBlockData.new(5))

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, {5, 0, 0}, NormalBlockData.new(7))

    refute_receive {:voxel_field_region_snapshot_payload, _field_payload}, 500
    assert ChunkProcess.debug_state(chunk).field_region_count == 0
    assert ChunkProcess.debug_state(chunk).field_source_count == 0

    CliObserve.flush()
    observe_log_text = File.read!(observe_log)

    assert Regex.scan(~r/event="voxel_auto_circuit_refreshed"/, observe_log_text)
           |> length() == 1

    assert observe_log_text =~ "action: :released"
    assert observe_log_text =~ "reason: :no_closed_circuit"
  end

  test "apply_intent rejects missing leases without mutating or persisting" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    attrs = lease |> intent_attrs() |> Map.delete(:lease)

    assert {:error, :missing_lease} = ChunkProcess.apply_intent(chunk, attrs)
    assert ChunkProcess.debug_state(chunk).chunk_version == 0

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
  end

  test "apply_intent rejects expired leases without mutating or persisting" do
    expired_lease = %{lease() | expires_at_ms: System.system_time(:millisecond) - 1}
    _lease = start_snapshot_store(expired_lease)

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:error, :lease_expired} =
             ChunkProcess.apply_intent(chunk, intent_attrs(expired_lease))

    assert ChunkProcess.debug_state(chunk).chunk_version == 0

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
  end

  test "apply_intent rejects lease identity mismatches without mutating or persisting" do
    stale_lease = lease()

    current_lease = %{
      stale_lease
      | lease_id: 101,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 2
    }

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(Map.put(current_lease, :token_version, 2))

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:error, :lease_id_mismatch} =
             ChunkProcess.apply_intent(chunk, intent_attrs(stale_lease))

    assert ChunkProcess.debug_state(chunk).chunk_version == 0

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
  end

  test "apply_intent pushes a CellSolid ChunkDelta to subscribers after persistence" do
    lease = start_snapshot_store()

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 88)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    block = NormalBlockData.new(9)

    assert {:ok, %{chunk_version: 1}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, macro: {2, 0, 0}, block: block)
             )

    assert_receive {:voxel_chunk_delta_payload, delta_payload}
    refute delta_payload == initial_payload

    assert {:ok, decoded} = Codec.decode_chunk_delta_payload(delta_payload)
    assert decoded.logical_scene_id == 1
    assert decoded.chunk_coord == {1, 1, 1}
    assert decoded.base_chunk_version == 0
    assert decoded.new_chunk_version == 1

    assert [%{delta_kind: 1, cell_version: 1, payload: block_payload}] = decoded.ops
    assert Codec.decode_normal_block_data(block_payload) == NormalBlockData.normalize!(block)
  end

  test "invalidate_subscribers pushes a ChunkInvalidate payload and drops every subscriber" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self())
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok, %{subscriber_count: 1, reason: 0x01}} =
             ChunkProcess.invalidate_subscribers(chunk, 0x01)

    assert_receive {:voxel_chunk_invalidate_payload, payload}
    assert {:ok, decoded} = Codec.decode_chunk_invalidate_payload(payload)
    assert decoded.logical_scene_id == 1
    assert decoded.chunk_coord == {0, 0, 0}
    assert decoded.reason == 0x01
    assert decoded.reason_name == :migration_cutover

    # Subscriber list is now empty so subsequent edits do not push back.
    assert ChunkProcess.debug_state(chunk).subscriber_count == 0
  end

  test "unsubscribe stops future snapshot fallback pushes" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self())
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert :ok = ChunkProcess.unsubscribe(chunk, self())
    assert ChunkProcess.debug_state(chunk).subscriber_count == 0

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2),
               cell_version: 1
             )

    refute_received {:voxel_chunk_snapshot_payload, _payload}
  end

  test "dead subscribers are removed by monitor cleanup" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    parent = self()

    subscriber =
      spawn(fn ->
        case ChunkProcess.subscribe(chunk, self()) do
          {:ok, payload} ->
            receive do
              {:voxel_chunk_snapshot_payload, ^payload} ->
                send(parent, :subscriber_received_snapshot)
            after
              500 ->
                send(parent, :subscriber_snapshot_timeout)
            end

          other ->
            send(parent, {:subscriber_error, other})
        end
      end)

    monitor_ref = Process.monitor(subscriber)

    assert_receive :subscriber_received_snapshot
    assert_receive {:DOWN, ^monitor_ref, :process, ^subscriber, :normal}

    assert_eventually(fn ->
      ChunkProcess.debug_state(chunk).subscriber_count == 0
    end)
  end

  test "persists snapshots through DataService write-token fence" do
    lease = lease()

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(Map.put(lease, :token_version, 1))

    chunk =
      start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}, lease: lease})

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, 0, NormalBlockData.new(7), cell_version: 1)

    assert {:ok, :inserted} = ChunkProcess.persist(chunk)
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})

    assert snapshot.chunk_version == 1
    assert byte_size(snapshot.chunk_hash) == 8
    assert {:ok, %{storage: decoded_storage}} = Codec.decode_chunk_snapshot_payload(snapshot.data)
    assert decoded_storage.chunk_version == 1
  end

  test "stale lease cannot persist after token advances" do
    lease_v1 = lease()
    lease_v2 = %{lease_v1 | lease_id: 101, owner_scene_instance_ref: 2_000, owner_epoch: 2}

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(Map.put(lease_v1, :token_version, 1))

    assert {:ok, :updated} =
             WriteTokenStore.upsert_token(Map.put(lease_v2, :token_version, 2))

    chunk =
      start_supervised!(
        {ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}, lease: lease_v1}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, 0, NormalBlockData.new(7), cell_version: 1)

    assert {:error, :lease_id_mismatch} = ChunkProcess.persist(chunk)
  end

  describe "Phase 1c — :put_micro_block / :clear_micro_block intents" do
    test "apply_intent :put_micro_block writes a refined slot, bumps versions, persists snapshot" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, %{chunk_version: 1, persist_result: :inserted}} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :put_micro_block,
                   macro: {2, 0, 0},
                   micro_slot: 5,
                   micro_layer: %{material_id: 17, health: 100}
                 )
               )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})
      assert snapshot.chunk_version == 1

      assert {:ok, %{storage: stored_storage}} =
               Codec.decode_chunk_snapshot_payload(snapshot.data)

      header = Storage.macro_header_at(stored_storage, {2, 0, 0})
      assert header.mode == MacroCellHeader.cell_mode_refined()

      cell = Storage.refined_cell_at(stored_storage, {2, 0, 0})
      [layer] = cell.layers
      assert layer.material_id == 17
      assert layer.health == 100
      expected_word = Bitwise.bsl(1, 5)
      assert cell.occupancy_words == [expected_word, 0, 0, 0, 0, 0, 0, 0]
    end

    test "apply_intent :put_micro_block on already-occupied slot returns :micro_slot_already_occupied" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :put_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5,
                   micro_layer: %{material_id: 17}
                 )
               )

      assert {:error, :micro_slot_already_occupied} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :put_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5,
                   micro_layer: %{material_id: 99}
                 )
               )
    end

    test "apply_intent :clear_micro_block clears the slot and downgrades to empty when last" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      put = fn slot, mat ->
        ChunkProcess.apply_intent(
          chunk,
          micro_intent_attrs(lease,
            operation: :put_micro_block,
            macro: {0, 0, 0},
            micro_slot: slot,
            micro_layer: %{material_id: mat}
          )
        )
      end

      assert {:ok, _} = put.(5, 17)
      assert {:ok, _} = put.(9, 17)

      # Clear slot 5 — cell should still be refined with one slot remaining.
      assert {:ok, %{chunk_version: 3}} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :clear_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5
                 )
               )

      # Clear slot 9 — cell becomes empty, header downgrades.
      assert {:ok, %{chunk_version: 4}} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :clear_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 9
                 )
               )

      assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(1, {1, 1, 1})

      assert {:ok, %{storage: stored_storage}} =
               Codec.decode_chunk_snapshot_payload(snapshot.data)

      header = Storage.macro_header_at(stored_storage, {0, 0, 0})
      assert header.mode == MacroCellHeader.cell_mode_empty()
    end

    test "apply_intent :clear_micro_block on empty slot is a noop (no version bump)" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, %{chunk_version: 0, changed?: false, persist_result: :unchanged}} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :clear_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5
                 )
               )
    end

    test "apply_intent :put_micro_block on a solid macro is rejected" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease, macro: {0, 0, 0}, block: NormalBlockData.new(11))
               )

      # Decision 2 / Phase 1c v1: solid macros do NOT auto-promote to refined
      # under a micro write. Surface the specific reason so client UX can
      # explain why the click was a no-op.
      assert {:error, :cannot_micro_edit_solid_macro} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :put_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5,
                   micro_layer: %{material_id: 17}
                 )
               )

      assert {:error, :cannot_micro_edit_solid_macro} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :clear_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5
                 )
               )
    end

    test "apply_intent rejects micro_slot out of 0..511" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      for bad <- [-1, 512, 1024] do
        assert {:error, :invalid_micro_slot} =
                 ChunkProcess.apply_intent(
                   chunk,
                   micro_intent_attrs(lease,
                     operation: :put_micro_block,
                     macro: {0, 0, 0},
                     micro_slot: bad,
                     micro_layer: %{material_id: 1}
                   )
                 )
      end
    end

    test "apply_intent :put_micro_block requires micro_layer" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      attrs =
        micro_intent_attrs(lease,
          operation: :put_micro_block,
          macro: {0, 0, 0},
          micro_slot: 5
        )
        |> Map.delete(:micro_layer)

      assert {:error, :missing_micro_layer} = ChunkProcess.apply_intent(chunk, attrs)
    end

    test "subscribers receive a CellRefined ChunkDelta (delta_kind=2) after a micro put" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 200)
      assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :put_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5,
                   micro_layer: %{material_id: 17}
                 )
               )

      assert_receive {:voxel_chunk_delta_payload, delta_payload}
      refute_received {:voxel_chunk_snapshot_payload, _}

      assert {:ok, delta} = Codec.decode_chunk_delta_payload(delta_payload)
      assert [op] = delta.ops
      assert op.delta_kind == 2
      assert op.macro_index == 0

      # The op payload is a single-cell RefinedCellData (delta_kind=2 wire).
      assert {:ok, cell} = Codec.decode_refined_cell_payload(op.payload)
      [layer] = cell.layers
      assert layer.material_id == 17
      assert cell.occupancy_words == [Bitwise.bsl(1, 5), 0, 0, 0, 0, 0, 0, 0]
    end

    test "subscribers receive CellEmpty ChunkDelta (delta_kind=0) when last slot is cleared" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :put_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5,
                   micro_layer: %{material_id: 17}
                 )
               )

      assert {:ok, _} = ChunkProcess.subscribe(chunk, self(), request_id: 201)
      assert_receive {:voxel_chunk_snapshot_payload, _initial}

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :clear_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5
                 )
               )

      assert_receive {:voxel_chunk_delta_payload, delta_payload}
      assert {:ok, delta} = Codec.decode_chunk_delta_payload(delta_payload)
      assert [op] = delta.ops
      assert op.delta_kind == 0
      assert op.payload == <<>>
    end

    test "clear_micro_block leaves a refined cell ChunkDelta (delta_kind=2) when slots remain" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      put = fn slot, mat ->
        ChunkProcess.apply_intent(
          chunk,
          micro_intent_attrs(lease,
            operation: :put_micro_block,
            macro: {0, 0, 0},
            micro_slot: slot,
            micro_layer: %{material_id: mat}
          )
        )
      end

      assert {:ok, _} = put.(5, 17)
      assert {:ok, _} = put.(9, 17)

      assert {:ok, _} = ChunkProcess.subscribe(chunk, self(), request_id: 202)
      assert_receive {:voxel_chunk_snapshot_payload, _initial}

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 micro_intent_attrs(lease,
                   operation: :clear_micro_block,
                   macro: {0, 0, 0},
                   micro_slot: 5
                 )
               )

      assert_receive {:voxel_chunk_delta_payload, delta_payload}
      assert {:ok, delta} = Codec.decode_chunk_delta_payload(delta_payload)
      assert [op] = delta.ops
      assert op.delta_kind == 2

      assert {:ok, cell} = Codec.decode_refined_cell_payload(op.payload)
      [layer] = cell.layers
      assert layer.mask_words == [Bitwise.bsl(1, 9), 0, 0, 0, 0, 0, 0, 0]
    end
  end

  describe "Phase 1c — expected_chunk_version / expected_cell_hash optimistic concurrency" do
    test "apply_intent rejects when expected_chunk_version does not match current version" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, %{chunk_version: 1}} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease, macro: 0, block: NormalBlockData.new(7))
               )

      # Current version is 1; client believes it is still 0.
      assert {:error, :stale_chunk_version} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease,
                   macro: 1,
                   block: NormalBlockData.new(8),
                   expected_chunk_version: 0
                 )
               )

      # State unchanged — chunk still at version 1, only macro 0 written.
      assert ChunkProcess.debug_state(chunk).chunk_version == 1
    end

    test "apply_intent accepts when expected_chunk_version matches current version" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, %{chunk_version: 1}} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease, macro: 0, block: NormalBlockData.new(7))
               )

      assert {:ok, %{chunk_version: 2}} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease,
                   macro: 1,
                   block: NormalBlockData.new(8),
                   expected_chunk_version: 1
                 )
               )
    end

    test "apply_intent treats 0xFFFF...FFFF expected_chunk_version sentinel as unspecified" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      # Bump current chunk_version to 1 first.
      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease, macro: 0, block: NormalBlockData.new(7))
               )

      # Sentinel value should bypass the precondition — write succeeds even
      # though chunk_version is no longer the wire's "max u64" placeholder.
      assert {:ok, %{chunk_version: 2}} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease,
                   macro: 1,
                   block: NormalBlockData.new(8),
                   expected_chunk_version: 0xFFFF_FFFF_FFFF_FFFF
                 )
               )
    end

    test "apply_intent reconciles durable newer snapshot before unpinned writes" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 502)
      assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

      canonical_storage = Storage.empty(1, {1, 1, 1}, chunk_version: 5)
      put_canonical_snapshot!(lease, canonical_storage)

      assert {:ok, %{chunk_version: 6, persist_result: :updated}} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease, macro: 0, block: NormalBlockData.new(8))
               )

      assert_receive {:voxel_chunk_snapshot_payload, recovery_payload}

      assert {:ok, %{storage: recovered_storage}} =
               Codec.decode_chunk_snapshot_payload(recovery_payload)

      assert recovered_storage.chunk_version == 5

      assert_receive {:voxel_chunk_delta_payload, delta_payload}
      assert {:ok, delta} = Codec.decode_chunk_delta_payload(delta_payload)
      assert delta.base_chunk_version == 5
      assert delta.new_chunk_version == 6

      assert ChunkProcess.debug_state(chunk).chunk_version == 6
    end

    test "apply_intent rejects when expected_cell_hash does not match macro header" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, _} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease, macro: 0, block: NormalBlockData.new(7), cell_hash: 0xABCD)
               )

      assert {:error, :stale_cell_hash} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease,
                   macro: 0,
                   block: NormalBlockData.new(8),
                   expected_cell_hash: 0xDEAD
                 )
               )
    end

    test "apply_intent treats 0xFFFF_FFFF expected_cell_hash sentinel as unspecified" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:ok, %{chunk_version: 1}} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease,
                   macro: 0,
                   block: NormalBlockData.new(7),
                   expected_cell_hash: 0xFFFF_FFFF
                 )
               )
    end

    test "apply_intent rejects garbage expected_chunk_version up front" do
      lease = start_snapshot_store()

      chunk =
        start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {1, 1, 1}})

      assert {:error, :invalid_expected_chunk_version} =
               ChunkProcess.apply_intent(
                 chunk,
                 intent_attrs(lease,
                   macro: 0,
                   block: NormalBlockData.new(7),
                   expected_chunk_version: -1
                 )
               )
    end
  end

  defp lease do
    %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }
  end

  # Phase 1d helper: ensures the global WriteTokenStore knows about the test
  # lease and clears any previous voxel_chunks rows. Returns the lease the
  # caller should plumb through ChunkProcess intents.
  defp start_snapshot_store(token \\ lease()) do
    assert {:ok, _} =
             WriteTokenStore.upsert_token(Map.put(token, :token_version, 1))

    token
  end

  defp intent_attrs(lease, overrides \\ []) do
    %{
      request_id: 70,
      logical_scene_id: lease.logical_scene_id,
      chunk_coord: {1, 1, 1},
      lease: lease,
      operation: :put_solid_block,
      macro: 0,
      block: NormalBlockData.new(7)
    }
    |> Map.merge(Map.new(overrides))
  end

  defp closed_loop_intents(lease, first_request_id) do
    closed_loop_blocks()
    |> Enum.with_index(first_request_id)
    |> Enum.map(fn {{coord, material_id}, request_id} ->
      intent_attrs(lease,
        request_id: request_id,
        macro: coord,
        block: NormalBlockData.new(material_id)
      )
    end)
  end

  defp put_closed_loop_blocks(%Storage{} = storage) do
    Enum.reduce(closed_loop_blocks(), storage, fn {coord, material_id}, acc ->
      Storage.put_solid_block(acc, coord, NormalBlockData.new(material_id))
    end)
  end

  defp closed_loop_blocks do
    [
      {{0, 0, 0}, 6},
      {{1, 0, 0}, 5},
      {{2, 0, 0}, 7},
      {{2, 1, 0}, 5},
      {{2, 2, 0}, 5},
      {{1, 2, 0}, 5},
      {{0, 2, 0}, 5},
      {{0, 1, 0}, 5}
    ]
  end

  defp closed_loop_macro_indices do
    closed_loop_blocks()
    |> Enum.map(fn {coord, _material_id} -> Types.macro_index!(coord) end)
    |> Enum.sort()
  end

  defp poll_field_region_count(chunk, target, timeout_ms, waited \\ 0) do
    cond do
      ChunkProcess.debug_state(chunk).field_region_count == target ->
        true

      waited >= timeout_ms ->
        false

      true ->
        Process.sleep(25)
        poll_field_region_count(chunk, target, timeout_ms, waited + 25)
    end
  end

  defp micro_intent_attrs(lease, overrides) do
    %{
      request_id: 70,
      logical_scene_id: lease.logical_scene_id,
      chunk_coord: {1, 1, 1},
      lease: lease,
      operation: :put_micro_block,
      macro: {0, 0, 0},
      micro_slot: 0,
      micro_layer: %{material_id: 1, health: 100}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp put_canonical_snapshot!(lease, %Storage{} = storage) do
    payload = Codec.encode_chunk_snapshot_payload(%{request_id: 0, storage: storage})

    attrs =
      lease
      |> Map.take([
        :logical_scene_id,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch
      ])
      |> Map.merge(%{
        chunk_coord: storage.chunk_coord,
        schema_version: storage.schema_version,
        chunk_size_in_macro: storage.chunk_size_in_macro,
        micro_resolution: storage.micro_resolution,
        chunk_version: storage.chunk_version,
        chunk_hash: Hash.encode64(Codec.chunk_hash(storage)),
        data: payload
      })

    assert {:ok, _result} = ChunkSnapshotStore.put_snapshot(attrs)
    payload
  end

  defp assert_eventually(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    assert_eventually(fun, deadline, timeout_ms)
  end

  defp assert_eventually(fun, deadline, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true within #{timeout_ms}ms")
      else
        receive do
        after
          10 -> assert_eventually(fun, deadline, timeout_ms)
        end
      end
    end
  end
end
