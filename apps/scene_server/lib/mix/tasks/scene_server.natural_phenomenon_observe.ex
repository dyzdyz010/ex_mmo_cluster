defmodule Mix.Tasks.SceneServer.NaturalPhenomenonObserve do
  @moduledoc """
  Runs a scene-side natural-phenomenon observe smoke for high-temperature combustion.

      mix scene_server.natural_phenomenon_observe --logical-scene-id 1 --coord 0,0,0

  The task places a combustible voxel, drives the formal set-temperature entry,
  waits for the authority-owned field tick to ignite it, then reads the
  read-only combustion probe. It is meant to produce a CLI/log artifact for
  validating the current Phase 8 combustion slice without relying on browser
  visuals.
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

  alias SceneServer.Voxel.Field.DevFieldCreate

  @shortdoc "Runs a natural phenomenon high-temperature combustion CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    coord: :string,
    material: :string,
    target_temperature: :float,
    max_ticks: :integer,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [
    h: :help,
    s: :logical_scene_id,
    c: :coord,
    m: :material,
    o: :observe_dir,
    l: :observe_log
  ]
  @default_coord "0,0,0"
  @default_material "wood"
  @default_target_temperature 720.0
  @default_max_ticks 8
  @probe_timeout_ms 2_000
  @probe_interval_ms 25

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
    material_name = Keyword.get(opts, :material, @default_material)
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

      {:ok, heat_summary} =
        DevFieldCreate.set_temperature(
          logical_scene_id: logical_scene_id,
          world_macro: world_macro,
          target_temperature_celsius: target_temperature,
          max_ticks: max_ticks
        )

      {:ok, combustion_summary} =
        wait_for_active_combustion(logical_scene_id, world_macro, @probe_timeout_ms)

      summary =
        summary(
          logical_scene_id,
          world_macro,
          material_name,
          target_temperature,
          max_ticks,
          heat_summary,
          combustion_summary,
          observe_log
        )

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

  defp summary(
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

  defp summary_line(summary) do
    [
      "scene_natural_phenomenon_observe=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "coord=#{Enum.join(summary.coord, ",")}",
      "material=#{summary.material}",
      "target_temperature=#{summary.target_temperature_celsius}",
      "combustion_stage=#{summary.combustion_stage}",
      "active_combustion=#{summary.active_combustion}",
      "fuel_mass=#{format_float(summary.fuel_mass_kg_per_m3)}",
      "smoke=#{format_float(summary.smoke_density_percent)}",
      "carbonization=#{format_float(summary.carbonization_percent)}",
      "structural_integrity=#{format_float(summary.structural_integrity_percent)}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp material_id!("wood"), do: MaterialCatalog.wood_material_id()
  defp material_id!("charcoal"), do: MaterialCatalog.charcoal_material_id()
  defp material_id!("dry_grass"), do: MaterialCatalog.dry_grass_material_id()
  defp material_id!("cloth"), do: MaterialCatalog.cloth_material_id()

  defp material_id!(material) do
    Mix.raise(
      "unsupported material #{inspect(material)}; expected wood, charcoal, dry_grass, or cloth"
    )
  end

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
