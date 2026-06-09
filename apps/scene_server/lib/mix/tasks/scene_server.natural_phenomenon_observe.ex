defmodule Mix.Tasks.SceneServer.NaturalPhenomenonObserve do
  @moduledoc """
  Runs a scene-side natural-phenomenon observe smoke for combustion or corrosion.

      mix scene_server.natural_phenomenon_observe --logical-scene-id 1 --coord 0,0,0
      mix scene_server.natural_phenomenon_observe --scenario spread --coord 0,0,0
      mix scene_server.natural_phenomenon_observe --phenomenon corrosion --coord 0,0,0

  The task places a material voxel, drives the selected formal entry, waits for
  the authority-owned field tick to change it, then reads the matching read-only
  phenomenon probe. It is meant to produce a CLI/log artifact for validating
  Phase 8 natural-phenomenon slices without relying on browser visuals.
  """

  use Mix.Task

  alias SceneServer.CliObserve

  alias SceneServer.Voxel.{
    ChunkDirectory,
    ChunkProcess,
    MaterialCatalog,
    NormalBlockData,
    Types
  }

  alias SceneServer.Voxel.Field.{DevFieldCreate, FieldRegion, FieldTickWorker, ThermalKernelSpecs}
  alias SceneServer.Voxel.Phenomenon.{CorrosionKernel, Effect}

  @shortdoc "Runs a natural phenomenon CLI observe smoke"
  @switches [
    help: :boolean,
    phenomenon: :string,
    scenario: :string,
    logical_scene_id: :integer,
    coord: :string,
    material: :string,
    target_temperature: :float,
    moisture: :float,
    chemical_concentration: :float,
    max_ticks: :integer,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [
    h: :help,
    p: :phenomenon,
    s: :logical_scene_id,
    c: :coord,
    m: :material,
    o: :observe_dir,
    l: :observe_log
  ]
  @default_coord "0,0,0"
  @default_combustion_material "wood"
  @default_corrosion_material "iron"
  @default_combustion_scenario "single"
  @default_target_temperature 720.0
  @default_corrosion_moisture 120.0
  @default_chemical_concentration 45.0
  @default_max_ticks 8
  @default_spread_max_ticks 24
  @spread_probe_timeout_ms 4_000
  @probe_timeout_ms 2_000
  @probe_interval_ms 25
  @worker_timeout_ms 2_000

  @doc false
  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        run_smoke(opts)
    end
  end

  defp run_smoke(opts) do
    {:ok, _apps} = Application.ensure_all_started(:scene_server)

    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    world_macro = parse_coord!(Keyword.get(opts, :coord, @default_coord))
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    phenomenon = phenomenon!(Keyword.get(opts, :phenomenon, "combustion"))
    scenario = scenario!(Keyword.get(opts, :scenario, default_scenario(phenomenon)), phenomenon)
    material_name = Keyword.get(opts, :material, default_material(phenomenon))
    material_id = material_id!(material_name)
    target_temperature = Keyword.get(opts, :target_temperature, @default_target_temperature)
    max_ticks = Keyword.get(opts, :max_ticks, default_max_ticks(phenomenon, scenario))
    observe_log = observe_path(opts, logical_scene_id)
    previous_log = Application.fetch_env(:scene_server, :cli_observe_log)

    try do
      File.mkdir_p!(Path.dirname(observe_log))
      File.rm(observe_log)
      Application.put_env(:scene_server, :cli_observe_log, observe_log)

      {:ok, chunk_pid} =
        ChunkDirectory.ensure_chunk(%{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord
        })

      summary =
        case {phenomenon, scenario} do
          {:combustion, :single} ->
            {:ok, _storage} =
              ChunkProcess.put_solid_block(
                chunk_pid,
                local_macro,
                NormalBlockData.new(material_id)
              )

            run_combustion_smoke(
              logical_scene_id,
              world_macro,
              material_name,
              target_temperature,
              max_ticks,
              observe_log
            )

          {:combustion, :spread} ->
            run_combustion_spread_smoke(
              logical_scene_id,
              world_macro,
              material_name,
              target_temperature,
              max_ticks,
              observe_log
            )

          {:corrosion, :single} ->
            {:ok, _storage} =
              ChunkProcess.put_solid_block(
                chunk_pid,
                local_macro,
                NormalBlockData.new(material_id)
              )

            run_corrosion_smoke(
              logical_scene_id,
              chunk_pid,
              chunk_coord,
              local_macro,
              world_macro,
              material_name,
              opts,
              max_ticks,
              observe_log
            )
        end

      CliObserve.emit("scene_natural_phenomenon_smoke_completed", summary)
      CliObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      CliObserve.flush()
      restore_observe_log(previous_log)
    end
  rescue
    error in Mix.Error ->
      reraise error, __STACKTRACE__

    error ->
      Mix.raise("scene natural phenomenon observe failed: #{Exception.message(error)}")
  catch
    kind, reason ->
      Mix.raise("scene natural phenomenon observe failed: #{inspect({kind, reason})}")
  end

  defp run_combustion_smoke(
         logical_scene_id,
         world_macro,
         material_name,
         target_temperature,
         max_ticks,
         observe_log
       ) do
    {:ok, heat_summary} =
      DevFieldCreate.set_temperature(
        logical_scene_id: logical_scene_id,
        world_macro: world_macro,
        target_temperature_celsius: target_temperature,
        max_ticks: max_ticks
      )

    {:ok, combustion_summary} =
      wait_for_active_combustion(logical_scene_id, world_macro, @probe_timeout_ms)

    combustion_summary(
      logical_scene_id,
      world_macro,
      material_name,
      target_temperature,
      max_ticks,
      heat_summary,
      combustion_summary,
      observe_log
    )
  end

  defp run_combustion_spread_smoke(
         logical_scene_id,
         source_world_macro,
         source_material_name,
         target_temperature,
         max_ticks,
         observe_log
       ) do
    spread_cells = combustion_spread_cells(source_world_macro, source_material_name)

    for %{world_macro: world_macro, initial_material: material_name} = cell <- spread_cells do
      {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
      macro_index = Types.macro_index!(local_macro)

      {:ok, chunk_pid} =
        ChunkDirectory.ensure_chunk(%{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord
        })

      {:ok, _storage} =
        ChunkProcess.put_solid_block(
          chunk_pid,
          local_macro,
          NormalBlockData.new(material_id!(material_name))
        )

      apply_combustion_spread_cell_setup(chunk_pid, macro_index, Map.get(cell, :setup, %{}))
    end

    {:ok, heat_summary} =
      DevFieldCreate.set_temperature(
        logical_scene_id: logical_scene_id,
        world_macro: source_world_macro,
        target_temperature_celsius: target_temperature,
        max_ticks: max_ticks,
        radius: 4,
        kernel_specs: combustion_spread_kernel_specs()
      )

    {:ok, cell_summaries} =
      wait_for_combustion_spread(logical_scene_id, spread_cells, @spread_probe_timeout_ms)

    Enum.each(cell_summaries, fn cell ->
      CliObserve.emit("scene_combustion_spread_cell_observed", cell)
    end)

    combustion_spread_summary(
      logical_scene_id,
      source_world_macro,
      source_material_name,
      target_temperature,
      max_ticks,
      heat_summary,
      cell_summaries,
      observe_log
    )
  end

  defp apply_combustion_spread_cell_setup(_chunk_pid, _macro_index, nil), do: :ok

  defp apply_combustion_spread_cell_setup(_chunk_pid, _macro_index, setup)
       when map_size(setup) == 0,
       do: :ok

  defp apply_combustion_spread_cell_setup(chunk_pid, macro_index, %{oxygen_percent: oxygen}) do
    {:ok, %{rejected_count: 0}} =
      ChunkProcess.apply_field_effects(
        chunk_pid,
        [Effect.write_voxel_attribute(macro_index, :oxygen, fixed32(oxygen))],
        %{kernel_id: :natural_phenomenon_combustion_spread_setup}
      )

    :ok
  end

  defp run_corrosion_smoke(
         logical_scene_id,
         chunk_pid,
         chunk_coord,
         local_macro,
         world_macro,
         material_name,
         opts,
         max_ticks,
         observe_log
       ) do
    macro_index = Types.macro_index!(local_macro)
    moisture = Keyword.get(opts, :moisture, @default_corrosion_moisture)

    chemical_concentration =
      Keyword.get(opts, :chemical_concentration, @default_chemical_concentration)

    {:ok, %{rejected_count: 0}} =
      ChunkProcess.apply_field_effects(
        chunk_pid,
        [
          Effect.write_voxel_attribute(macro_index, :moisture, fixed32(moisture)),
          Effect.write_voxel_attribute(
            macro_index,
            :chemical_concentration,
            fixed32(chemical_concentration)
          )
        ],
        %{kernel_id: :natural_phenomenon_corrosion_setup}
      )

    region =
      FieldRegion.new(%{
        region_id: System.unique_integer([:positive]),
        chunk_coord: chunk_coord,
        aabb: {local_macro, local_macro},
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

    :ok = wait_for_field_worker(pid, @worker_timeout_ms)

    {:ok, corrosion_summary} =
      wait_for_active_corrosion(logical_scene_id, world_macro, @probe_timeout_ms)

    corrosion_summary(
      logical_scene_id,
      world_macro,
      material_name,
      moisture,
      chemical_concentration,
      max_ticks,
      corrosion_summary,
      observe_log
    )
  end

  defp wait_for_active_combustion(logical_scene_id, world_macro, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_active_combustion(logical_scene_id, world_macro, deadline)
  end

  defp do_wait_for_active_combustion(logical_scene_id, world_macro, deadline) do
    case DevFieldCreate.combustion_probe(
           logical_scene_id: logical_scene_id,
           world_macro: world_macro
         ) do
      {:ok, %{active_combustion: true} = summary} ->
        {:ok, summary}

      {:ok, summary} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:combustion_not_active, summary}}
        else
          :timer.sleep(@probe_interval_ms)
          do_wait_for_active_combustion(logical_scene_id, world_macro, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_combustion_spread(logical_scene_id, spread_cells, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_combustion_spread(logical_scene_id, spread_cells, deadline)
  end

  defp do_wait_for_combustion_spread(logical_scene_id, spread_cells, deadline) do
    case probe_combustion_spread(logical_scene_id, spread_cells) do
      {:ok, cell_summaries} ->
        if combustion_spread_observed?(cell_summaries) or
             System.monotonic_time(:millisecond) >= deadline do
          if combustion_spread_observed?(cell_summaries) do
            {:ok, cell_summaries}
          else
            {:error, {:combustion_spread_not_observed, cell_summaries}}
          end
        else
          :timer.sleep(@probe_interval_ms)
          do_wait_for_combustion_spread(logical_scene_id, spread_cells, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_combustion_spread(logical_scene_id, spread_cells) do
    spread_cells
    |> Enum.reduce_while({:ok, []}, fn cell, {:ok, summaries} ->
      case DevFieldCreate.combustion_probe(
             logical_scene_id: logical_scene_id,
             world_macro: cell.world_macro
           ) do
        {:ok, probe_summary} ->
          {:cont, {:ok, [combustion_spread_cell_summary(cell, probe_summary) | summaries]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp combustion_spread_observed?(cell_summaries) do
    source_residue? = cell_outcome?(cell_summaries, :source, :material_residue)
    char_fuel_charcoal? = cell_current_material?(cell_summaries, :char_fuel, "charcoal")
    fast_fuel_cleared? = cell_outcome?(cell_summaries, :fast_fuel, :cleared)
    ash_fuel_residue? = cell_outcome?(cell_summaries, :ash_fuel, :material_residue)

    inert_control_stable? =
      Enum.any?(cell_summaries, fn
        %{
          role: :inert_control,
          active_combustion: false,
          initial_material: material,
          current_material: material
        } ->
          true

        _other ->
          false
      end)

    source_residue? and char_fuel_charcoal? and fast_fuel_cleared? and ash_fuel_residue? and
      inert_control_stable?
  end

  defp cell_outcome?(cell_summaries, role, outcome) do
    Enum.any?(cell_summaries, fn
      %{role: ^role, outcome: ^outcome} -> true
      _other -> false
    end)
  end

  defp cell_current_material?(cell_summaries, role, material) do
    Enum.any?(cell_summaries, fn
      %{role: ^role, current_material: ^material} -> true
      _other -> false
    end)
  end

  defp wait_for_active_corrosion(logical_scene_id, world_macro, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_active_corrosion(logical_scene_id, world_macro, deadline)
  end

  defp do_wait_for_active_corrosion(logical_scene_id, world_macro, deadline) do
    case DevFieldCreate.corrosion_probe(
           logical_scene_id: logical_scene_id,
           world_macro: world_macro
         ) do
      {:ok, %{active_corrosion: true} = summary} ->
        {:ok, summary}

      {:ok, summary} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:corrosion_not_active, summary}}
        else
          :timer.sleep(@probe_interval_ms)
          do_wait_for_active_corrosion(logical_scene_id, world_macro, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_field_worker(pid, timeout_ms) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, {:field_worker_stopped, reason}}
    after
      timeout_ms -> {:error, :field_worker_timeout}
    end
  end

  defp combustion_spread_summary(
         logical_scene_id,
         source_world_macro,
         source_material_name,
         target_temperature,
         max_ticks,
         heat_summary,
         cell_summaries,
         observe_log
       ) do
    %{
      phenomenon: :combustion,
      scenario: :spread,
      logical_scene_id: logical_scene_id,
      coord: Tuple.to_list(source_world_macro),
      material: source_material_name,
      target_temperature_celsius: target_temperature,
      max_ticks: max_ticks,
      field_region_created: Map.get(heat_summary, :field_region_created),
      region_id: Map.get(heat_summary, :region_id),
      spread_cell_count: length(cell_summaries),
      spread_ignited_count: Enum.count(cell_summaries, &spread_cell_ignited_or_consumed?/1),
      spread_residue_count:
        Enum.count(cell_summaries, &(&1.outcome in [:cleared, :material_residue])),
      spread_inert_count:
        Enum.count(cell_summaries, fn
          %{
            role: :inert_control,
            active_combustion: false,
            initial_material: material,
            current_material: material
          } ->
            true

          _other ->
            false
        end),
      spread_cells: cell_summaries,
      observe_log: observe_log
    }
  end

  defp combustion_summary(
         logical_scene_id,
         world_macro,
         material_name,
         target_temperature,
         max_ticks,
         heat_summary,
         combustion_summary,
         observe_log
       ) do
    attrs = Map.fetch!(combustion_summary, :attributes)

    %{
      phenomenon: :combustion,
      scenario: :single,
      logical_scene_id: logical_scene_id,
      coord: Tuple.to_list(world_macro),
      material: material_name,
      target_temperature_celsius: target_temperature,
      max_ticks: max_ticks,
      field_region_created: Map.get(heat_summary, :field_region_created),
      region_id: Map.get(heat_summary, :region_id),
      combustion_stage: Map.fetch!(combustion_summary, :combustion_stage),
      active_combustion: Map.fetch!(combustion_summary, :active_combustion),
      active_combustion_instance: Map.fetch!(combustion_summary, :active_combustion_instance),
      fuel_mass_kg_per_m3: Map.fetch!(attrs, :fuel_mass_kg_per_m3),
      oxygen_percent: Map.fetch!(attrs, :oxygen_percent),
      smoke_density_percent: Map.fetch!(attrs, :smoke_density_percent),
      carbonization_percent: Map.fetch!(attrs, :carbonization_percent),
      structural_integrity_percent: Map.fetch!(attrs, :structural_integrity_percent),
      observe_log: observe_log
    }
  end

  defp corrosion_summary(
         logical_scene_id,
         world_macro,
         material_name,
         moisture,
         chemical_concentration,
         max_ticks,
         corrosion_summary,
         observe_log
       ) do
    attrs = Map.fetch!(corrosion_summary, :attributes)

    %{
      phenomenon: :corrosion,
      logical_scene_id: logical_scene_id,
      coord: Tuple.to_list(world_macro),
      material: material_name,
      moisture_kg_per_m3: moisture,
      chemical_concentration_percent: chemical_concentration,
      max_ticks: max_ticks,
      surface_state: Map.fetch!(corrosion_summary, :surface_state),
      active_corrosion: Map.fetch!(corrosion_summary, :active_corrosion),
      active_corrosion_instance: Map.fetch!(corrosion_summary, :active_corrosion_instance),
      corrosion_percent: Map.fetch!(attrs, :corrosion_percent),
      corrosion_resistance_percent: Map.fetch!(attrs, :corrosion_resistance_percent),
      structural_integrity_percent: Map.fetch!(attrs, :structural_integrity_percent),
      electric_conductivity_ms_per_m: Map.fetch!(attrs, :electric_conductivity_ms_per_m),
      observe_log: observe_log
    }
  end

  defp combustion_spread_cell_summary(cell, probe_summary) do
    attrs = Map.fetch!(probe_summary, :attributes)
    current_material_id = Map.get(probe_summary, :material_id)
    current_material = material_name_from_id(current_material_id)
    cell_mode = Map.fetch!(probe_summary, :cell_mode)

    %{
      role: cell.role,
      coord: Tuple.to_list(cell.world_macro),
      initial_material: cell.initial_material,
      current_material: current_material,
      current_material_id: current_material_id,
      cell_mode: cell_mode,
      combustible: Map.fetch!(probe_summary, :combustible),
      combustion_stage: Map.fetch!(probe_summary, :combustion_stage),
      active_combustion: Map.fetch!(probe_summary, :active_combustion),
      active_combustion_instance: Map.fetch!(probe_summary, :active_combustion_instance),
      outcome: combustion_spread_outcome(cell.initial_material, current_material, cell_mode),
      fuel_mass_kg_per_m3: Map.fetch!(attrs, :fuel_mass_kg_per_m3),
      oxygen_percent: Map.fetch!(attrs, :oxygen_percent),
      smoke_density_percent: Map.fetch!(attrs, :smoke_density_percent),
      carbonization_percent: Map.fetch!(attrs, :carbonization_percent)
    }
  end

  defp combustion_spread_outcome(_initial_material, nil, :empty), do: :cleared
  defp combustion_spread_outcome(_initial_material, nil, "empty"), do: :cleared

  defp combustion_spread_outcome(initial_material, current_material, _cell_mode)
       when initial_material != current_material do
    :material_residue
  end

  defp combustion_spread_outcome(_initial_material, _current_material, _cell_mode), do: :unchanged

  defp spread_cell_ignited_or_consumed?(cell) do
    cell.active_combustion or
      cell.combustion_stage in [:burning, :smoldering, :extinguished] or
      cell.outcome in [:cleared, :material_residue]
  end

  defp combustion_spread_cells(source_world_macro, source_material_name) do
    x_direction = spread_x_direction(source_world_macro)
    y_direction = spread_y_direction(source_world_macro)
    z_direction = spread_z_direction(source_world_macro)

    [
      %{role: :source, offset: {0, 0, 0}, initial_material: source_material_name},
      %{role: :fast_fuel, offset: {x_direction, 0, 0}, initial_material: "dry_grass"},
      %{role: :ash_fuel, offset: {0, 0, z_direction}, initial_material: "cloth"},
      %{role: :inert_control, offset: {3 * x_direction, 0, 0}, initial_material: "stone"},
      %{
        role: :char_fuel,
        offset: {0, y_direction, 0},
        initial_material: "wood",
        setup: %{oxygen_percent: 2.0}
      }
    ]
    |> Enum.map(fn cell ->
      Map.put(cell, :world_macro, offset_world_macro(source_world_macro, cell.offset))
    end)
  end

  defp spread_x_direction(world_macro) do
    {_chunk_coord, {local_x, _local_y, _local_z}} = Types.chunk_and_local_macro!(world_macro)
    if local_x <= 12, do: 1, else: -1
  end

  defp spread_y_direction(world_macro) do
    {_chunk_coord, {_local_x, local_y, _local_z}} = Types.chunk_and_local_macro!(world_macro)
    if local_y <= 14, do: 1, else: -1
  end

  defp spread_z_direction(world_macro) do
    {_chunk_coord, {_local_x, _local_y, local_z}} = Types.chunk_and_local_macro!(world_macro)
    if local_z <= 14, do: 1, else: -1
  end

  defp offset_world_macro({x, y, z}, {x_offset, y_offset, z_offset}) do
    {x + x_offset, y + y_offset, z + z_offset}
  end

  defp combustion_spread_kernel_specs do
    ThermalKernelSpecs.temperature_source_specs(
      temperature_diffusion_time_scale: 100_000_000.0,
      temperature_ambient_loss_per_second: 0.0,
      combustion_opts: %{
        profile: %{
          initial_fuel_mass_kg_per_m3: 2.0,
          burn_rate_kg_per_m3_second: 5.0,
          combustion_heat_j_per_kg: 3_000_000_000.0,
          heat_release_efficiency: 1.0,
          heat_source_celsius: 2_500.0,
          smolder_heat_source_celsius: 900.0,
          oxygen_limited_carbonization_percent_per_second: 80.0,
          oxygen_limited_residue_threshold_percent: 35.0
        },
        profile_overrides: %{
          MaterialCatalog.dry_grass_material_id() => %{
            initial_fuel_mass_kg_per_m3: 1.0,
            burn_rate_kg_per_m3_second: 200.0
          },
          MaterialCatalog.charcoal_material_id() => %{
            ignition_temperature_celsius: 5_000.0
          }
        }
      }
    )
  end

  defp summary_line(summary) do
    base = [
      "scene_natural_phenomenon_observe=ok",
      "phenomenon=#{summary.phenomenon}",
      "scenario=#{Map.get(summary, :scenario, :single)}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "coord=#{Enum.join(summary.coord, ",")}",
      "material=#{summary.material}",
      "max_ticks=#{summary.max_ticks}"
    ]

    fields =
      case summary.phenomenon do
        :combustion ->
          combustion_summary_fields(summary)

        :corrosion ->
          [
            "moisture=#{format_float(summary.moisture_kg_per_m3)}",
            "chemical_concentration=#{format_float(summary.chemical_concentration_percent)}",
            "surface_state=#{summary.surface_state}",
            "active_corrosion=#{summary.active_corrosion}",
            "corrosion=#{format_float(summary.corrosion_percent)}",
            "conductivity=#{format_float(summary.electric_conductivity_ms_per_m)}",
            "structural_integrity=#{format_float(summary.structural_integrity_percent)}"
          ]
      end

    (base ++ fields ++ ["observe_log=#{summary.observe_log}"])
    |> Enum.join(" ")
  end

  defp combustion_summary_fields(%{scenario: :spread} = summary) do
    [
      "target_temperature=#{summary.target_temperature_celsius}",
      "field_region_created=#{summary.field_region_created}",
      "spread_cell_count=#{summary.spread_cell_count}",
      "spread_ignited_count=#{summary.spread_ignited_count}",
      "spread_residue_count=#{summary.spread_residue_count}",
      "spread_inert_count=#{summary.spread_inert_count}",
      "spread_cells=#{format_spread_cells(summary.spread_cells)}"
    ]
  end

  defp combustion_summary_fields(summary) do
    [
      "target_temperature=#{summary.target_temperature_celsius}",
      "combustion_stage=#{summary.combustion_stage}",
      "active_combustion=#{summary.active_combustion}",
      "fuel_mass=#{format_float(summary.fuel_mass_kg_per_m3)}",
      "smoke=#{format_float(summary.smoke_density_percent)}",
      "carbonization=#{format_float(summary.carbonization_percent)}",
      "structural_integrity=#{format_float(summary.structural_integrity_percent)}"
    ]
  end

  defp format_spread_cells(cells) do
    cells
    |> Enum.map(fn cell ->
      current = cell.current_material || "empty"
      "#{cell.role}:#{cell.initial_material}->#{current}:#{cell.combustion_stage}:#{cell.outcome}"
    end)
    |> Enum.join(",")
  end

  defp phenomenon!("combustion"), do: :combustion
  defp phenomenon!("corrosion"), do: :corrosion

  defp phenomenon!(phenomenon) when is_binary(phenomenon) do
    phenomenon
    |> String.downcase()
    |> phenomenon!()
  end

  defp phenomenon!(phenomenon) do
    Mix.raise("unsupported phenomenon #{inspect(phenomenon)}; expected combustion or corrosion")
  end

  defp scenario!(scenario, phenomenon) when is_binary(scenario) do
    case String.downcase(scenario) do
      "single" ->
        :single

      "spread" when phenomenon == :combustion ->
        :spread

      normalized when phenomenon == :combustion ->
        Mix.raise(
          "unsupported combustion scenario #{inspect(normalized)}; expected single or spread"
        )

      normalized ->
        Mix.raise("unsupported #{phenomenon} scenario #{inspect(normalized)}; expected single")
    end
  end

  defp scenario!(scenario, :combustion) do
    Mix.raise("unsupported combustion scenario #{inspect(scenario)}; expected single or spread")
  end

  defp scenario!(scenario, phenomenon) do
    Mix.raise("unsupported #{phenomenon} scenario #{inspect(scenario)}; expected single")
  end

  defp default_scenario(:combustion), do: @default_combustion_scenario
  defp default_scenario(:corrosion), do: "single"

  defp default_max_ticks(:combustion, :spread), do: @default_spread_max_ticks
  defp default_max_ticks(_phenomenon, _scenario), do: @default_max_ticks

  defp default_material(:combustion), do: @default_combustion_material
  defp default_material(:corrosion), do: @default_corrosion_material

  defp material_id!("iron"), do: 5
  defp material_id!("stone"), do: 2
  defp material_id!("power_block"), do: MaterialCatalog.power_source_material_id()
  defp material_id!("electric_load"), do: MaterialCatalog.electric_load_material_id()
  defp material_id!("wood"), do: MaterialCatalog.wood_material_id()
  defp material_id!("charcoal"), do: MaterialCatalog.charcoal_material_id()
  defp material_id!("dry_grass"), do: MaterialCatalog.dry_grass_material_id()
  defp material_id!("cloth"), do: MaterialCatalog.cloth_material_id()

  defp material_id!(material) do
    Mix.raise(
      "unsupported material #{inspect(material)}; expected wood, charcoal, dry_grass, cloth, stone, iron, power_block, or electric_load"
    )
  end

  defp material_name_from_id(nil), do: nil

  defp material_name_from_id(material_id) do
    case material_id do
      1 -> "dirt"
      2 -> "stone"
      3 -> "wood"
      4 -> "ice"
      5 -> "iron"
      6 -> "power_block"
      7 -> "electric_load"
      8 -> "ash"
      9 -> "charcoal"
      10 -> "dry_grass"
      11 -> "cloth"
      other -> "material_#{other}"
    end
  end

  defp fixed32(value), do: round(value * 65_536)

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "scene-natural-phenomenon-#{logical_scene_id}.log")
    )
  end

  defp parse_coord!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
      _other -> Mix.raise("coord must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("coord must be formatted as x,y,z")
  end

  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_float(value), do: to_string(value)

  defp restore_observe_log({:ok, value}),
    do: Application.put_env(:scene_server, :cli_observe_log, value)

  defp restore_observe_log(:error), do: Application.delete_env(:scene_server, :cli_observe_log)
end
