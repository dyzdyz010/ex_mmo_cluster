defmodule AuthServerWeb.IngameControllerTest do
  use AuthServerWeb.ConnCase

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PartState
  alias SceneServer.Voxel.Phenomenon.Combustion
  alias SceneServer.Voxel.Phenomenon.Corrosion
  alias SceneServer.Voxel.Phenomenon.Effect
  alias SceneServer.Voxel.Phenomenon.StructuralIntegrity
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types
  alias WorldServer.Voxel.DevSeed
  alias WorldServer.Voxel.MapLedger

  @iron_material_id 5
  @power_block_material_id 6
  @load_block_material_id 7

  setup_all do
    {:ok, _} = Application.ensure_all_started(:world_server)
    {:ok, _} = Application.ensure_all_started(:scene_server)
    :ok
  end

  setup do
    previous_auto_login = Application.get_env(:auth_server, :dev_auto_login, false)
    Application.put_env(:auth_server, :dev_auto_login, true)

    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      Application.put_env(:auth_server, :dev_auto_login, previous_auto_login)
    end)

    :ok
  end

  test "POST /ingame/voxel/set_temperature returns JSON-safe source and cleanup summaries",
       %{conn: conn} do
    logical_scene_id = 81_000 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    chunk_pid = put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [{world_macro, 1}])

    hot_conn =
      post(conn, ~p"/ingame/voxel/set_temperature", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "target_temperature_celsius" => 800,
        "max_ticks" => 100
      })

    hot = json_response(hot_conn, 200)
    assert hot["target_temperature"] == 800.0
    assert hot["scene_node"] == Atom.to_string(node())
    assert hot["source"]["source_kind"] == "temperature"
    assert hot["source"]["source_mode"] == "impulse"
    assert hot["source"]["source_key"] == ["temperature", macro_index]

    kernel_modules = Enum.map(hot["source"]["kernel_specs"], & &1["module"])
    assert "Elixir.SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel" in kernel_modules
    assert "Elixir.SceneServer.Voxel.Phenomenon.CombustionKernel" in kernel_modules
    assert "Elixir.SceneServer.Voxel.Phenomenon.PhaseChangeKernel" in kernel_modules
    assert "Elixir.SceneServer.Voxel.Field.Kernels.SmokeDiffusionKernel" in kernel_modules
    assert "Elixir.SceneServer.Voxel.Field.Kernels.OxygenDiffusionKernel" in kernel_modules
    assert "Elixir.SceneServer.Voxel.Field.Kernels.MoistureDiffusionKernel" in kernel_modules

    ambient_conn =
      hot_conn
      |> recycle()
      |> post(~p"/ingame/voxel/set_temperature", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "restore_ambient" => true,
        "max_ticks" => 100
      })

    ambient = json_response(ambient_conn, 200)
    assert ambient["target_temperature"] == 20.0
    assert ambient["field_region_created"] == false

    assert Storage.effective_attribute_at(
             ChunkProcess.debug_state(chunk_pid).storage,
             macro_index,
             "temperature"
           ) ==
             1_310_720

    assert ambient["field_region_cleanup"] == %{
             "destroy_reason" => "temperature_within_environment_threshold",
             "region_action" => "destroyed",
             "region_id" => hot["region_id"],
             "source_action" => "released",
             "source_key" => ["temperature", macro_index]
           }
  end

  test "POST /ingame/voxel/conduct returns JSON-safe conduction region summary", %{conn: conn} do
    logical_scene_id = 82_000 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    for coord <- [{0, 1, 0}, {3, 1, 0}, {0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}] do
      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 coord,
                 NormalBlockData.new(@iron_material_id)
               )
    end

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 1,
        "source_z" => 0,
        "target_x" => 3,
        "target_y" => 1,
        "target_z" => 0,
        "source_potential" => 120,
        "max_ticks" => 90,
        "ttl_ticks" => 45,
        "radius" => 1,
        "max_frontier" => 64,
        "source_mode" => "persistent",
        "source_owner_kind" => "device",
        "source_owner_id" => "coil-7",
        "output_mode" => "ac",
        "voltage" => 240,
        "current_limit_amps" => 12.5,
        "frequency_hz" => 60,
        "load_current_amps" => 6.25,
        "energy_budget_joules" => 5000
      })

    body = json_response(conn, 200)
    assert body["field_types"] == ["electric_potential", "ionization"]
    assert body["field_region_created"] == true
    assert body["max_ticks"] == 45

    assert body["source_key"] == [
             "electric",
             ["device", "coil-7"],
             Types.macro_index!({0, 1, 0}),
             Types.macro_index!({3, 1, 0})
           ]

    assert body["source"]["source_kind"] == "electric"
    assert body["source"]["source_mode"] == "persistent"
    assert body["source"]["owner_ref"] == %{"id" => "coil-7", "kind" => "device"}
    assert body["source"]["source_value"] == 240.0

    assert body["source"]["power_source"] == %{
             "current_limit_amps" => 12.5,
             "energy_budget_joules" => 5000.0,
             "frequency_hz" => 60.0,
             "load_current_amps" => 6.25,
             "output_mode" => "ac",
             "owner_ref" => %{"id" => "coil-7", "kind" => "device"},
             "voltage" => 240.0
           }

    assert body["power_draw"] == %{
             "current_limit_amps" => 12.5,
             "energy_budget_joules" => 5000.0,
             "estimated_tick_energy_joules" => 150.0,
             "frequency_hz" => 60.0,
             "load_current_amps" => 6.25,
             "output_mode" => "ac",
             "voltage" => 240.0
           }

    assert body["source"]["decay_policy"] == %{
             "energy_budget_joules" => 5000.0,
             "field_radius" => 1,
             "max_frontier" => 64,
             "max_ticks" => 90,
             "ttl_ticks" => 45
           }

    assert body["source_potential"] == 240.0
    assert body["source_world_macro"] == %{"x" => 0, "y" => 1, "z" => 0}
    assert body["target_world_macro"] == %{"x" => 3, "y" => 1, "z" => 0}
  end

  test "POST /ingame/voxel/conduct can create a dielectric-breakdown discharge path",
       %{conn: conn} do
    logical_scene_id = 82_125 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

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

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               {3, 1, 0},
               NormalBlockData.new(@iron_material_id)
             )

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 1,
        "source_z" => 0,
        "target_x" => 3,
        "target_y" => 1,
        "target_z" => 0,
        "source_potential" => 120,
        "max_ticks" => 90,
        "radius" => 0,
        "max_frontier" => 32,
        "conduction_mode" => "discharge"
      })

    body = json_response(conn, 200)
    assert body["field_region_created"] == true
    assert body["conduction_mode"] == "discharge"
    assert body["source"]["conduction_mode"] == "discharge"
    assert body["field_types"] == ["electric_potential", "ionization"]
  end

  test "POST /ingame/voxel/auto_circuit refreshes a target-free current field", %{conn: conn} do
    logical_scene_id = 82_250 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [
      {{0, 0, 0}, @power_block_material_id},
      {{1, 0, 0}, @iron_material_id},
      {{2, 0, 0}, @load_block_material_id},
      {{2, 1, 0}, @iron_material_id},
      {{2, 2, 0}, @iron_material_id},
      {{1, 2, 0}, @iron_material_id},
      {{0, 2, 0}, @iron_material_id},
      {{0, 1, 0}, @iron_material_id}
    ])

    conn =
      post(conn, ~p"/ingame/voxel/auto_circuit", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "max_ticks" => 90
      })

    body = json_response(conn, 200)
    assert body["field_types"] == ["electric_potential", "electric_current", "ionization"]
    assert is_boolean(body["field_region_created"])
    assert body["source_count"] == 1
    assert body["load_count"] == 1
    assert body["closed_circuit_count"] == 1
    assert body["waiting_for_load"] == false

    assert body["power_draw"] == %{
             "current_limit_amps" => 20.0,
             "energy_budget_joules" => nil,
             "estimated_tick_energy_joules" => 240.0,
             "frequency_hz" => nil,
             "load_current_amps" => 20.0,
             "output_mode" => "dc",
             "voltage" => 120.0
           }
  end

  test "POST /ingame/voxel/auto_circuit reports no closed circuit for an open source-load path",
       %{conn: conn} do
    logical_scene_id = 82_375 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [
      {{0, 0, 0}, @power_block_material_id},
      {{1, 0, 0}, @iron_material_id},
      {{2, 0, 0}, @load_block_material_id}
    ])

    conn =
      post(conn, ~p"/ingame/voxel/auto_circuit", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "max_ticks" => 90
      })

    body = json_response(conn, 200)
    assert body["field_region_created"] == false
    assert body["source_count"] == 1
    assert body["load_count"] == 1
    assert body["closed_circuit_count"] == 0
    assert body["reason"] == "no_closed_circuit"
  end

  test "POST /ingame/voxel/combustion_probe returns authoritative material burn state",
       %{conn: conn} do
    logical_scene_id = 82_425 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    chunk_pid =
      put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [
        {world_macro, MaterialCatalog.wood_material_id()}
      ])

    assert {:ok, %{changed?: true}} =
             ChunkProcess.write_temperature_attribute(chunk_pid, %{
               macro: world_macro,
               target_temperature: 680.0
             })

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(macro_index, :fuel_mass, fixed32(12.5)),
                 Effect.write_voxel_attribute(macro_index, :oxygen, fixed32(44.0)),
                 Effect.write_voxel_attribute(macro_index, :combustion_stage, 2),
                 Effect.write_voxel_attribute(macro_index, :combustion_progress, fixed32(56.0)),
                 Effect.write_voxel_attribute(macro_index, :smoke_density, fixed32(7.0)),
                 Effect.write_voxel_attribute(macro_index, :carbonization, fixed32(18.0)),
                 Effect.write_voxel_attribute(macro_index, :structural_integrity, fixed32(82.0))
               ],
               %{source: :combustion_probe_test}
             )

    conn =
      post(conn, ~p"/ingame/voxel/combustion_probe", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0
      })

    body = json_response(conn, 200)
    assert body["cell_mode"] == "solid"
    assert body["material_id"] == MaterialCatalog.wood_material_id()
    assert body["material_name"] == "wood"
    assert body["combustible"] == true
    assert body["combustion_stage"] == "burning"
    assert body["combustion_stage_raw"] == 2
    assert body["active_combustion"] == true
    assert body["active_combustion_instance"] == false
    assert body["phenomenon_instance"] == nil
    assert body["world_macro"] == %{"x" => 0, "y" => 0, "z" => 0}
    assert body["scene_node"] == Atom.to_string(node())

    attrs = body["attributes"]
    assert_in_delta attrs["temperature_celsius"], 680.0, 0.001
    assert_in_delta attrs["fuel_mass_kg_per_m3"], 12.5, 0.001
    assert_in_delta attrs["oxygen_percent"], 44.0, 0.001
    assert_in_delta attrs["smoke_density_percent"], 7.0, 0.001
    assert_in_delta attrs["carbonization_percent"], 18.0, 0.001
    assert_in_delta attrs["structural_integrity_percent"], 82.0, 0.001

    assert body["profile"]["residue"] == %{
             "type" => "material",
             "material_id" => MaterialCatalog.charcoal_material_id()
           }
  end

  test "POST /ingame/voxel/combustion_probe names inert materials without inventing a profile",
       %{conn: conn} do
    logical_scene_id = 82_465 + System.unique_integer([:positive])
    world_macro = {1, 0, 0}

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    _chunk_pid = put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [{world_macro, 2}])

    conn =
      post(conn, ~p"/ingame/voxel/combustion_probe", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 1,
        "y" => 0,
        "z" => 0
      })

    body = json_response(conn, 200)
    assert body["cell_mode"] == "solid"
    assert body["material_id"] == 2
    assert body["material_name"] == "stone"
    assert body["combustible"] == false
    assert body["profile"] == nil
    assert body["combustion_stage"] == "idle"
    assert body["active_combustion"] == false
    assert body["active_combustion_instance"] == false
  end

  test "POST set_temperature can ignite wood and combustion_probe reads the live burn state",
       %{conn: conn} do
    logical_scene_id = 82_475 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    chunk_pid =
      put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [
        {world_macro, MaterialCatalog.wood_material_id()}
      ])

    heat_conn =
      post(conn, ~p"/ingame/voxel/set_temperature", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "target_temperature_celsius" => 800,
        "radius" => 1,
        "max_ticks" => 10
      })

    heat_body = json_response(heat_conn, 200)
    assert heat_body["target_temperature"] == 800.0

    assert "Elixir.SceneServer.Voxel.Phenomenon.CombustionKernel" in Enum.map(
             heat_body["source"]["kernel_specs"],
             & &1["module"]
           )

    assert "Elixir.SceneServer.Voxel.Field.Kernels.SmokeDiffusionKernel" in Enum.map(
             heat_body["source"]["kernel_specs"],
             & &1["module"]
           )

    assert "Elixir.SceneServer.Voxel.Field.Kernels.OxygenDiffusionKernel" in Enum.map(
             heat_body["source"]["kernel_specs"],
             & &1["module"]
           )

    assert "Elixir.SceneServer.Voxel.Field.Kernels.MoistureDiffusionKernel" in Enum.map(
             heat_body["source"]["kernel_specs"],
             & &1["module"]
           )

    assert "Elixir.SceneServer.Voxel.Phenomenon.PhaseChangeKernel" in Enum.map(
             heat_body["source"]["kernel_specs"],
             & &1["module"]
           )

    assert_eventually(fn ->
      chunk_pid
      |> ChunkProcess.debug_state()
      |> Map.fetch!(:storage)
      |> Storage.effective_attribute_at(macro_index, "combustion_stage")
      |> Kernel.==(Combustion.stage_burning())
    end)

    probe_conn =
      heat_conn
      |> recycle()
      |> post(~p"/ingame/voxel/combustion_probe", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0
      })

    body = json_response(probe_conn, 200)
    assert body["combustion_stage"] == "burning"
    assert body["active_combustion"] == true
    assert body["active_combustion_instance"] == true
    assert body["material_name"] == "wood"
    assert body["profile"]["combustion_heat_j_per_kg"] == 16_000_000.0
    assert body["profile"]["heat_release_efficiency"] == 0.35

    instance = body["phenomenon_instance"]
    assert instance["kind"] == "combustion"
    assert instance["status"] == "active"
    assert instance["stage"] == "burning"
    assert instance["macro_index"] == macro_index

    assert [%{"kind" => "field_source", "source_key" => source_key}] =
             instance["metadata"]["source_refs"]

    assert source_key =~ "{:combustion_instance"

    attrs = body["attributes"]
    assert attrs["fuel_mass_kg_per_m3"] < 45.0
    assert attrs["oxygen_percent"] < 100.0
    assert attrs["combustion_progress_percent"] > 0.0
  end

  test "POST /ingame/voxel/corrosion_probe returns authoritative material corrosion state",
       %{conn: conn} do
    logical_scene_id = 82_480 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    chunk_pid =
      put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [
        {world_macro, @iron_material_id}
      ])

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(macro_index, :moisture, fixed32(120.0)),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :chemical_concentration,
                   fixed32(45.0)
                 ),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :surface_state,
                   Corrosion.surface_corroding()
                 ),
                 Effect.write_voxel_attribute(macro_index, :corrosion, fixed32(14.25)),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :structural_integrity,
                   fixed32(94.25)
                 ),
                 Effect.write_voxel_attribute(
                   macro_index,
                   :electric_conductivity,
                   fixed32(7.75)
                 ),
                 Effect.upsert_phenomenon_instance(:corrosion, macro_index, %{
                   material_id: @iron_material_id,
                   stage: :corroding,
                   previous_stage: :exposed,
                   corrosion_after_percent: 14.25
                 })
               ],
               %{source: :corrosion_probe_test}
             )

    conn =
      post(conn, ~p"/ingame/voxel/corrosion_probe", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0
      })

    body = json_response(conn, 200)
    assert body["cell_mode"] == "solid"
    assert body["material_id"] == @iron_material_id
    assert body["material_name"] == "iron"
    assert body["corrodible"] == true
    assert body["surface_state"] == "corroding"
    assert body["surface_state_raw"] == Corrosion.surface_corroding()
    assert body["active_corrosion"] == true
    assert body["active_corrosion_instance"] == true
    assert body["scene_node"] == Atom.to_string(node())
    assert body["world_macro"] == %{"x" => 0, "y" => 0, "z" => 0}

    attrs = body["attributes"]
    assert_in_delta attrs["moisture_kg_per_m3"], 120.0, 0.001
    assert_in_delta attrs["chemical_concentration_percent"], 45.0, 0.001
    assert_in_delta attrs["corrosion_percent"], 14.25, 0.001
    assert_in_delta attrs["corrosion_resistance_percent"], 35.0, 0.001
    assert_in_delta attrs["structural_integrity_percent"], 94.25, 0.001
    assert_in_delta attrs["electric_conductivity_ms_per_m"], 7.75, 0.001

    assert body["profile"]["material_name"] == "iron"
    assert body["profile"]["moisture_threshold_kg_per_m3"] > 0.0
    assert body["profile"]["chemical_threshold_percent"] > 0.0
    assert body["profile"]["corrosion_rate_percent_per_second"] > 0.0

    instance = body["phenomenon_instance"]
    assert instance["kind"] == "corrosion"
    assert instance["status"] == "active"
    assert instance["stage"] == "corroding"
    assert instance["macro_index"] == macro_index
  end

  test "POST /ingame/voxel/phase_change_probe returns authoritative contained-water state",
       %{conn: conn} do
    logical_scene_id = 82_485 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    chunk_pid =
      put_authorized_blocks!(logical_scene_id, {0, 0, 0}, [
        {world_macro, MaterialCatalog.wood_material_id()}
      ])

    assert {:ok, %{changed?: true}} =
             ChunkProcess.write_temperature_attribute(chunk_pid, %{
               macro: world_macro,
               target_temperature: -12.0
             })

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(
               chunk_pid,
               [
                 Effect.write_voxel_attribute(macro_index, :moisture, fixed32(38.0)),
                 Effect.write_voxel_attribute(macro_index, :phase_state, 1),
                 Effect.write_voxel_attribute(macro_index, :structural_integrity, fixed32(88.0)),
                 Effect.upsert_phenomenon_instance(:phase_change, macro_index, %{
                   material_id: MaterialCatalog.wood_material_id(),
                   stage: :frozen,
                   previous_stage: :stable,
                   temperature_celsius: -12.0,
                   moisture_kg_per_m3: 38.0
                 })
               ],
               %{source: :phase_change_probe_test}
             )

    conn =
      post(conn, ~p"/ingame/voxel/phase_change_probe", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0
      })

    body = json_response(conn, 200)
    assert body["cell_mode"] == "solid"
    assert body["material_id"] == MaterialCatalog.wood_material_id()
    assert body["material_name"] == "wood"
    assert body["phase_state"] == "frozen"
    assert body["phase_state_raw"] == 1
    assert body["active_phase_change"] == true
    assert body["active_phase_change_instance"] == true
    assert body["scene_node"] == Atom.to_string(node())
    assert body["world_macro"] == %{"x" => 0, "y" => 0, "z" => 0}

    attrs = body["attributes"]
    assert_in_delta attrs["temperature_celsius"], -12.0, 0.001
    assert_in_delta attrs["moisture_kg_per_m3"], 38.0, 0.001
    assert_in_delta attrs["structural_integrity_percent"], 88.0, 0.001

    instance = body["phenomenon_instance"]
    assert instance["kind"] == "phase_change"
    assert instance["status"] == "active"
    assert instance["stage"] == "frozen"
    assert instance["macro_index"] == macro_index
  end

  test "POST /ingame/voxel/object_probe returns phenomenon-driven object part damage",
       %{conn: conn} do
    logical_scene_id = 82_495 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert :ok = ObjectRegistry.reset(ObjectRegistry)

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert {:ok, route} = MapLedger.route_chunk_with_lease(logical_scene_id, {0, 0, 0})
    lease = route.lease
    chunk_pid = put_owned_micro_slots!(lease, world_macro, 42, 3, 2)

    assert :ok =
             ObjectRegistry.upsert_object(
               ObjectRegistry,
               object_instance_attrs(
                 object_id: 42,
                 logical_scene_id: logical_scene_id,
                 covered_chunks: [{0, 0, 0}],
                 part_states: [%{part_id: 3, health: 5, state_flags: 0}],
                 owner_region_id: route.assignment.region_id,
                 owner_lease_id: route.lease.lease_id
               )
             )

    structural_effects =
      StructuralIntegrity.damage_effects(
        macro_index,
        MaterialCatalog.wood_material_id(),
        16.0,
        13.0,
        reason: :combustion_heat_stress,
        threshold_percent: 15.0,
        context: %{stage: :burning}
      )
      |> Enum.reject(fn
        {:emit_observe, _event, _fields} -> true
        _other -> false
      end)
      |> Enum.filter(fn
        {:apply_structural_damage, _attrs} -> true
        _other -> false
      end)

    assert [_effect] = structural_effects

    assert {:ok, %{rejected_count: 0}} =
             ChunkProcess.apply_field_effects(chunk_pid, structural_effects, %{
               kernel_id: :combustion
             })

    assert_eventually(fn ->
      case ObjectRegistry.lookup_object(ObjectRegistry, logical_scene_id, 42) do
        %{part_states: [%PartState{part_id: 3, health: 3} = part]} ->
          PartState.damaged?(part)

        _other ->
          false
      end
    end)

    conn =
      post(conn, ~p"/ingame/voxel/object_probe", %{
        "logical_scene_id" => logical_scene_id,
        "object_id" => 42,
        "x" => 0,
        "y" => 0,
        "z" => 0
      })

    body = json_response(conn, 200)
    assert body["object_found"] == true
    assert body["logical_scene_id"] == logical_scene_id
    assert body["object_id"] == 42
    assert body["object_version"] == 2
    assert Bitwise.band(body["state_flags"], PartState.flag_damaged()) != 0
    assert body["covered_chunks"] == [%{"x" => 0, "y" => 0, "z" => 0}]
    assert body["damaged_part_count"] == 1
    assert body["destroyed_part_count"] == 0
    assert body["scene_node"] == Atom.to_string(node())
    assert body["route_world_macro"] == %{"x" => 0, "y" => 0, "z" => 0}

    assert [
             %{
               "part_id" => 3,
               "health" => 3,
               "state_flags" => flags,
               "damaged" => true,
               "destroyed" => false
             }
           ] = body["part_states"]

    assert Bitwise.band(flags, PartState.flag_damaged()) != 0
  end

  test "POST /ingame/voxel/conduct rejects a plain conductor without a power block",
       %{conn: conn} do
    logical_scene_id = 82_500 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    for coord <- [{0, 1, 0}, {3, 1, 0}, {0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}] do
      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 coord,
                 NormalBlockData.new(@iron_material_id)
               )
    end

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 1,
        "source_z" => 0,
        "target_x" => 3,
        "target_y" => 1,
        "target_z" => 0
      })

    body = json_response(conn, 422)
    assert body["error"] == "voxel_conduct_failed"
    assert body["reason_code"] == "source_not_powered"
  end

  test "POST /ingame/voxel/conduct returns 200 for adjacent conductive cross-chunk paths",
       %{conn: conn} do
    logical_scene_id = 83_000 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

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

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 15,
        "source_y" => 0,
        "source_z" => 0,
        "target_x" => 16,
        "target_y" => 0,
        "target_z" => 0
      })

    body = json_response(conn, 200)
    assert body["cross_chunk"] == true
    assert body["field_region_created"] == true

    assert body["participant_chunks"] == [
             %{"x" => 0, "y" => 0, "z" => 0},
             %{"x" => 1, "y" => 0, "z" => 0}
           ]

    assert body["source_shard"]["chunk_coord"] == %{"x" => 0, "y" => 0, "z" => 0}
    assert body["target_shard"]["chunk_coord"] == %{"x" => 1, "y" => 0, "z" => 0}
    assert body["source_shard"]["field_region_created"] == true
    assert body["target_shard"]["field_region_created"] == true
  end

  test "POST /ingame/voxel/conduct still rejects non-direct cross-chunk paths",
       %{conn: conn} do
    logical_scene_id = 83_050 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {2, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 0,
        "source_z" => 0,
        "target_x" => 32,
        "target_y" => 0,
        "target_z" => 0
      })

    body = json_response(conn, 422)
    assert body["error"] == "voxel_conduct_failed"
    assert body["reason_code"] == "cross_chunk_conduction_not_supported"
  end

  test "POST /ingame/voxel/conduct rejects empty or non-conductive source cells",
       %{conn: conn} do
    logical_scene_id = 83_500 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

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

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 1,
        "source_z" => 0,
        "target_x" => 3,
        "target_y" => 1,
        "target_z" => 0
      })

    body = json_response(conn, 422)
    assert body["error"] == "voxel_conduct_failed"
    assert body["reason_code"] == "source_not_conductive"
  end

  test "POST /ingame/voxel/conduct rejects empty or non-conductive target cells",
       %{conn: conn} do
    logical_scene_id = 83_600 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk_pid,
               {0, 1, 0},
               NormalBlockData.new(@iron_material_id)
             )

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 1,
        "source_z" => 0,
        "target_x" => 3,
        "target_y" => 1,
        "target_z" => 0
      })

    body = json_response(conn, 422)
    assert body["error"] == "voxel_conduct_failed"
    assert body["reason_code"] == "target_not_conductive"
  end

  test "POST /ingame/voxel/conduct rejects source and target with no conductive path",
       %{conn: conn} do
    logical_scene_id = 83_700 + System.unique_integer([:positive])

    assert {:ok, _route_summary} =
             DevSeed.ensure_default_region(
               logical_scene_id: logical_scene_id,
               region_id: logical_scene_id * 1_000 + 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               assigned_scene_node: node(),
               seed_terrain?: false
             )

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    for coord <- [{0, 1, 0}, {3, 1, 0}] do
      assert {:ok, _storage} =
               ChunkProcess.put_solid_block(
                 chunk_pid,
                 coord,
                 NormalBlockData.new(
                   if coord == {0, 1, 0}, do: @power_block_material_id, else: @iron_material_id
                 )
               )
    end

    conn =
      post(conn, ~p"/ingame/voxel/conduct", %{
        "logical_scene_id" => logical_scene_id,
        "source_x" => 0,
        "source_y" => 1,
        "source_z" => 0,
        "target_x" => 3,
        "target_y" => 1,
        "target_z" => 0
      })

    body = json_response(conn, 422)
    assert body["error"] == "voxel_conduct_failed"
    assert body["reason_code"] == "no_conductive_path"
  end

  defp put_authorized_blocks!(logical_scene_id, chunk_coord, entries) do
    assert {:ok, %{lease: lease}} =
             MapLedger.route_chunk_with_lease(logical_scene_id, chunk_coord)

    intents =
      Enum.map(entries, fn {macro, material_id} ->
        %{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          lease: lease,
          operation: :put_solid_block,
          macro: macro,
          block: NormalBlockData.new(material_id)
        }
      end)

    assert {:ok, %{changed_count: changed_count}} = ChunkDirectory.apply_intents(intents)
    assert changed_count == length(entries)

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: chunk_coord,
               lease: lease
             })

    chunk_pid
  end

  defp put_owned_micro_slots!(lease, world_macro, object_id, part_id, count) do
    intents =
      0..(count - 1)
      |> Enum.map(fn micro_slot ->
        %{
          request_id: 10_000 + micro_slot,
          logical_scene_id: lease.logical_scene_id,
          chunk_coord: {0, 0, 0},
          lease: lease,
          operation: :put_micro_block,
          macro: world_macro,
          micro_slot: micro_slot,
          micro_layer: %{
            material_id: MaterialCatalog.wood_material_id(),
            health: 100,
            owner_object_id: object_id,
            owner_part_id: part_id
          }
        }
      end)

    assert {:ok, %{changed_count: ^count}} = ChunkDirectory.apply_intents(intents)

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: lease.logical_scene_id,
               chunk_coord: {0, 0, 0},
               lease: lease
             })

    chunk_pid
  end

  defp object_instance_attrs(overrides) do
    %{
      object_id: 42,
      logical_scene_id: 1,
      parcel_id: 13,
      blueprint_id: 7,
      blueprint_version: 2,
      anchor_world_micro: {0, 0, 0},
      rotation: 0,
      owner_actor_id: 1_001,
      state_flags: 0,
      object_attribute_ref: 0,
      object_tag_set_ref: 0,
      covered_chunks: [{0, 0, 0}],
      part_states: [
        %{part_id: 1, health: 80, state_flags: 0}
      ],
      object_version: 1,
      owner_region_id: 1,
      owner_lease_id: 100
    }
    |> Map.merge(Map.new(overrides))
  end

  defp assert_eventually(fun, timeout_ms \\ 2_000) do
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

  defp fixed32(value), do: round(value * 65_536)
end
