defmodule SceneServer.Voxel.Field.FieldRuntimeTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.FieldCodec
  alias SceneServer.Voxel.Field.FieldLayer
  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Field.FieldSource
  alias SceneServer.Voxel.Field.FieldRuntime
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Field.TemperatureField
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.CombustionKernel
  alias SceneServer.Voxel.Phenomenon.PhaseChangeKernel
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    SceneServer.TestVoxelRuntime.ensure_started!()

    :ok
  end

  @fixed32_scale 65_536
  @dirt_material_id 1
  @iron_material_id 5
  @power_block_material_id 6
  @load_block_material_id 7

  defp solid_storage_with_temperature_delta(world_macro, delta_celsius) do
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    macro_index = Types.macro_index!(local_macro)
    raw_delta = round(delta_celsius * @fixed32_scale)

    storage =
      Storage.new(7, chunk_coord)
      |> Storage.put_solid_block(macro_index, NormalBlockData.new(1))
      |> Storage.put_attribute_for_cell(macro_index, "temperature", raw_delta)

    {storage, local_macro, macro_index}
  end

  defp with_observe_log(fun) do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    observe_log =
      Path.join(
        System.tmp_dir!(),
        "scene-field-runtime-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)
    Application.put_env(:scene_server, :cli_observe_log, observe_log)

    try do
      fun.(observe_log)
    after
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end

      File.rm(observe_log)
    end
  end

  describe "ensure_temperature_anomaly/1" do
    test "default heat skill targets 800C and reports the real iron heat budget" do
      logical_scene_id = 71_000 + System.unique_integer([:positive])
      world_macro = {0, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 world_macro,
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_temperature_anomaly(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 max_ticks: 100
               )

      assert summary.target_temperature == 800.0
      assert summary.attribute_write.target_temperature == 800.0
      assert summary.attribute_write.density == 7_870.0
      assert summary.attribute_write.specific_heat_capacity == 449.0
      assert_in_delta summary.attribute_write.heat_energy_joules, 2_756_231_400.0, 1.0
    end

    test "set temperature supports cooling to 0C through target temperature" do
      logical_scene_id = 72_000 + System.unique_integer([:positive])
      world_macro = {0, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk_pid, world_macro, NormalBlockData.new(1))

      assert {:ok, summary} =
               FieldRuntime.ensure_set_temperature(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 target_temperature_celsius: 0,
                 max_ticks: 100
               )

      assert summary.target_temperature == 0.0
      assert summary.anomaly_delta == -20.0
      assert summary.attribute_write.target_temperature == 0.0
      assert summary.attribute_write.heat_energy_joules < 0
      assert summary.field_region_created == true
      assert summary.source.source_kind == :temperature
      assert summary.source.source_mode == :impulse
      assert summary.source.source_key == {:temperature, Types.macro_index!({0, 0, 0})}
      assert summary.source.target_value == 0.0
      assert summary.source.source_value == 0.0
    end

    test "reuses the active field source for repeated heat on the same voxel" do
      logical_scene_id = 70_000 + System.unique_integer([:positive])
      world_macro = {0, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk_pid, world_macro, NormalBlockData.new(1))

      assert {:ok, first} =
               FieldRuntime.ensure_temperature_anomaly(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 heat_energy_joules: 2_560_000,
                 max_ticks: 100
               )

      assert first.field_region_created == true

      assert {:ok, second} =
               FieldRuntime.ensure_temperature_anomaly(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 heat_energy_joules: 2_560_000,
                 max_ticks: 100
               )

      assert second.region_id == first.region_id
      assert second.field_region_created == false
    end

    test "set temperature to ambient destroys the active field region when the anomaly falls below threshold" do
      logical_scene_id = 73_000 + System.unique_integer([:positive])
      world_macro = {0, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk_pid, world_macro, NormalBlockData.new(1))

      assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk_pid, self(), request_id: 730)
      assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

      assert {:ok, hot_summary} =
               FieldRuntime.ensure_set_temperature(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 target_temperature_celsius: 800,
                 max_ticks: 100
               )

      region_id = hot_summary.region_id
      assert hot_summary.field_region_created == true
      assert hot_summary.source.source_mode == :impulse
      assert ChunkProcess.debug_state(chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(chunk_pid).field_source_count == 1

      assert {:ok, ambient_summary} =
               FieldRuntime.ensure_set_temperature(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 target_temperature_celsius: 20,
                 max_ticks: 100
               )

      assert ambient_summary.created == false
      assert ambient_summary.reason == :temperature_within_environment_threshold
      assert ambient_summary.target_temperature == 20.0
      assert ambient_summary.field_region_created == false

      assert ambient_summary.field_region_cleanup == %{
               region_action: :destroyed,
               source_action: :released,
               destroy_reason: :temperature_within_environment_threshold,
               region_id: region_id,
               source_key: {:temperature, Types.macro_index!(world_macro)}
             }

      assert_receive {:voxel_field_region_destroyed_payload, destroyed_payload}
      destroyed = FieldCodec.decode_destroyed_payload!(destroyed_payload)
      assert destroyed.region_id == region_id
      assert destroyed.destroy_reason == :explicit

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "restore_ambient destroys the active field region through the same cleanup path" do
      logical_scene_id = 74_000 + System.unique_integer([:positive])
      world_macro = {1, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(chunk_pid, world_macro, NormalBlockData.new(1))

      assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk_pid, self(), request_id: 740)
      assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

      assert {:ok, hot_summary} =
               FieldRuntime.ensure_set_temperature(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 target_temperature_celsius: 800,
                 max_ticks: 100
               )

      region_id = hot_summary.region_id
      assert hot_summary.field_region_created == true

      assert {:ok, restore_summary} =
               FieldRuntime.ensure_set_temperature(
                 logical_scene_id: logical_scene_id,
                 world_macro: world_macro,
                 restore_ambient: true,
                 max_ticks: 100
               )

      assert restore_summary.created == false
      assert restore_summary.reason == :temperature_within_environment_threshold
      assert restore_summary.target_temperature == 20.0
      assert restore_summary.attribute_write.target_temperature == 20.0
      assert restore_summary.field_region_created == false

      assert restore_summary.field_region_cleanup == %{
               region_action: :destroyed,
               source_action: :released,
               destroy_reason: :temperature_within_environment_threshold,
               region_id: region_id,
               source_key: {:temperature, Types.macro_index!(world_macro)}
             }

      assert_receive {:voxel_field_region_destroyed_payload, destroyed_payload}
      destroyed = FieldCodec.decode_destroyed_payload!(destroyed_payload)
      assert destroyed.region_id == region_id
      assert destroyed.destroy_reason == :explicit

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end
  end

  describe "ensure_conduction_path/1" do
    test "creates a same-chunk electric discharge region through dielectric medium" do
      logical_scene_id = 75_050 + System.unique_integer([:positive])
      source_world_macro = {0, 0, 0}
      target_world_macro = {3, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 target_world_macro,
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 source_potential: 120,
                 max_ticks: 60,
                 radius: 0,
                 max_frontier: 32,
                 conduction_mode: :discharge
               )

      assert summary.created == true
      assert summary.field_region_created == true
      assert summary.conduction_mode == :discharge
      assert summary.field_types == ["electric_potential", "ionization"]

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 1
      assert debug.field_source_count == 1
    end

    test "rejects low-energy electric discharge before allocating a region" do
      logical_scene_id = 75_075 + System.unique_integer([:positive])
      source_world_macro = {0, 0, 0}
      target_world_macro = {3, 0, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 target_world_macro,
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:error, {:conduction_path_failed, :no_discharge_path}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 source_potential: 2,
                 max_ticks: 60,
                 radius: 0,
                 max_frontier: 32,
                 conduction_mode: :discharge
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "creates a same-chunk ConductionPathKernel region from a physical power block" do
      logical_scene_id = 75_000 + System.unique_integer([:positive])
      source_world_macro = {0, 1, 0}
      target_world_macro = {3, 1, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@power_block_material_id)
               )

      for coord <- [
            target_world_macro,
            {0, 0, 0},
            {1, 0, 0},
            {2, 0, 0},
            {3, 0, 0}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 max_ticks: 90,
                 radius: 1,
                 max_frontier: 64
               )

      source_index = Types.macro_index!(source_world_macro)
      target_index = Types.macro_index!(target_world_macro)

      assert summary.created == true
      assert summary.field_region_created == true
      assert summary.field_types == ["electric_potential", "ionization"]
      assert summary.region_id

      assert summary.source_key ==
               {:electric, {:power_block, source_index}, source_index, target_index}

      assert summary.source_index == source_index
      assert summary.target_index == target_index
      assert summary.source_world_macro == %{x: 0, y: 1, z: 0}
      assert summary.target_world_macro == %{x: 3, y: 1, z: 0}
      assert summary.source_potential == 120.0

      assert summary.source.owner_ref == %{
               kind: :power_block,
               id: source_index,
               logical_scene_id: logical_scene_id,
               world_macro: %{x: 0, y: 1, z: 0},
               material_id: @power_block_material_id
             }

      assert summary.source.power_source.output_mode == :dc
      assert summary.source.power_source.current_limit_amps == 20.0
      assert summary.source.power_source.energy_budget_joules == 20_000.0
      assert summary.max_ticks == 90
      assert summary.max_frontier == 64
      assert summary.source_points_action == :seeded

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 1
      assert debug.field_source_count == 1
    end

    test "rejects a conductive iron source when no physical or explicit power source exists" do
      logical_scene_id = 75_125 + System.unique_integer([:positive])
      source_world_macro = {0, 1, 0}
      target_world_macro = {3, 1, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      for coord <- [
            source_world_macro,
            target_world_macro,
            {0, 0, 0},
            {1, 0, 0},
            {2, 0, 0},
            {3, 0, 0}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:error, {:conduction_path_failed, :source_not_powered}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 source_potential: 120,
                 max_ticks: 90
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "threads electric FieldSource owner ttl and budget into the region summary" do
      logical_scene_id = 75_250 + System.unique_integer([:positive])
      source_world_macro = {0, 1, 0}
      target_world_macro = {3, 1, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      for coord <- [
            source_world_macro,
            target_world_macro,
            {0, 0, 0},
            {1, 0, 0},
            {2, 0, 0},
            {3, 0, 0}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 source_potential: 150,
                 max_ticks: 90,
                 ttl_ticks: 45,
                 radius: 1,
                 max_frontier: 64,
                 energy_budget_joules: 5_000,
                 source_mode: :persistent,
                 owner_ref: %{kind: :device, id: "coil-7"}
               )

      source_index = Types.macro_index!(source_world_macro)
      target_index = Types.macro_index!(target_world_macro)

      assert summary.max_ticks == 45
      assert summary.source_key == {:electric, {:device, "coil-7"}, source_index, target_index}
      assert summary.source.source_kind == :electric
      assert summary.source.source_mode == :persistent
      assert summary.source.owner_ref == %{kind: :device, id: "coil-7"}
      assert summary.source.source_value == 150.0

      assert summary.source.decay_policy == %{
               field_radius: 1,
               max_ticks: 90,
               ttl_ticks: 45,
               max_frontier: 64,
               energy_budget_joules: 5_000.0
             }
    end

    test "rejects over-current load before allocating a conduction region" do
      logical_scene_id = 75_375 + System.unique_integer([:positive])
      source_world_macro = {0, 1, 0}
      target_world_macro = {3, 1, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@power_block_material_id)
               )

      for coord <- [
            target_world_macro,
            {0, 0, 0},
            {1, 0, 0},
            {2, 0, 0},
            {3, 0, 0}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:error, {:conduction_path_failed, :current_limit_exceeded}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 max_ticks: 90,
                 voltage: 120,
                 current_limit_amps: 5,
                 load_current_amps: 12,
                 owner_ref: %{kind: :device, id: "bench-supply"}
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "rejects a conduction request whose first tick exceeds source energy budget" do
      logical_scene_id = 75_425 + System.unique_integer([:positive])
      source_world_macro = {0, 1, 0}
      target_world_macro = {3, 1, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@power_block_material_id)
               )

      for coord <- [
            target_world_macro,
            {0, 0, 0},
            {1, 0, 0},
            {2, 0, 0},
            {3, 0, 0}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:error, {:conduction_path_failed, :energy_budget_exhausted}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 max_ticks: 90,
                 voltage: 120,
                 current_limit_amps: 5,
                 load_current_amps: 5,
                 energy_budget_joules: 1,
                 owner_ref: %{kind: :device, id: "small-cell"}
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "reuses the same source-target region and refreshes source points on replay" do
      logical_scene_id = 75_500 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 {0, 1, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      for coord <- [{3, 1, 0}, {0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:ok, first} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {0, 1, 0},
                 target_world_macro: {3, 1, 0},
                 source_potential: 80,
                 max_ticks: 90
               )

      assert {:ok, second} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {0, 1, 0},
                 target_world_macro: {3, 1, 0},
                 source_potential: 160,
                 max_ticks: 90
               )

      assert first.field_region_created == true
      assert first.created == true
      assert first.source_points_action == :seeded
      assert second.region_id == first.region_id
      assert second.field_region_created == false
      assert second.created == false
      assert second.source_points_action == :replaced
    end

    test "rejects non-direct cross-chunk conduction requests" do
      logical_scene_id = 76_000 + System.unique_integer([:positive])

      assert {:error, {:conduction_path_failed, :cross_chunk_conduction_not_supported}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {0, 0, 0},
                 target_world_macro: {32, 0, 0}
               )
    end

    test "rejects adjacent cross-chunk conduction unless both endpoints sit on the shared face" do
      logical_scene_id = 76_025 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {14, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {1, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:error, {:conduction_path_failed, :no_conductive_path}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {14, 0, 0},
                 target_world_macro: {17, 0, 0},
                 max_ticks: 90
               )

      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 0
    end

    test "creates a coordinated cross-chunk conduction field when aligned boundary contacts are conductive" do
      logical_scene_id = 76_050 + System.unique_integer([:positive])
      source_world_macro = {15, 0, 0}
      target_world_macro = {16, 0, 0}

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 max_ticks: 90
               )

      source_index = Types.macro_index!({15, 0, 0})
      target_index = Types.macro_index!({0, 0, 0})

      assert summary.cross_chunk == true
      assert summary.created == true
      assert summary.field_region_created == true
      assert summary.source_index == source_index
      assert summary.target_index == target_index
      assert summary.region_id == summary.source_shard.region_id

      assert summary.participant_chunks == [
               %{x: 0, y: 0, z: 0},
               %{x: 1, y: 0, z: 0}
             ]

      assert summary.source_shard.chunk_coord == %{x: 0, y: 0, z: 0}
      assert summary.source_shard.field_region_created == true
      assert summary.source_shard.source_points_action == :seeded

      assert summary.target_shard.chunk_coord == %{x: 1, y: 0, z: 0}
      assert summary.target_shard.field_region_created == true
      assert summary.target_shard.source_points_action == :seeded

      assert summary.source_shard.region_id != summary.target_shard.region_id

      source_debug = ChunkProcess.debug_state(source_chunk_pid)
      assert source_debug.field_region_count == 1
      assert source_debug.field_source_count == 1

      target_debug = ChunkProcess.debug_state(target_chunk_pid)
      assert target_debug.field_region_count == 1
      assert target_debug.field_source_count == 0
    end

    test "creates a coordinated cross-chunk discharge field without requiring conductive boundary contact" do
      logical_scene_id = 76_055 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 source_potential: 120,
                 max_ticks: 90,
                 radius: 1,
                 max_frontier: 32,
                 conduction_mode: :discharge
               )

      assert summary.cross_chunk == true
      assert summary.conduction_mode == :discharge
      assert summary.source_shard.field_region_created == true
      assert summary.target_shard.field_region_created == true
      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 1
    end

    test "reuses the coordinated cross-chunk conduction field for the same source and target" do
      logical_scene_id = 76_062 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, first} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert {:ok, second} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert first.cross_chunk == true
      assert first.field_region_created == true
      assert second.cross_chunk == true
      assert second.created == false
      assert second.field_region_created == false
      assert second.region_id == first.region_id
      assert second.source_shard.region_id == first.source_shard.region_id
      assert second.target_shard.region_id == first.target_shard.region_id
      assert second.source_shard.field_region_created == false
      assert second.target_shard.field_region_created == false
      assert second.source_shard.source_points_action == :replaced
      assert second.target_shard.source_points_action == :replaced

      source_debug = ChunkProcess.debug_state(source_chunk_pid)
      assert source_debug.field_region_count == 1
      assert source_debug.field_source_count == 1

      target_debug = ChunkProcess.debug_state(target_chunk_pid)
      assert target_debug.field_region_count == 1
      assert target_debug.field_source_count == 0
    end

    test "source release cleans up the linked cross-chunk target shard" do
      logical_scene_id = 76_068 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 1

      assert {:ok, %{region_action: :destroyed, source_action: :released}} =
               ChunkProcess.release_field_region_source(
                 source_chunk_pid,
                 summary.source_key,
                 :explicit
               )

      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(source_chunk_pid).field_source_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_source_count == 0
    end

    test "source lease revoke cleans up the linked cross-chunk target shard" do
      logical_scene_id = 76_070 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert summary.cross_chunk == true
      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 1

      assert {:ok, _lease} =
               ChunkProcess.apply_lease(
                 source_chunk_pid,
                 lease(logical_scene_id, region_id: 9, lease_id: 1, owner_epoch: 1)
               )

      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(source_chunk_pid).field_source_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_source_count == 0
    end

    test "cross-chunk boundary preflight rejects a non-conductive neighbor before region allocation" do
      with_observe_log(fn observe_log ->
        logical_scene_id = 76_075 + System.unique_integer([:positive])

        assert {:ok, source_chunk_pid} =
                 ChunkDirectory.ensure_chunk(%{
                   logical_scene_id: logical_scene_id,
                   chunk_coord: {0, 0, 0}
                 })

        assert {:ok, target_chunk_pid} =
                 ChunkDirectory.ensure_chunk(%{
                   logical_scene_id: logical_scene_id,
                   chunk_coord: {1, 0, 0}
                 })

        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   source_chunk_pid,
                   {15, 0, 0},
                   NormalBlockData.new(@power_block_material_id)
                 )

        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   target_chunk_pid,
                   {0, 0, 0},
                   NormalBlockData.new(@dirt_material_id)
                 )

        assert {:error, {:conduction_path_failed, :target_not_conductive}} =
                 FieldRuntime.ensure_conduction_path(
                   logical_scene_id: logical_scene_id,
                   source_world_macro: {15, 0, 0},
                   target_world_macro: {16, 0, 0},
                   max_ticks: 90
                 )

        assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 0
        assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 0

        CliObserve.flush()
        observe_log_text = File.read!(observe_log)

        assert observe_log_text =~ ~s(event="voxel_conduction_path_rejected")
        assert observe_log_text =~ "raw_reason: :target_not_conductive"
        assert observe_log_text =~ "public_reason: :target_not_conductive"
        assert observe_log_text =~ "source_exit_face: :x_pos"
        assert observe_log_text =~ "target_entry_face: :x_neg"
      end)
    end

    test "cleans up an existing cross-chunk conduction field when the target becomes non-conductive" do
      logical_scene_id = 76_085 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, first} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert first.cross_chunk == true
      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(source_chunk_pid).field_source_count == 1
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(target_chunk_pid).field_source_count == 0

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@dirt_material_id)
               )

      assert {:error, {:conduction_path_failed, :target_not_conductive}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(source_chunk_pid).field_source_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_source_count == 0
    end

    test "cleans up an existing cross-chunk conduction field when the source block is removed" do
      logical_scene_id = 76_095 + System.unique_integer([:positive])

      assert {:ok, source_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, target_chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {1, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 target_chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:ok, first} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert first.cross_chunk == true

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 source_chunk_pid,
                 {15, 0, 0},
                 NormalBlockData.new(@dirt_material_id)
               )

      assert {:error, {:conduction_path_failed, :source_not_conductive}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {15, 0, 0},
                 target_world_macro: {16, 0, 0},
                 max_ticks: 90
               )

      assert ChunkProcess.debug_state(source_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(source_chunk_pid).field_source_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(target_chunk_pid).field_source_count == 0
    end

    test "rejects conduction when the source voxel has been removed" do
      logical_scene_id = 76_500 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 {3, 1, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:error, {:conduction_path_failed, :source_not_conductive}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {0, 1, 0},
                 target_world_macro: {3, 1, 0},
                 source_potential: 120,
                 max_ticks: 90
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "cleans up an existing conduction region when refreshed source is no longer conductive" do
      logical_scene_id = 76_600 + System.unique_integer([:positive])
      source_world_macro = {0, 1, 0}
      target_world_macro = {3, 1, 0}

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@power_block_material_id)
               )

      for coord <- [
            target_world_macro,
            {0, 0, 0},
            {1, 0, 0},
            {2, 0, 0},
            {3, 0, 0}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@iron_material_id)
                 )
      end

      assert {:ok, first} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 source_potential: 120,
                 max_ticks: 90
               )

      assert first.field_region_created == true
      assert ChunkProcess.debug_state(chunk_pid).field_region_count == 1
      assert ChunkProcess.debug_state(chunk_pid).field_source_count == 1

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 source_world_macro,
                 NormalBlockData.new(@dirt_material_id)
               )

      assert {:error, {:conduction_path_failed, :source_not_conductive}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: source_world_macro,
                 target_world_macro: target_world_macro,
                 source_potential: 120,
                 max_ticks: 90
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "rejects dirt ground and air gaps as a conductive channel" do
      logical_scene_id = 76_700 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      for coord <- [{0, 1, 0}, {1, 1, 0}, {2, 1, 0}, {3, 1, 0}] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   coord,
                   NormalBlockData.new(@dirt_material_id)
                 )
      end

      assert {:error, {:conduction_path_failed, :source_not_conductive}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {0, 1, 0},
                 target_world_macro: {3, 1, 0},
                 source_potential: 120,
                 max_ticks: 90
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 {0, 1, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 {3, 1, 0},
                 NormalBlockData.new(@iron_material_id)
               )

      assert {:error, {:conduction_path_failed, :no_conductive_path}} =
               FieldRuntime.ensure_conduction_path(
                 logical_scene_id: logical_scene_id,
                 source_world_macro: {0, 1, 0},
                 target_world_macro: {3, 1, 0},
                 source_potential: 120,
                 max_ticks: 90
               )

      debug = ChunkProcess.debug_state(chunk_pid)
      assert debug.field_region_count == 0
      assert debug.field_source_count == 0
    end

    test "emits detailed observe reason when conduction preflight rejects a channel" do
      with_observe_log(fn observe_log ->
        logical_scene_id = 76_800 + System.unique_integer([:positive])

        assert {:ok, chunk_pid} =
                 ChunkDirectory.ensure_chunk(%{
                   logical_scene_id: logical_scene_id,
                   chunk_coord: {0, 0, 0}
                 })

        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(
                   chunk_pid,
                   {0, 1, 0},
                   NormalBlockData.new(@power_block_material_id)
                 )

        for coord <- [{1, 1, 0}, {2, 1, 0}, {3, 1, 0}] do
          assert {:ok, _storage} =
                   ChunkProcess.put_solid_block(
                     chunk_pid,
                     coord,
                     NormalBlockData.new(@iron_material_id)
                   )
        end

        assert {:error, {:conduction_path_failed, :no_conductive_path}} =
                 FieldRuntime.ensure_conduction_path(
                   logical_scene_id: logical_scene_id,
                   source_world_macro: {0, 1, 0},
                   target_world_macro: {3, 1, 0},
                   source_potential: 120,
                   max_ticks: 90,
                   max_frontier: 1
                 )

        CliObserve.flush()
        observe_log_text = File.read!(observe_log)

        assert observe_log_text =~ ~s(event="voxel_conduction_path_rejected")
        assert observe_log_text =~ "raw_reason: :frontier_exhausted"
        assert observe_log_text =~ "reject_reason: :search_budget_exhausted"
        assert observe_log_text =~ "public_reason: :no_conductive_path"
        assert observe_log_text =~ "max_frontier: 1"
      end)
    end
  end

  describe "ensure_auto_circuit/1" do
    test "reuses authority-started auto circuit region and emits closed source-load current" do
      logical_scene_id = 77_000 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk_pid, self(), request_id: 770)
      assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

      for {coord, material_id} <- closed_loop_blocks() do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(chunk_pid, coord, NormalBlockData.new(material_id))
      end

      assert_receive {:voxel_field_region_snapshot_payload, payload}, 1_000
      assert ChunkProcess.debug_state(chunk_pid).field_region_count == 1

      assert {:ok, summary} =
               FieldRuntime.ensure_auto_circuit(
                 logical_scene_id: logical_scene_id,
                 world_macro: {0, 0, 0},
                 max_ticks: 90
               )

      assert summary.created == true
      assert summary.field_region_created == false
      assert summary.field_types == ["electric_potential", "electric_current", "ionization"]
      assert summary.max_ticks == nil
      assert summary.source_count == 1
      assert summary.load_count == 1
      assert summary.waiting_for_load == false
      assert summary.power_draw.output_mode == :dc
      assert summary.power_draw.voltage == 120.0
      assert summary.power_draw.current_limit_amps == 20.0
      assert summary.power_draw.load_current_amps == 20.0
      assert summary.power_draw.estimated_tick_energy_joules == 240.0

      decoded = FieldCodec.decode_snapshot_payload!(payload)

      assert Bitwise.band(decoded.field_mask, FieldCodec.field_mask_electric_current()) != 0

      assert decoded.macro_indices == closed_loop_macro_indices()

      assert Enum.all?(decoded.electric_current_values, &(&1 > 0.0))
    end

    test "keeps auto circuit regions topology-bound instead of expiring as a pulse" do
      logical_scene_id = 77_050 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      for {coord, material_id} <- closed_loop_blocks() do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(chunk_pid, coord, NormalBlockData.new(material_id))
      end

      assert {:ok, summary} =
               FieldRuntime.ensure_auto_circuit(
                 logical_scene_id: logical_scene_id,
                 world_macro: {0, 0, 0},
                 max_ticks: 1
               )

      assert summary.max_ticks == nil

      Process.sleep(250)

      assert ChunkProcess.debug_state(chunk_pid).field_region_count == 1
    end

    test "does not keep an auto circuit worker alive when no load exists" do
      logical_scene_id = 77_100 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 {0, 0, 0},
                 NormalBlockData.new(@power_block_material_id)
               )

      assert {:ok, summary} =
               FieldRuntime.ensure_auto_circuit(
                 logical_scene_id: logical_scene_id,
                 world_macro: {0, 0, 0},
                 max_ticks: 90
               )

      assert summary.created == false
      assert summary.field_region_created == false
      assert summary.source_count == 1
      assert summary.load_count == 0
      assert summary.waiting_for_load == false
      assert summary.reason == :no_load
      assert ChunkProcess.debug_state(chunk_pid).field_region_count == 0
    end

    test "does not allocate an automatic current field for an open source-load path" do
      logical_scene_id = 77_150 + System.unique_integer([:positive])

      assert {:ok, chunk_pid} =
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: {0, 0, 0}
               })

      for {coord, material_id} <- [
            {{0, 0, 0}, @power_block_material_id},
            {{1, 0, 0}, @iron_material_id},
            {{2, 0, 0}, @load_block_material_id}
          ] do
        assert {:ok, _storage} =
                 ChunkProcess.put_solid_block(chunk_pid, coord, NormalBlockData.new(material_id))
      end

      assert {:ok, summary} =
               FieldRuntime.ensure_auto_circuit(
                 logical_scene_id: logical_scene_id,
                 world_macro: {0, 0, 0},
                 max_ticks: 90
               )

      assert summary.created == false
      assert summary.field_region_created == false
      assert summary.source_count == 1
      assert summary.load_count == 1
      assert summary.closed_circuit_count == 0
      assert summary.waiting_for_load == false
      assert summary.reason == :no_closed_circuit
      assert ChunkProcess.debug_state(chunk_pid).field_region_count == 0
      assert ChunkProcess.debug_state(chunk_pid).field_source_count == 0
    end
  end

  describe "build_temperature_anomaly/1" do
    test "builds a kernel-first local temperature field from the voxel stored temperature" do
      world_macro = {-1, 16, 17}

      {storage, _local_macro, _macro_index} =
        solid_storage_with_temperature_delta(world_macro, 80)

      assert {:ok, plan} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 target_temperature: 20,
                 max_ticks: 120,
                 radius: 2
               })

      assert plan.logical_scene_id == 7
      assert plan.chunk_coord == {-1, 1, 1}
      assert plan.local_macro == {15, 0, 1}
      assert plan.source_index == Types.macro_index!({15, 0, 1})

      assert plan.region_attrs == %{
               chunk_coord: {-1, 1, 1},
               aabb: {{13, 0, 0}, {15, 2, 3}},
               kernels: [
                 %{
                   id: :temperature_diffusion,
                   module: TemperatureDiffusionKernel,
                   opts: %{
                     diffusion_time_scale: 1.0,
                     ambient_loss_per_second: 0.0,
                     cell_size_meters: 1.0
                   }
                 }
               ],
               source_points: [
                 %{
                   macro_index: Types.macro_index!({15, 0, 1}),
                   field_type: :temperature,
                   source_mode: :impulse,
                   value: 100.0
                 }
               ],
               max_ticks: 120
             }

      assert plan.summary.created == true
      assert plan.summary.target_temperature == 100.0
      assert plan.summary.baseline_temperature == 20.0
      assert plan.summary.anomaly_delta == 80.0
      assert plan.summary.field_types == ["temperature"]
      assert plan.summary.world_macro == %{x: -1, y: 16, z: 17}
      assert plan.summary.local_macro == %{x: 15, y: 0, z: 1}
    end

    test "builds the same temperature diffusion field for below-freezing anomalies" do
      world_macro = {2, 3, 4}

      {storage, _local_macro, _macro_index} =
        solid_storage_with_temperature_delta(world_macro, -40)

      assert {:ok, plan} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 max_ticks: 120,
                 radius: 1
               })

      assert plan.region_attrs.kernels == [
               %{
                 id: :temperature_diffusion,
                 module: TemperatureDiffusionKernel,
                 opts: %{
                   diffusion_time_scale: 1.0,
                   ambient_loss_per_second: 0.0,
                   cell_size_meters: 1.0
                 }
               }
             ]

      assert plan.region_attrs.source_points == [
               %{
                 macro_index: Types.macro_index!({2, 3, 4}),
                 field_type: :temperature,
                 source_mode: :impulse,
                 value: -20.0
               }
             ]

      assert plan.summary.target_temperature == -20.0
      assert plan.summary.anomaly_delta == -40.0
    end

    test "carries normalized field source summary through the pure anomaly plan" do
      world_macro = {-1, 16, 17}

      {storage, _local_macro, _macro_index} =
        solid_storage_with_temperature_delta(world_macro, 80)

      source =
        FieldSource.normalize(%{
          logical_scene_id: 7,
          world_macro: world_macro,
          target_temperature_celsius: 100,
          source_mode: :persistent,
          max_ticks: 120,
          radius: 2
        })

      assert {:ok, plan} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 field_source: source,
                 max_ticks: 120,
                 radius: 2
               })

      assert plan.source_key == source.source_key

      assert plan.region_attrs.source_points == [
               %{
                 macro_index: Types.macro_index!({15, 0, 1}),
                 field_type: :temperature,
                 source_mode: :persistent,
                 value: 100.0
               }
             ]

      assert plan.region_attrs.source_points_mode == :replace
      assert plan.summary.source.source_id == source.source_id
      assert plan.summary.source.source_key == source.source_key
      assert plan.summary.source.source_kind == :temperature
      assert plan.summary.source.source_mode == :persistent
      assert plan.summary.source.target_value == 100.0
      assert plan.summary.source.source_value == 100.0
      assert plan.summary.source.decay_policy == %{field_radius: 2, max_ticks: 120}
    end

    test "set-temperature field source spreads visibly within browser-observable ticks" do
      world_macro = {5, 0, 5}
      source_idx = Types.macro_index!(world_macro)
      first_ring_idx = Types.macro_index!({6, 0, 5})
      second_ring_idx = Types.macro_index!({7, 0, 5})

      {storage, _local_macro, _macro_index} =
        solid_storage_with_temperature_delta(world_macro, 780)

      source =
        FieldSource.normalize(%{
          logical_scene_id: 7,
          world_macro: world_macro,
          target_temperature_celsius: 800,
          max_ticks: 120,
          radius: 4
        })

      assert {:ok, plan} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 field_source: source,
                 max_ticks: 120,
                 radius: 4
               })

      [kernel_spec, combustion_spec, phase_change_spec, smoke_spec, oxygen_spec, moisture_spec] =
        plan.region_attrs.kernels

      region = FieldRegion.new(Map.put(plan.region_attrs, :region_id, 99))

      assert combustion_spec == %{id: :combustion, module: CombustionKernel, opts: %{}}
      assert phase_change_spec == %{id: :phase_change, module: PhaseChangeKernel, opts: %{}}
      assert smoke_spec.id == :smoke_diffusion
      assert oxygen_spec.id == :oxygen_diffusion
      assert moisture_spec.id == :moisture_diffusion
      assert plan.summary.field_types == ["temperature", "smoke_density", "oxygen", "moisture"]

      assert plan.summary.source.source_mode == :impulse

      assert plan.region_attrs.source_points == [
               %{
                 macro_index: source_idx,
                 field_type: :temperature,
                 source_mode: :impulse,
                 value: 800.0
               }
             ]

      region_after_spread =
        tick_temperature_region(region, storage, Map.to_list(kernel_spec.opts), 10)

      layer_after_spread = FieldRegion.get_layer(region_after_spread, :temperature)
      active = FieldLayer.active_cells(layer_after_spread, region_after_spread.aabb)
      active_indices = Enum.map(active, &elem(&1, 0))
      source_after_spread = FieldLayer.get(layer_after_spread, source_idx)
      max_after_spread = active |> Enum.map(&elem(&1, 1)) |> Enum.max()

      assert source_idx in active_indices
      assert length(active) > 2

      assert FieldLayer.get(layer_after_spread, first_ring_idx) >
               TemperatureField.env_temperature() + 10.0

      assert FieldLayer.get(layer_after_spread, second_ring_idx) >
               TemperatureField.env_temperature() + 1.0

      region_after_decay =
        tick_temperature_region(region_after_spread, storage, Map.to_list(kernel_spec.opts), 80)

      layer_after_decay = FieldRegion.get_layer(region_after_decay, :temperature)

      max_after_decay =
        layer_after_decay
        |> FieldLayer.active_cells(region_after_decay.aabb)
        |> Enum.map(&elem(&1, 1))
        |> Enum.max(fn -> TemperatureField.env_temperature() end)

      assert FieldLayer.get(layer_after_decay, source_idx) < source_after_spread
      assert max_after_decay < max_after_spread
    end

    test "does not create a field when the voxel effective temperature is still the baseline" do
      world_macro = {1, 2, 3}
      {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
      macro_index = Types.macro_index!(local_macro)

      storage =
        Storage.new(7, chunk_coord)
        |> Storage.put_solid_block(macro_index, NormalBlockData.new(1))

      assert {:ignore, summary} =
               FieldRuntime.build_temperature_anomaly(%{
                 logical_scene_id: 7,
                 storage: storage,
                 world_macro: world_macro,
                 target_temperature: 100
               })

      assert summary.created == false
      assert summary.reason == :temperature_within_environment_threshold
      assert summary.baseline_temperature == 20.0
      assert summary.target_temperature == 20.0
    end
  end

  defp tick_temperature_region(region, storage, kernel_opts, ticks) do
    Enum.reduce(1..ticks, region, fn _, acc ->
      TemperatureField.tick(acc, storage, kernel_opts)
    end)
  end

  defp closed_loop_blocks do
    [
      {{0, 0, 0}, @power_block_material_id},
      {{1, 0, 0}, @iron_material_id},
      {{2, 0, 0}, @load_block_material_id},
      {{2, 1, 0}, @iron_material_id},
      {{2, 2, 0}, @iron_material_id},
      {{1, 2, 0}, @iron_material_id},
      {{0, 2, 0}, @iron_material_id},
      {{0, 1, 0}, @iron_material_id}
    ]
  end

  defp closed_loop_macro_indices do
    closed_loop_blocks()
    |> Enum.map(fn {coord, _material_id} -> Types.macro_index!(coord) end)
    |> Enum.sort()
  end

  defp lease(logical_scene_id, overrides) do
    base = %{
      logical_scene_id: logical_scene_id,
      region_id: 1,
      lease_id: 1,
      owner_scene_instance_ref: 1,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {0, 0, 0},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }

    Map.merge(base, Map.new(overrides))
  end
end
