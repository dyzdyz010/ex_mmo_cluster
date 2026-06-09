defmodule Mix.Tasks.SceneServer.NaturalPhenomenonObserve do
  @moduledoc """
  Runs a scene-side natural-phenomenon observe smoke for combustion or corrosion.

      mix scene_server.natural_phenomenon_observe --logical-scene-id 1 --coord 0,0,0
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

  alias SceneServer.Voxel.Field.{DevFieldCreate, FieldRegion, FieldTickWorker}
  alias SceneServer.Voxel.Phenomenon.{CorrosionKernel, Effect}

  @shortdoc "Runs a natural phenomenon CLI observe smoke"
  @switches [
    help: :boolean,
    phenomenon: :string,
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
  @default_target_temperature 720.0
  @default_corrosion_moisture 120.0
  @default_chemical_concentration 45.0
  @default_max_ticks 8
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
    material_name = Keyword.get(opts, :material, default_material(phenomenon))
    material_id = material_id!(material_name)
    target_temperature = Keyword.get(opts, :target_temperature, @default_target_temperature)
    max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)
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

      {:ok, _storage} =
        ChunkProcess.put_solid_block(
          chunk_pid,
          local_macro,
          NormalBlockData.new(material_id)
        )

      summary =
        case phenomenon do
          :combustion ->
            run_combustion_smoke(
              logical_scene_id,
              world_macro,
              material_name,
              target_temperature,
              max_ticks,
              observe_log
            )

          :corrosion ->
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

  defp summary_line(summary) do
    base = [
      "scene_natural_phenomenon_observe=ok",
      "phenomenon=#{summary.phenomenon}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "coord=#{Enum.join(summary.coord, ",")}",
      "material=#{summary.material}",
      "max_ticks=#{summary.max_ticks}"
    ]

    fields =
      case summary.phenomenon do
        :combustion ->
          [
            "target_temperature=#{summary.target_temperature_celsius}",
            "combustion_stage=#{summary.combustion_stage}",
            "active_combustion=#{summary.active_combustion}",
            "fuel_mass=#{format_float(summary.fuel_mass_kg_per_m3)}",
            "smoke=#{format_float(summary.smoke_density_percent)}",
            "carbonization=#{format_float(summary.carbonization_percent)}",
            "structural_integrity=#{format_float(summary.structural_integrity_percent)}"
          ]

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

  defp default_material(:combustion), do: @default_combustion_material
  defp default_material(:corrosion), do: @default_corrosion_material

  defp material_id!("iron"), do: 5
  defp material_id!("power_block"), do: MaterialCatalog.power_source_material_id()
  defp material_id!("electric_load"), do: MaterialCatalog.electric_load_material_id()
  defp material_id!("wood"), do: MaterialCatalog.wood_material_id()
  defp material_id!("charcoal"), do: MaterialCatalog.charcoal_material_id()
  defp material_id!("dry_grass"), do: MaterialCatalog.dry_grass_material_id()
  defp material_id!("cloth"), do: MaterialCatalog.cloth_material_id()

  defp material_id!(material) do
    Mix.raise(
      "unsupported material #{inspect(material)}; expected wood, charcoal, dry_grass, cloth, iron, power_block, or electric_load"
    )
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
