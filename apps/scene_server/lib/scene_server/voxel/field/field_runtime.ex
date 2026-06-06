defmodule SceneServer.Voxel.Field.FieldRuntime do
  @moduledoc """
  Runtime entrypoint for turning abnormal voxel attributes into local fields.

  Normal environment values stay on voxel storage and do not allocate a
  `FieldRegion`.  A skill/request may mutate the authoritative voxel
  attribute, but anomaly detection always reads the post-write voxel truth
  before creating any local field.
  """

  alias SceneServer.CliObserve

  alias SceneServer.Voxel.{
    ChunkDirectory,
    ChunkProcess,
    MaterialCatalog,
    MicroLayer,
    NormalBlockData,
    RefinedCellData,
    Storage,
    Types
  }

  alias SceneServer.Voxel.Field.{CircuitComponentAnalysis, FieldRegion, FieldSource}
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.Field.Kernels.ConductionPathKernel
  alias SceneServer.Voxel.Field.Kernels.ElectricDischargeKernel
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.Field.PowerSource
  alias SceneServer.Voxel.Field.TemperatureField

  @default_logical_scene_id 1
  @default_max_ticks 600
  @default_radius 4
  @default_conduction_max_frontier 512
  @default_target_temperature_celsius 800.0
  @temperature_diffusion_time_scale 1.0
  @temperature_ambient_loss_per_second 0.0
  @temperature_cell_size_meters 1.0
  @temperature_threshold 1.0
  @conduction_power_policy_tick_ms 100
  @fixed32_scale 65_536

  @doc """
  Injects the requested heat skill into voxel attributes, then creates a local
  temperature `FieldRegion` only if the voxel's effective temperature is
  abnormal relative to the environment baseline.
  """
  @spec ensure_temperature_anomaly(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def ensure_temperature_anomaly(opts \\ []) do
    opts = opts_map(opts)
    field_source = get_any(opts, [:field_source], nil)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    world_macro = world_macro_coord(opts)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    heat_request = heat_request(opts)

    with {:ok, chunk_pid} <-
           ChunkDirectory.ensure_chunk(%{
             logical_scene_id: logical_scene_id,
             chunk_coord: chunk_coord,
             lease: get_any(opts, [:lease, :lease_token], nil)
           }),
         {:ok, %{storage: %Storage{} = storage} = write_summary} <-
           write_temperature_request(chunk_pid, local_macro, heat_request) do
      anomaly_opts =
        opts
        |> Map.put(:logical_scene_id, logical_scene_id)
        |> Map.put(:world_macro, world_macro)
        |> Map.put(:storage, storage)
        |> maybe_put(:field_source, field_source)

      case build_temperature_anomaly(anomaly_opts) do
        {:ignore, summary} ->
          {:ok,
           summary
           |> Map.put(:field_region_created, false)
           |> maybe_put(
             :field_region_cleanup,
             maybe_cleanup_ignored_field_region(chunk_pid, field_source, summary, opts)
           )
           |> Map.put(:attribute_write, summarize_attribute_write(write_summary))}

        {:ok, plan} ->
          region_attrs = Map.put(plan.region_attrs, :source_key, plan.source_key)

          with {:ok, field_region} <- ChunkProcess.ensure_field_region(chunk_pid, region_attrs) do
            {:ok,
             plan.summary
             |> Map.put(:region_id, field_region.region_id)
             |> Map.put(:field_region_created, field_region.created?)
             |> Map.put(:attribute_write, summarize_attribute_write(write_summary))}
          end
      end
    end
  rescue
    error -> {:error, {:temperature_anomaly_failed, error}}
  catch
    kind, reason -> {:error, {:temperature_anomaly_failed, kind, reason}}
  end

  @doc """
  Sets a voxel's target temperature through the formal Phase 7.D1 temperature
  path. Cooling is represented only as a lower `:target_temperature_celsius`,
  never as negative heat energy.
  """
  @spec ensure_set_temperature(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def ensure_set_temperature(opts \\ []) do
    opts = opts_map(opts)
    target_temperature = set_temperature_target(opts)

    field_source =
      opts
      |> drop_heat_request_keys()
      |> Map.put(:source_kind, :temperature)
      |> Map.put(:source_mode, set_temperature_source_mode(opts))
      |> Map.put(:target_temperature_celsius, target_temperature)
      |> FieldSource.normalize()

    opts
    |> drop_heat_request_keys()
    |> Map.put(:field_source, field_source)
    |> Map.put(:cleanup_on_ignore, true)
    |> Map.merge(FieldSource.temperature_runtime_attrs(field_source))
    |> ensure_temperature_anomaly()
  end

  @doc """
  Creates or refreshes a chunk-local automatic circuit field.

  The region is source-owned at the chunk level, not by an explicit target:
  every tick reads current voxel truth, projects power-source/load/conductor
  participants, and only writes current when a source-load connected component
  exists.
  """
  @spec ensure_auto_circuit(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def ensure_auto_circuit(opts \\ []) do
    opts = opts_map(opts)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    world_macro = world_macro_coord(opts)
    {chunk_coord, _local_macro} = Types.chunk_and_local_macro!(world_macro)
    source_key = {:auto_circuit, logical_scene_id, chunk_coord}
    aabb = full_chunk_aabb()
    max_ticks = auto_circuit_max_ticks(opts)

    with {:ok, chunk_pid} <-
           ChunkDirectory.ensure_chunk(%{
             logical_scene_id: logical_scene_id,
             chunk_coord: chunk_coord,
             lease: get_any(opts, [:lease, :lease_token], nil)
           }) do
      %{storage: %Storage{} = storage} = ChunkProcess.debug_state(chunk_pid)
      projection = ParticipantProjection.build(storage)
      source_points = auto_circuit_source_points(projection, aabb, opts)
      load_count = auto_circuit_role_count(projection, aabb, :load)
      power_source = auto_circuit_power_source(opts)
      kernel_spec = auto_circuit_kernel_spec(opts)

      topology =
        auto_circuit_topology_summary(
          projection,
          aabb,
          chunk_coord,
          source_points,
          kernel_spec
        )

      base_summary = %{
        logical_scene_id: logical_scene_id,
        world_macro: coord_map(world_macro),
        chunk_coord: coord_map(chunk_coord),
        source_key: source_key,
        field_types: ["electric_potential", "electric_current", "ionization"],
        max_ticks: max_ticks,
        source_count: length(source_points),
        load_count: load_count,
        closed_circuit_count: topology.closed_circuit_count
      }

      cond do
        source_points == [] ->
          {:ok, cleanup} =
            ChunkProcess.release_field_region_source(chunk_pid, source_key, :explicit)

          {:ok,
           base_summary
           |> Map.put(:created, false)
           |> Map.put(:field_region_created, false)
           |> Map.put(:reason, :no_power_source)
           |> Map.put(:field_region_cleanup, cleanup)}

        load_count == 0 ->
          {:ok, cleanup} =
            ChunkProcess.release_field_region_source(chunk_pid, source_key, :explicit)

          {:ok,
           base_summary
           |> Map.put(:created, false)
           |> Map.put(:field_region_created, false)
           |> Map.put(:waiting_for_load, false)
           |> Map.put(:reason, :no_load)
           |> Map.put(:field_region_cleanup, cleanup)}

        topology.closed_circuit_count == 0 ->
          {:ok, cleanup} =
            ChunkProcess.release_field_region_source(chunk_pid, source_key, :explicit)

          {:ok,
           base_summary
           |> Map.put(:created, false)
           |> Map.put(:field_region_created, false)
           |> Map.put(:waiting_for_load, false)
           |> Map.put(:reason, :no_closed_circuit)
           |> Map.put(:field_region_cleanup, cleanup)}

        true ->
          region_attrs = %{
            chunk_coord: chunk_coord,
            aabb: aabb,
            kernels: [kernel_spec],
            source_points: source_points,
            max_ticks: max_ticks,
            source_points_mode: :replace,
            source_key: source_key
          }

          with {:ok, field_region} <- ChunkProcess.ensure_field_region(chunk_pid, region_attrs) do
            {:ok,
             base_summary
             |> Map.put(:created, true)
             |> Map.put(:waiting_for_load, false)
             |> Map.put(:region_id, field_region.region_id)
             |> Map.put(:field_region_created, field_region.created?)
             |> Map.put(:source_points_action, field_region.source_points_action)
             |> Map.put(:power_draw, power_observe_fields(power_source))}
          end
      end
    end
  rescue
    error -> {:error, {:auto_circuit_failed, error}}
  catch
    kind, reason -> {:error, {:auto_circuit_failed, kind, reason}}
  end

  @doc """
  Creates an electric conduction field from an explicit source to an explicit
  target.

  This is a gameplay/debug runtime request, not a voxel-truth mutation: it
  allocates chunk-local `ConductionPathKernel` regions and leaves
  material/electric effects inside the field layers for the normal 0x73 field
  snapshot pipeline. Same-chunk requests allocate one source-owned region;
  adjacent cross-chunk boundary requests coordinate one source shard plus one
  stable target shard.
  """
  @spec ensure_conduction_path(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def ensure_conduction_path(opts \\ []) do
    opts = opts_map(opts)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    source_world_macro = source_world_macro_coord(opts)
    target_world_macro = target_world_macro_coord(opts)
    {source_chunk_coord, source_local_macro} = Types.chunk_and_local_macro!(source_world_macro)
    {target_chunk_coord, target_local_macro} = Types.chunk_and_local_macro!(target_world_macro)

    if source_chunk_coord != target_chunk_coord do
      validate_cross_chunk_conduction_boundary(
        opts,
        logical_scene_id,
        source_world_macro,
        target_world_macro,
        source_chunk_coord,
        source_local_macro,
        target_chunk_coord,
        target_local_macro
      )
    else
      source_index = Types.macro_index!(source_local_macro)
      target_index = Types.macro_index!(target_local_macro)

      with {:ok, chunk_pid} <-
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: source_chunk_coord,
               lease: get_any(opts, [:lease, :lease_token], nil)
             }) do
        %{storage: %Storage{} = storage} = ChunkProcess.debug_state(chunk_pid)

        {opts, source_powered?} =
          attach_physical_power_source(
            opts,
            logical_scene_id,
            source_world_macro,
            source_index,
            storage
          )

        field_source =
          opts
          |> Map.put(:source_kind, :electric)
          |> Map.put(:logical_scene_id, logical_scene_id)
          |> Map.put(:source_world_macro, source_world_macro)
          |> Map.put(:target_world_macro, target_world_macro)
          |> FieldSource.normalize()

        decay_policy = field_source.decay_policy || %{}
        source_potential = field_source.source_value
        max_ticks = conduction_max_ticks(decay_policy)
        radius = non_negative_int(get_any(decay_policy, [:field_radius], 1))

        max_frontier =
          non_negative_int(
            get_any(decay_policy, [:max_frontier], @default_conduction_max_frontier)
          )

        aabb = local_aabb_between(source_local_macro, target_local_macro, radius)
        source_key = field_source.source_key

        region_attrs = %{
          chunk_coord: source_chunk_coord,
          aabb: aabb,
          kernels: field_source.kernel_specs,
          source_points: [
            %{
              macro_index: source_index,
              field_type: :electric_potential,
              value: source_potential
            }
          ],
          max_ticks: max_ticks,
          source_points_mode: :replace,
          source_key: source_key
        }

        summary =
          %{
            logical_scene_id: logical_scene_id,
            chunk_coord: coord_map(source_chunk_coord),
            source_world_macro: coord_map(source_world_macro),
            target_world_macro: coord_map(target_world_macro),
            source_local_macro: coord_map(source_local_macro),
            target_local_macro: coord_map(target_local_macro),
            source_index: source_index,
            target_index: target_index,
            source_key: source_key,
            field_types: ["electric_potential", "ionization"],
            conduction_mode: field_source.conduction_mode || :conductive,
            source_potential: source_potential,
            radius: radius,
            max_ticks: max_ticks,
            max_frontier: max_frontier
          }
          |> maybe_put_source_summary(field_source)
          |> maybe_put_power_draw_summary(field_source)

        with :ok <-
               validate_conduction_channel(
                 chunk_pid,
                 source_key,
                 source_index,
                 target_index,
                 aabb,
                 source_potential,
                 max_frontier,
                 source_powered?,
                 field_source,
                 %{
                   logical_scene_id: logical_scene_id,
                   chunk_coord: coord_map(source_chunk_coord),
                   source_world_macro: coord_map(source_world_macro),
                   target_world_macro: coord_map(target_world_macro),
                   source_local_macro: coord_map(source_local_macro),
                   target_local_macro: coord_map(target_local_macro)
                 }
               ),
             :ok <-
               validate_power_source_policy(
                 chunk_pid,
                 source_key,
                 source_index,
                 target_index,
                 aabb,
                 source_potential,
                 max_frontier,
                 field_source,
                 %{
                   logical_scene_id: logical_scene_id,
                   chunk_coord: coord_map(source_chunk_coord),
                   source_world_macro: coord_map(source_world_macro),
                   target_world_macro: coord_map(target_world_macro),
                   source_local_macro: coord_map(source_local_macro),
                   target_local_macro: coord_map(target_local_macro)
                 }
               ),
             {:ok, field_region} <- ChunkProcess.ensure_field_region(chunk_pid, region_attrs) do
          {:ok,
           summary
           |> Map.put(:created, field_region.created?)
           |> Map.put(:region_id, field_region.region_id)
           |> Map.put(:field_region_created, field_region.created?)
           |> Map.put(:source_points_action, field_region.source_points_action)}
        end
      end
    end
  rescue
    error -> {:error, {:conduction_path_failed, error}}
  catch
    kind, reason -> {:error, {:conduction_path_failed, kind, reason}}
  end

  defp attach_physical_power_source(
         opts,
         logical_scene_id,
         source_world_macro,
         source_index,
         %Storage{} = storage
       ) do
    if explicit_power_source?(opts) do
      {opts, true}
    else
      material_id = source_material_id(storage, source_index)

      owner_ref =
        power_block_owner_ref(logical_scene_id, source_world_macro, source_index, material_id)

      opts = Map.put(opts, :owner_ref, owner_ref)

      if MaterialCatalog.power_source_material?(material_id) do
        defaults = MaterialCatalog.power_source_defaults()

        opts =
          opts
          |> Map.put_new(:source_mode, :persistent)
          |> Map.put_new(:output_mode, defaults.output_mode)
          |> Map.put_new(:source_potential, defaults.voltage)
          |> Map.put_new(
            :voltage,
            get_any(opts, [:source_potential, :potential], defaults.voltage)
          )
          |> Map.put_new(:current_limit_amps, defaults.current_limit_amps)
          |> Map.put_new(:energy_budget_joules, defaults.energy_budget_joules)

        {opts, true}
      else
        {opts, false}
      end
    end
  end

  defp explicit_power_source?(opts) do
    Enum.any?(
      explicit_power_source_keys(),
      fn key ->
        has_any_key?(opts, [key]) and not is_nil(get_any(opts, [key], nil))
      end
    )
  end

  defp explicit_power_source_keys do
    [
      :owner_ref,
      :output_mode,
      :power_output_mode,
      :source_output_mode,
      :voltage,
      :source_voltage,
      :power_voltage,
      :current_limit_amps,
      :current_limit,
      :power_current_limit_amps,
      :load_current_amps,
      :requested_current_amps,
      :current_amps,
      :power_load_current_amps,
      :frequency_hz,
      :power_frequency_hz,
      :energy_budget_joules,
      :source_energy_budget_joules
    ]
  end

  defp power_block_owner_ref(logical_scene_id, source_world_macro, source_index, material_id) do
    %{
      kind: :power_block,
      id: source_index,
      logical_scene_id: logical_scene_id,
      world_macro: coord_map(source_world_macro),
      material_id: material_id
    }
  end

  defp cross_chunk_conduction_source_key(
         logical_scene_id,
         source_world_macro,
         target_world_macro,
         opts
       ) do
    {:electric_cross_chunk, logical_scene_id, source_world_macro, target_world_macro,
     stable_cross_chunk_owner_key(get_any(opts, [:owner_ref], nil))}
  end

  defp stable_cross_chunk_owner_key(%{kind: kind, id: id}), do: {kind, id}
  defp stable_cross_chunk_owner_key(%{"kind" => kind, "id" => id}), do: {kind, id}
  defp stable_cross_chunk_owner_key(%{kind: kind, object_id: id}), do: {kind, id}
  defp stable_cross_chunk_owner_key(%{"kind" => kind, "object_id" => id}), do: {kind, id}
  defp stable_cross_chunk_owner_key(_owner_ref), do: nil

  defp source_material_id(%Storage{} = storage, source_index) do
    case Storage.normal_block_at(storage, source_index) do
      %NormalBlockData{material_id: material_id} ->
        material_id

      _other ->
        case Storage.refined_cell_at(storage, source_index) do
          %RefinedCellData{layers: [%MicroLayer{material_id: material_id} | _]} -> material_id
          _other -> nil
        end
    end
  end

  defp validate_cross_chunk_conduction_boundary(
         opts,
         logical_scene_id,
         source_world_macro,
         target_world_macro,
         source_chunk_coord,
         source_local_macro,
         target_chunk_coord,
         target_local_macro
       ) do
    case cross_chunk_boundary_handoff(
           source_chunk_coord,
           source_local_macro,
           target_chunk_coord,
           target_local_macro
         ) do
      {:ok,
       %{
         source_exit_face: source_exit_face,
         target_entry_face: target_entry_face,
         source_boundary_local_macro: source_boundary_local_macro,
         target_boundary_local_macro: target_boundary_local_macro
       }} ->
        source_index = Types.macro_index!(source_local_macro)
        target_index = Types.macro_index!(target_local_macro)
        source_boundary_index = Types.macro_index!(source_boundary_local_macro)
        target_boundary_index = Types.macro_index!(target_boundary_local_macro)

        with {:ok, source_chunk_pid} <-
               ChunkDirectory.ensure_chunk(%{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: source_chunk_coord,
                 lease: get_any(opts, [:lease, :lease_token], nil)
               }) do
          %{storage: %Storage{} = source_storage} = ChunkProcess.debug_state(source_chunk_pid)

          {opts, source_powered?} =
            attach_physical_power_source(
              opts,
              logical_scene_id,
              source_world_macro,
              source_index,
              source_storage
            )

          field_source =
            opts
            |> Map.put(
              :source_key,
              cross_chunk_conduction_source_key(
                logical_scene_id,
                source_world_macro,
                target_world_macro,
                opts
              )
            )
            |> Map.put(:source_kind, :electric)
            |> Map.put(:logical_scene_id, logical_scene_id)
            |> Map.put(:source_world_macro, source_world_macro)
            |> Map.put(:target_world_macro, target_world_macro)
            |> FieldSource.normalize()

          decay_policy = field_source.decay_policy || %{}
          source_potential = field_source.source_value
          max_ticks = conduction_max_ticks(decay_policy)
          radius = non_negative_int(get_any(decay_policy, [:field_radius], 1))

          max_frontier =
            non_negative_int(
              get_any(decay_policy, [:max_frontier], @default_conduction_max_frontier)
            )

          source_aabb =
            local_aabb_between(source_local_macro, source_boundary_local_macro, radius)

          target_aabb =
            local_aabb_between(target_boundary_local_macro, target_local_macro, radius)

          source_kernel_specs =
            conduction_kernel_specs_for_target(field_source, source_boundary_index)

          target_kernel_specs =
            conduction_kernel_specs_for_target(field_source, target_index)

          target_region_id =
            cross_chunk_target_region_id(
              logical_scene_id,
              target_chunk_coord,
              field_source.source_key
            )

          cleanup_context = %{
            source_chunk_pid: source_chunk_pid,
            source_key: field_source.source_key,
            logical_scene_id: logical_scene_id,
            target_chunk_coord: target_chunk_coord,
            target_region_id: target_region_id
          }

          base_context = %{
            logical_scene_id: logical_scene_id,
            chunk_coord: coord_map(source_chunk_coord),
            source_world_macro: coord_map(source_world_macro),
            target_world_macro: coord_map(target_world_macro),
            source_chunk_coord: coord_map(source_chunk_coord),
            target_chunk_coord: coord_map(target_chunk_coord),
            source_local_macro: coord_map(source_local_macro),
            target_local_macro: coord_map(target_local_macro),
            source_index: source_index,
            target_index: target_index,
            source_key: field_source.source_key,
            source_potential: source_potential,
            source_boundary_local_macro: coord_map(source_boundary_local_macro),
            target_boundary_local_macro: coord_map(target_boundary_local_macro),
            source_boundary_index: source_boundary_index,
            target_boundary_index: target_boundary_index,
            source_exit_face: source_exit_face,
            target_entry_face: target_entry_face,
            cross_chunk: true,
            participant_chunks: [coord_map(source_chunk_coord), coord_map(target_chunk_coord)]
          }

          source_projection = ParticipantProjection.build(source_storage)

          cond do
            not ParticipantProjection.electric_conductive_cell?(source_projection, source_index) ->
              reject_cross_chunk_conduction_boundary(
                :source_not_conductive,
                base_context,
                cleanup_context
              )

            not source_powered? ->
              reject_cross_chunk_conduction_boundary(
                :source_not_powered,
                base_context,
                cleanup_context
              )

            true ->
              with :ok <-
                     cleanup_cross_chunk_on_error(
                       validate_conduction_channel(
                         source_chunk_pid,
                         field_source.source_key,
                         source_index,
                         source_boundary_index,
                         source_aabb,
                         source_potential,
                         max_frontier,
                         source_powered?,
                         field_source,
                         Map.merge(base_context, %{
                           shard: :source,
                           target_local_macro: coord_map(source_boundary_local_macro),
                           target_index: source_boundary_index
                         })
                       ),
                       cleanup_context
                     ),
                   :ok <-
                     cleanup_cross_chunk_on_error(
                       validate_power_source_policy(
                         source_chunk_pid,
                         field_source.source_key,
                         source_index,
                         source_boundary_index,
                         source_aabb,
                         source_potential,
                         max_frontier,
                         field_source,
                         Map.merge(base_context, %{
                           shard: :source,
                           target_local_macro: coord_map(source_boundary_local_macro),
                           target_index: source_boundary_index
                         })
                       ),
                       cleanup_context
                     ),
                   {:ok, target_chunk_pid} <-
                     validate_cross_chunk_target_boundary(
                       logical_scene_id,
                       target_chunk_coord,
                       target_index,
                       target_local_macro,
                       target_boundary_index,
                       target_boundary_local_macro,
                       target_entry_face,
                       source_projection,
                       source_boundary_index,
                       source_exit_face,
                       source_potential,
                       target_aabb,
                       max_frontier,
                       field_source,
                       base_context,
                       cleanup_context
                     ) do
                source_region_attrs = %{
                  chunk_coord: source_chunk_coord,
                  aabb: source_aabb,
                  kernels: source_kernel_specs,
                  source_points: [
                    %{
                      macro_index: source_index,
                      field_type: :electric_potential,
                      value: source_potential
                    }
                  ],
                  max_ticks: max_ticks,
                  source_points_mode: :replace,
                  source_key: field_source.source_key,
                  linked_field_regions: [
                    %{
                      chunk_coord: target_chunk_coord,
                      region_id: target_region_id
                    }
                  ]
                }

                target_region_attrs = %{
                  region_id: target_region_id,
                  chunk_coord: target_chunk_coord,
                  aabb: target_aabb,
                  kernels: target_kernel_specs,
                  source_points: [
                    %{
                      macro_index: target_boundary_index,
                      field_type: :electric_potential,
                      value: source_potential
                    }
                  ],
                  max_ticks: max_ticks,
                  source_points_mode: :replace
                }

                case ChunkProcess.ensure_field_region(source_chunk_pid, source_region_attrs) do
                  {:ok, source_region} ->
                    case ChunkProcess.ensure_field_region(target_chunk_pid, target_region_attrs) do
                      {:ok, target_region} ->
                        {:ok,
                         coordinated_cross_chunk_summary(
                           logical_scene_id,
                           source_chunk_coord,
                           target_chunk_coord,
                           source_world_macro,
                           target_world_macro,
                           source_local_macro,
                           target_local_macro,
                           source_boundary_local_macro,
                           target_boundary_local_macro,
                           source_index,
                           target_index,
                           source_boundary_index,
                           target_boundary_index,
                           source_potential,
                           radius,
                           max_ticks,
                           max_frontier,
                           field_source,
                           source_region,
                           target_region
                         )}

                      {:error, reason} ->
                        _ =
                          ChunkProcess.release_field_region_source(
                            source_chunk_pid,
                            field_source.source_key,
                            :explicit
                          )

                        _ = destroy_cross_chunk_target_region(cleanup_context)
                        {:error, {:conduction_path_failed, reason}}
                    end

                  {:error, reason} ->
                    {:error, {:conduction_path_failed, reason}}
                end
              end
          end
        end

      {:misaligned, source_exit_face, target_entry_face} ->
        reject_cross_chunk_conduction_boundary(
          :cross_chunk_boundary_contacts_misaligned,
          %{
            logical_scene_id: logical_scene_id,
            source_world_macro: coord_map(source_world_macro),
            target_world_macro: coord_map(target_world_macro),
            source_chunk_coord: coord_map(source_chunk_coord),
            target_chunk_coord: coord_map(target_chunk_coord),
            source_local_macro: coord_map(source_local_macro),
            target_local_macro: coord_map(target_local_macro),
            source_exit_face: source_exit_face,
            target_entry_face: target_entry_face,
            cross_chunk: true,
            participant_chunks: [coord_map(source_chunk_coord), coord_map(target_chunk_coord)]
          }
        )

      :not_direct_boundary_neighbors ->
        {:error, {:conduction_path_failed, :cross_chunk_conduction_not_supported}}
    end
  end

  defp validate_cross_chunk_target_boundary(
         logical_scene_id,
         target_chunk_coord,
         target_index,
         target_local_macro,
         target_boundary_index,
         target_boundary_local_macro,
         target_entry_face,
         source_projection,
         source_boundary_index,
         source_exit_face,
         source_potential,
         target_aabb,
         max_frontier,
         field_source,
         base_context,
         cleanup_context
       ) do
    case ChunkDirectory.lookup_chunk_pid(logical_scene_id, target_chunk_coord) do
      {:ok, target_chunk_pid} ->
        %{storage: %Storage{} = target_storage} = ChunkProcess.debug_state(target_chunk_pid)
        target_projection = ParticipantProjection.build(target_storage)

        contacts =
          ParticipantProjection.electric_contact_transfer(
            source_projection,
            source_boundary_index,
            :source,
            MapSet.new(),
            source_exit_face,
            target_projection,
            target_boundary_index,
            target_entry_face
          )

        context = Map.put(base_context, :boundary_contacts_count, MapSet.size(contacts))
        cleanup_context = Map.put(cleanup_context, :target_chunk_pid, target_chunk_pid)

        conductive_boundary_mode? = field_source.conduction_mode != :discharge

        cond do
          conductive_boundary_mode? and
              not ParticipantProjection.electric_conductive_cell?(
                target_projection,
                target_index
              ) ->
            reject_cross_chunk_conduction_boundary(
              :target_not_conductive,
              context,
              cleanup_context
            )

          conductive_boundary_mode? and MapSet.size(contacts) == 0 ->
            reject_cross_chunk_conduction_boundary(
              :cross_chunk_boundary_contacts_misaligned,
              context,
              cleanup_context
            )

          true ->
            case electric_channel_path(
                   field_source,
                   target_storage,
                   target_boundary_index,
                   target_index,
                   target_aabb,
                   source_potential,
                   max_frontier
                 ) do
              {:ok, _path} ->
                {:ok, target_chunk_pid}

              {:error, reason} ->
                reject_cross_chunk_conduction_boundary(
                  reason,
                  Map.merge(context, %{
                    shard: :target,
                    source_local_macro: coord_map(target_boundary_local_macro),
                    source_index: target_boundary_index,
                    target_local_macro: coord_map(target_local_macro),
                    target_index: target_index
                  }),
                  cleanup_context
                )
            end
        end

      :not_started ->
        reject_cross_chunk_conduction_boundary(
          :target_not_conductive,
          Map.put(base_context, :boundary_contacts_count, 0),
          cleanup_context
        )
    end
  end

  defp cross_chunk_boundary_handoff(
         {sx, sy, sz},
         {source_x, source_y, source_z},
         {tx, ty, tz},
         {target_x, target_y, target_z}
       ) do
    max_local = Types.chunk_size_in_macro() - 1

    case {tx - sx, ty - sy, tz - sz} do
      {1, 0, 0} ->
        aligned_cross_chunk_handoff(
          source_x == max_local and target_x == 0 and source_y == target_y and
            source_z == target_z,
          :x_pos,
          :x_neg,
          {max_local, source_y, source_z},
          {0, target_y, target_z}
        )

      {-1, 0, 0} ->
        aligned_cross_chunk_handoff(
          source_x == 0 and target_x == max_local and source_y == target_y and
            source_z == target_z,
          :x_neg,
          :x_pos,
          {0, source_y, source_z},
          {max_local, target_y, target_z}
        )

      {0, 1, 0} ->
        aligned_cross_chunk_handoff(
          source_y == max_local and target_y == 0 and source_x == target_x and
            source_z == target_z,
          :y_pos,
          :y_neg,
          {source_x, max_local, source_z},
          {target_x, 0, target_z}
        )

      {0, -1, 0} ->
        aligned_cross_chunk_handoff(
          source_y == 0 and target_y == max_local and source_x == target_x and
            source_z == target_z,
          :y_neg,
          :y_pos,
          {source_x, 0, source_z},
          {target_x, max_local, target_z}
        )

      {0, 0, 1} ->
        aligned_cross_chunk_handoff(
          source_z == max_local and target_z == 0 and source_x == target_x and
            source_y == target_y,
          :z_pos,
          :z_neg,
          {source_x, source_y, max_local},
          {target_x, target_y, 0}
        )

      {0, 0, -1} ->
        aligned_cross_chunk_handoff(
          source_z == 0 and target_z == max_local and source_x == target_x and
            source_y == target_y,
          :z_neg,
          :z_pos,
          {source_x, source_y, 0},
          {target_x, target_y, max_local}
        )

      _other ->
        :not_direct_boundary_neighbors
    end
  end

  defp aligned_cross_chunk_handoff(
         true,
         source_exit_face,
         target_entry_face,
         source_boundary_local_macro,
         target_boundary_local_macro
       ) do
    {:ok,
     %{
       source_exit_face: source_exit_face,
       target_entry_face: target_entry_face,
       source_boundary_local_macro: source_boundary_local_macro,
       target_boundary_local_macro: target_boundary_local_macro
     }}
  end

  defp aligned_cross_chunk_handoff(
         false,
         source_exit_face,
         target_entry_face,
         _source_boundary_local_macro,
         _target_boundary_local_macro
       ) do
    {:misaligned, source_exit_face, target_entry_face}
  end

  defp reject_cross_chunk_conduction_boundary(reason, observe_context, cleanup_context \\ nil) do
    public_reason = normalize_conduction_reject_reason(reason)

    observe_context
    |> Map.put_new(:boundary_contacts_count, 0)
    |> Map.merge(%{
      raw_reason: reason,
      reject_reason: detailed_conduction_reject_reason(reason),
      public_reason: public_reason
    })
    |> emit_conduction_path_rejected()

    _ = cleanup_cross_chunk_conduction(cleanup_context, public_reason)
    {:error, {:conduction_path_failed, public_reason}}
  end

  defp cleanup_cross_chunk_on_error(:ok, _cleanup_context), do: :ok

  defp cleanup_cross_chunk_on_error(
         {:error, {:conduction_path_failed, public_reason}} = error,
         cleanup_context
       ) do
    _ = cleanup_cross_chunk_conduction(cleanup_context, public_reason)
    error
  end

  defp cleanup_cross_chunk_on_error(error, cleanup_context) do
    _ = cleanup_cross_chunk_conduction(cleanup_context, :explicit)
    error
  end

  defp cleanup_cross_chunk_conduction(nil, _destroy_reason), do: :ok

  defp cleanup_cross_chunk_conduction(cleanup_context, destroy_reason)
       when is_map(cleanup_context) do
    case {Map.get(cleanup_context, :source_chunk_pid), Map.get(cleanup_context, :source_key)} do
      {source_chunk_pid, source_key} when is_pid(source_chunk_pid) and not is_nil(source_key) ->
        _ = ChunkProcess.release_field_region_source(source_chunk_pid, source_key, destroy_reason)

      _other ->
        :ok
    end

    destroy_cross_chunk_target_region(cleanup_context)
  end

  defp destroy_cross_chunk_target_region(%{target_region_id: target_region_id} = cleanup_context)
       when is_integer(target_region_id) do
    case cross_chunk_target_pid(cleanup_context) do
      {:ok, target_chunk_pid} ->
        _ = ChunkProcess.destroy_field_region(target_chunk_pid, target_region_id)
        :ok

      :not_started ->
        :ok
    end
  end

  defp destroy_cross_chunk_target_region(_cleanup_context), do: :ok

  defp cross_chunk_target_pid(%{target_chunk_pid: target_chunk_pid})
       when is_pid(target_chunk_pid) do
    {:ok, target_chunk_pid}
  end

  defp cross_chunk_target_pid(%{
         logical_scene_id: logical_scene_id,
         target_chunk_coord: target_chunk_coord
       }) do
    ChunkDirectory.lookup_chunk_pid(logical_scene_id, target_chunk_coord)
  end

  defp cross_chunk_target_pid(_cleanup_context), do: :not_started

  defp validate_conduction_channel(
         chunk_pid,
         source_key,
         source_index,
         target_index,
         aabb,
         source_potential,
         max_frontier,
         source_powered?,
         field_source,
         observe_context
       ) do
    %{storage: %Storage{} = storage} = ChunkProcess.debug_state(chunk_pid)

    case electric_channel_path(
           field_source,
           storage,
           source_index,
           target_index,
           aabb,
           source_potential,
           max_frontier
         ) do
      {:ok, _path} ->
        if source_powered? do
          :ok
        else
          reject_conduction_channel(
            chunk_pid,
            source_key,
            source_index,
            target_index,
            aabb,
            source_potential,
            max_frontier,
            :source_not_powered,
            observe_context
          )
        end

      {:error, reason} ->
        reject_conduction_channel(
          chunk_pid,
          source_key,
          source_index,
          target_index,
          aabb,
          source_potential,
          max_frontier,
          reason,
          observe_context
        )
    end
  end

  defp electric_channel_path(
         %FieldSource{conduction_mode: :discharge},
         %Storage{} = storage,
         source_index,
         target_index,
         aabb,
         source_potential,
         max_frontier
       ) do
    ElectricDischargeKernel.discharge_path(
      storage,
      source_index,
      target_index,
      aabb,
      source_potential,
      %{
        max_frontier: max_frontier
      }
    )
  end

  defp electric_channel_path(
         _field_source,
         %Storage{} = storage,
         source_index,
         target_index,
         aabb,
         source_potential,
         max_frontier
       ) do
    ConductionPathKernel.channel_path(
      storage,
      source_index,
      target_index,
      aabb,
      source_potential,
      %{
        max_frontier: max_frontier
      }
    )
  end

  defp validate_power_source_policy(
         chunk_pid,
         source_key,
         source_index,
         target_index,
         aabb,
         source_potential,
         max_frontier,
         %FieldSource{power_source: %PowerSource{} = power_source},
         observe_context
       ) do
    cond do
      PowerSource.over_current?(power_source) ->
        reject_conduction_channel(
          chunk_pid,
          source_key,
          source_index,
          target_index,
          aabb,
          source_potential,
          max_frontier,
          :current_limit_exceeded,
          Map.merge(observe_context, power_observe_fields(power_source))
        )

      energy_budget_exhausted?(power_source) ->
        reject_conduction_channel(
          chunk_pid,
          source_key,
          source_index,
          target_index,
          aabb,
          source_potential,
          max_frontier,
          :energy_budget_exhausted,
          Map.merge(observe_context, power_observe_fields(power_source))
        )

      true ->
        :ok
    end
  end

  defp validate_power_source_policy(
         _chunk_pid,
         _source_key,
         _source_index,
         _target_index,
         _aabb,
         _source_potential,
         _max_frontier,
         _field_source,
         _observe_context
       ),
       do: :ok

  defp energy_budget_exhausted?(%PowerSource{energy_budget_joules: budget} = power_source)
       when is_number(budget) do
    PowerSource.estimated_tick_energy_joules(power_source, @conduction_power_policy_tick_ms) >
      budget
  end

  defp energy_budget_exhausted?(%PowerSource{}), do: false

  defp power_observe_fields(%PowerSource{} = power_source) do
    %{
      output_mode: power_source.output_mode,
      voltage: power_source.voltage,
      current_limit_amps: power_source.current_limit_amps,
      frequency_hz: power_source.frequency_hz,
      load_current_amps: PowerSource.effective_load_current_amps(power_source),
      energy_budget_joules: power_source.energy_budget_joules,
      estimated_tick_energy_joules:
        PowerSource.estimated_tick_energy_joules(power_source, @conduction_power_policy_tick_ms)
    }
  end

  defp reject_conduction_channel(
         chunk_pid,
         source_key,
         source_index,
         target_index,
         aabb,
         source_potential,
         max_frontier,
         reason,
         observe_context
       ) do
    public_reason = normalize_conduction_reject_reason(reason)

    emit_conduction_path_rejected(
      Map.merge(observe_context, %{
        source_key: source_key,
        source_index: source_index,
        target_index: target_index,
        aabb: aabb,
        source_potential: source_potential,
        max_frontier: max_frontier,
        raw_reason: reason,
        reject_reason: detailed_conduction_reject_reason(reason),
        public_reason: public_reason
      })
    )

    _ = ChunkProcess.release_field_region_source(chunk_pid, source_key, :explicit)
    {:error, {:conduction_path_failed, public_reason}}
  end

  defp normalize_conduction_reject_reason(:unreachable), do: :no_conductive_path
  defp normalize_conduction_reject_reason(:empty_queue), do: :no_conductive_path
  defp normalize_conduction_reject_reason(:frontier_exhausted), do: :no_conductive_path
  defp normalize_conduction_reject_reason(:no_discharge_path), do: :no_discharge_path

  defp normalize_conduction_reject_reason(:cross_chunk_boundary_contacts_misaligned),
    do: :no_conductive_path

  defp normalize_conduction_reject_reason(reason), do: reason

  defp detailed_conduction_reject_reason(:frontier_exhausted), do: :search_budget_exhausted
  defp detailed_conduction_reject_reason(reason), do: normalize_conduction_reject_reason(reason)

  defp emit_conduction_path_rejected(fields) do
    CliObserve.emit("voxel_conduction_path_rejected", fn -> fields end)
  end

  @doc """
  Builds the deterministic field plan from authoritative voxel storage without
  touching the process registry.  This is the pure, testable half of the
  runtime.
  """
  @spec build_temperature_anomaly(keyword() | map()) :: {:ok, map()} | {:ignore, map()}
  def build_temperature_anomaly(opts \\ []) do
    opts = opts_map(opts)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    baseline_temperature = TemperatureField.env_temperature() * 1.0
    storage = storage!(get_any(opts, [:storage], nil))
    world_macro = world_macro_coord(opts)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    source_index = Types.macro_index!(local_macro)
    target_temperature = voxel_temperature(storage, source_index)
    anomaly_delta = target_temperature - baseline_temperature
    field_source = get_any(opts, [:field_source], nil)

    summary =
      base_summary(
        logical_scene_id,
        world_macro,
        chunk_coord,
        local_macro,
        baseline_temperature,
        target_temperature,
        anomaly_delta
      )
      |> maybe_put_source_summary(field_source)

    if abs(anomaly_delta) < @temperature_threshold do
      {:ignore,
       summary
       |> Map.put(:created, false)
       |> Map.put(:reason, :temperature_within_environment_threshold)}
    else
      max_ticks = anomaly_max_ticks(opts, field_source)
      radius = anomaly_radius(opts, field_source)
      aabb = local_aabb_around(local_macro, radius)
      kernels = anomaly_kernel_specs(field_source)
      source_key = anomaly_source_key(field_source, source_index)

      region_attrs =
        %{
          chunk_coord: chunk_coord,
          aabb: aabb,
          kernels: kernels,
          source_points: [
            %{
              macro_index: source_index,
              field_type: :temperature,
              source_mode: temperature_source_mode(field_source),
              value: target_temperature
            }
          ],
          max_ticks: max_ticks
        }
        |> maybe_put(:source_points_mode, temperature_source_points_mode(field_source))

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         local_macro: local_macro,
         source_index: source_index,
         source_key: source_key,
         region_attrs: region_attrs,
         summary:
           summary
           |> Map.put(:created, true)
           |> Map.put(:field_types, ["temperature"])
           |> Map.put(:radius, radius)
           |> Map.put(:max_ticks, max_ticks)
       }}
    end
  end

  @doc "Returns the default heat-skill target temperature in Celsius."
  @spec default_target_temperature_celsius() :: float()
  def default_target_temperature_celsius, do: @default_target_temperature_celsius

  @doc "Returns the ambient temperature restored by the formal set-temperature path."
  @spec ambient_temperature_celsius() :: float()
  def ambient_temperature_celsius, do: TemperatureField.env_temperature() * 1.0

  @doc "Converts a Celsius value into the storage catalog Q16.16 raw value."
  @spec celsius_to_raw(number()) :: integer()
  def celsius_to_raw(value) when is_integer(value) or is_float(value) do
    round(value * @fixed32_scale)
  end

  @doc "Converts a storage catalog Q16.16 raw value into Celsius."
  @spec raw_to_celsius(integer()) :: float()
  def raw_to_celsius(value) when is_integer(value), do: value / @fixed32_scale

  defp physical_temperature_kernel_opts do
    %{
      diffusion_time_scale: @temperature_diffusion_time_scale,
      ambient_loss_per_second: @temperature_ambient_loss_per_second,
      cell_size_meters: @temperature_cell_size_meters
    }
  end

  defp anomaly_kernel_specs(%FieldSource{} = field_source), do: field_source.kernel_specs
  defp anomaly_kernel_specs(_field_source), do: [default_temperature_kernel_spec()]

  defp anomaly_source_key(%FieldSource{} = field_source, _source_index),
    do: field_source.source_key

  defp anomaly_source_key(_field_source, source_index), do: {:temperature, source_index}

  defp temperature_source_mode(%FieldSource{} = field_source), do: field_source.source_mode
  defp temperature_source_mode(_field_source), do: :impulse

  defp temperature_source_points_mode(%FieldSource{}), do: :replace
  defp temperature_source_points_mode(_field_source), do: nil

  defp anomaly_max_ticks(opts, %FieldSource{} = field_source) do
    non_negative_int(
      get_any(
        opts,
        [:max_ticks],
        get_in(field_source.decay_policy || %{}, [:max_ticks]) || @default_max_ticks
      )
    )
  end

  defp anomaly_max_ticks(opts, _field_source) do
    non_negative_int(get_any(opts, [:max_ticks], @default_max_ticks))
  end

  defp anomaly_radius(opts, %FieldSource{} = field_source) do
    non_negative_int(
      get_any(
        opts,
        [:radius],
        get_in(field_source.decay_policy || %{}, [:field_radius]) || @default_radius
      )
    )
  end

  defp anomaly_radius(opts, _field_source) do
    non_negative_int(get_any(opts, [:radius], @default_radius))
  end

  defp default_temperature_kernel_spec do
    %{
      id: :temperature_diffusion,
      module: TemperatureDiffusionKernel,
      opts: physical_temperature_kernel_opts()
    }
  end

  defp auto_circuit_kernel_spec(opts) do
    %{
      id: :circuit_current,
      module: CircuitCurrentKernel,
      opts: %{
        current_limit_amps:
          non_negative_float(
            get_any(
              opts,
              [:current_limit_amps],
              MaterialCatalog.power_source_defaults().current_limit_amps
            )
          )
      }
    }
  end

  defp auto_circuit_power_source(opts) do
    defaults = MaterialCatalog.power_source_defaults()

    PowerSource.normalize(%{
      output_mode: :dc,
      voltage:
        get_any(
          opts,
          [:voltage, :source_voltage, :source_potential],
          defaults.voltage
        ),
      current_limit_amps:
        get_any(
          opts,
          [:current_limit_amps],
          defaults.current_limit_amps
        )
    })
  end

  defp auto_circuit_max_ticks(opts) do
    case get_any(opts, [:ttl_ticks, :ttl], nil) do
      nil -> nil
      value -> non_negative_int(value)
    end
  end

  defp auto_circuit_topology_summary(
         projection,
         aabb,
         chunk_coord,
         source_points,
         kernel_spec
       ) do
    region =
      FieldRegion.new(%{
        region_id: 0,
        chunk_coord: chunk_coord,
        aabb: aabb,
        kernels: [kernel_spec],
        source_points: source_points
      })

    active_components = CircuitComponentAnalysis.active_circuit_components(region, projection)

    %{
      closed_circuit_count: length(active_components)
    }
  end

  defp auto_circuit_source_points(projection, aabb, opts) do
    voltage =
      non_negative_float(
        get_any(
          opts,
          [:voltage, :source_voltage, :source_potential],
          MaterialCatalog.power_source_defaults().voltage
        )
      )

    aabb
    |> aabb_macro_indices()
    |> Enum.filter(&ParticipantProjection.electric_role?(projection, &1, :source))
    |> Enum.map(fn macro_index ->
      %{
        macro_index: macro_index,
        field_type: :electric_potential,
        source_mode: :persistent,
        value: voltage
      }
    end)
  end

  defp auto_circuit_role_count(projection, aabb, role) do
    aabb
    |> aabb_macro_indices()
    |> Enum.count(&ParticipantProjection.electric_role?(projection, &1, role))
  end

  defp full_chunk_aabb, do: {{0, 0, 0}, {15, 15, 15}}

  defp aabb_macro_indices({{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z do
      Types.macro_index!({x, y, z})
    end
  end

  defp conduction_max_ticks(decay_policy) do
    ttl_ticks = Map.get(decay_policy, :ttl_ticks) || Map.get(decay_policy, "ttl_ticks")
    max_ticks = Map.get(decay_policy, :max_ticks) || Map.get(decay_policy, "max_ticks")
    non_negative_int(ttl_ticks || max_ticks || @default_max_ticks)
  end

  defp base_summary(
         logical_scene_id,
         world_macro,
         chunk_coord,
         local_macro,
         baseline_temperature,
         target_temperature,
         anomaly_delta
       ) do
    %{
      created: true,
      logical_scene_id: logical_scene_id,
      world_macro: coord_map(world_macro),
      chunk_coord: coord_map(chunk_coord),
      local_macro: coord_map(local_macro),
      baseline_temperature: baseline_temperature,
      target_temperature: target_temperature,
      anomaly_delta: anomaly_delta
    }
  end

  defp world_macro_coord(opts) do
    cond do
      has_any_key?(opts, [:world_macro]) ->
        Types.normalize_world_micro_coord!(get_any(opts, [:world_macro], nil))

      has_axis_keys?(opts, [:x, :y, :z]) ->
        Types.normalize_world_micro_coord!(
          {get_any(opts, [:x], 0), get_any(opts, [:y], 0), get_any(opts, [:z], 0)}
        )

      has_any_key?(opts, [:chunk_coord]) ->
        world_macro_from_chunk(get_any(opts, [:chunk_coord], {0, 0, 0}))

      true ->
        {0, 0, 0}
    end
  end

  defp source_world_macro_coord(opts) do
    cond do
      has_any_key?(opts, [:source_world_macro, :source_macro, :from_world_macro]) ->
        Types.normalize_world_micro_coord!(
          get_any(opts, [:source_world_macro, :source_macro, :from_world_macro], nil)
        )

      has_axis_keys?(opts, [:source_x, :source_y, :source_z]) ->
        Types.normalize_world_micro_coord!(
          {get_any(opts, [:source_x], 0), get_any(opts, [:source_y], 0),
           get_any(opts, [:source_z], 0)}
        )

      true ->
        world_macro_coord(opts)
    end
  end

  defp target_world_macro_coord(opts) do
    cond do
      has_any_key?(opts, [:target_world_macro, :target_macro, :to_world_macro]) ->
        Types.normalize_world_micro_coord!(
          get_any(opts, [:target_world_macro, :target_macro, :to_world_macro], nil)
        )

      has_axis_keys?(opts, [:target_x, :target_y, :target_z]) ->
        Types.normalize_world_micro_coord!(
          {get_any(opts, [:target_x], 0), get_any(opts, [:target_y], 0),
           get_any(opts, [:target_z], 0)}
        )

      true ->
        world_macro_coord(opts)
    end
  end

  defp world_macro_from_chunk(chunk_coord) do
    {cx, cy, cz} = Types.normalize_chunk_coord!(chunk_coord)
    size = Types.chunk_size_in_macro()
    centre = div(size, 2) - 1
    {cx * size + centre, cy * size + centre, cz * size + centre}
  end

  defp storage!(%Storage{} = storage), do: Storage.normalize!(storage)

  defp storage!(nil) do
    raise ArgumentError,
          "build_temperature_anomaly requires :storage; anomaly detection must read voxel truth"
  end

  defp storage!(storage) when is_map(storage), do: Storage.normalize!(storage)

  defp voxel_temperature(%Storage{} = storage, source_index) do
    storage
    |> Storage.effective_attribute_at(source_index, "temperature")
    |> raw_to_celsius()
  end

  defp heat_request(opts) do
    cond do
      has_any_key?(opts, [:target_temperature, :target_temperature_celsius]) ->
        {:target_temperature,
         temperature_float(
           get_any(opts, [:target_temperature, :target_temperature_celsius], nil),
           @default_target_temperature_celsius
         )}

      has_any_key?(opts, [:heat_energy_joules]) ->
        {:heat_energy_joules, non_negative_float(get_any(opts, [:heat_energy_joules], 0.0))}

      true ->
        {:target_temperature, @default_target_temperature_celsius}
    end
  end

  defp set_temperature_target(opts) do
    if restore_ambient?(opts) do
      ambient_temperature_celsius()
    else
      temperature_float(
        get_any(opts, [:target_temperature, :target_temperature_celsius], nil),
        @default_target_temperature_celsius
      )
    end
  end

  defp set_temperature_source_mode(opts) do
    case get_any(opts, [:source_mode], :impulse) do
      value when value in [:impulse, :persistent] ->
        value

      value when is_binary(value) ->
        case String.trim(String.downcase(value)) do
          "persistent" -> :persistent
          "impulse" -> :impulse
          _other -> :impulse
        end

      _other ->
        :impulse
    end
  end

  defp write_temperature_request(
         chunk_pid,
         local_macro,
         {:target_temperature, target_temperature}
       ) do
    ChunkProcess.write_temperature_attribute(chunk_pid, %{
      macro: local_macro,
      target_temperature: target_temperature
    })
  end

  defp write_temperature_request(
         chunk_pid,
         local_macro,
         {:heat_energy_joules, heat_energy_joules}
       ) do
    ChunkProcess.add_heat_energy_attribute(chunk_pid, %{
      macro: local_macro,
      heat_energy_joules: heat_energy_joules
    })
  end

  defp summarize_attribute_write(summary) when is_map(summary) do
    Map.take(summary, [
      :changed?,
      :macro_index,
      :heat_energy_joules,
      :density,
      :specific_heat_capacity,
      :heat_capacity_j_per_k,
      :previous_temperature,
      :temperature_delta,
      :target_temperature,
      :target_temperature_raw,
      :attribute_delta_raw,
      :effective_temperature,
      :effective_temperature_raw,
      :chunk_version
    ])
  end

  defp maybe_put_source_summary(summary, %FieldSource{} = field_source) do
    Map.put(summary, :source, FieldSource.to_summary(field_source))
  end

  defp maybe_put_source_summary(summary, _field_source), do: summary

  defp maybe_put_power_draw_summary(summary, %FieldSource{power_source: %PowerSource{} = source}) do
    Map.put(summary, :power_draw, power_observe_fields(source))
  end

  defp maybe_put_power_draw_summary(summary, _field_source), do: summary

  defp conduction_kernel_specs_for_target(%FieldSource{kernel_specs: kernel_specs}, target_index) do
    Enum.map(kernel_specs, fn
      %{id: :conduction_path, opts: opts} = kernel_spec when is_map(opts) ->
        %{kernel_spec | opts: Map.put(opts, :target_macro_index, target_index)}

      %{id: :conduction_path} = kernel_spec ->
        Map.put(kernel_spec, :opts, %{target_macro_index: target_index})

      %{id: :electric_discharge, opts: opts} = kernel_spec when is_map(opts) ->
        %{kernel_spec | opts: Map.put(opts, :target_macro_index, target_index)}

      %{id: :electric_discharge} = kernel_spec ->
        Map.put(kernel_spec, :opts, %{target_macro_index: target_index})

      kernel_spec ->
        kernel_spec
    end)
  end

  defp cross_chunk_target_region_id(logical_scene_id, target_chunk_coord, source_key) do
    {:ok, hash} =
      {:ok,
       :crypto.hash(
         :sha256,
         :erlang.term_to_binary(
           {:cross_chunk_conduction_target_region, logical_scene_id, target_chunk_coord,
            source_key}
         )
       )}

    hash
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
    |> Kernel.+(1)
  end

  defp coordinated_cross_chunk_summary(
         logical_scene_id,
         source_chunk_coord,
         target_chunk_coord,
         source_world_macro,
         target_world_macro,
         source_local_macro,
         target_local_macro,
         source_boundary_local_macro,
         target_boundary_local_macro,
         source_index,
         target_index,
         source_boundary_index,
         target_boundary_index,
         source_potential,
         radius,
         max_ticks,
         max_frontier,
         %FieldSource{} = field_source,
         source_region,
         target_region
       ) do
    field_region_created = source_region.created? or target_region.created?

    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: coord_map(source_chunk_coord),
      source_world_macro: coord_map(source_world_macro),
      target_world_macro: coord_map(target_world_macro),
      source_local_macro: coord_map(source_local_macro),
      target_local_macro: coord_map(target_local_macro),
      source_boundary_local_macro: coord_map(source_boundary_local_macro),
      target_boundary_local_macro: coord_map(target_boundary_local_macro),
      source_index: source_index,
      target_index: target_index,
      source_boundary_index: source_boundary_index,
      target_boundary_index: target_boundary_index,
      source_key: field_source.source_key,
      field_types: ["electric_potential", "ionization"],
      conduction_mode: field_source.conduction_mode || :conductive,
      source_potential: source_potential,
      radius: radius,
      max_ticks: max_ticks,
      max_frontier: max_frontier,
      cross_chunk: true,
      participant_chunks: [coord_map(source_chunk_coord), coord_map(target_chunk_coord)],
      source_shard: shard_summary(source_region, source_chunk_coord),
      target_shard: shard_summary(target_region, target_chunk_coord)
    }
    |> maybe_put_source_summary(field_source)
    |> maybe_put_power_draw_summary(field_source)
    |> Map.put(:created, field_region_created)
    |> Map.put(:region_id, source_region.region_id)
    |> Map.put(:field_region_created, field_region_created)
    |> Map.put(:source_points_action, source_region.source_points_action)
  end

  defp shard_summary(region_result, chunk_coord) do
    region_result
    |> Map.take([
      :region_id,
      :source_key,
      :region_action,
      :source_points_action,
      :source_points_count,
      :source_points_rejection_reason
    ])
    |> Map.put(:chunk_coord, coord_map(chunk_coord))
    |> Map.put(:created, Map.get(region_result, :created?, false))
    |> Map.put(:field_region_created, Map.get(region_result, :created?, false))
  end

  defp maybe_cleanup_ignored_field_region(
         chunk_pid,
         %FieldSource{} = field_source,
         summary,
         opts
       ) do
    if cleanup_on_ignore?(opts) do
      case ChunkProcess.release_field_region_source(
             chunk_pid,
             field_source.source_key,
             Map.get(summary, :reason, :explicit)
           ) do
        {:ok, cleanup_summary} -> cleanup_summary
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  defp maybe_cleanup_ignored_field_region(_chunk_pid, _field_source, _summary, _opts), do: nil

  defp drop_heat_request_keys(opts) do
    Map.drop(opts, [
      :heat_energy_joules,
      "heat_energy_joules",
      :heat_joules,
      "heat_joules",
      :energy_joules,
      "energy_joules"
    ])
  end

  defp local_aabb_around({x, y, z}, radius) do
    {{clamp_macro(x - radius), clamp_macro(y - radius), clamp_macro(z - radius)},
     {clamp_macro(x + radius), clamp_macro(y + radius), clamp_macro(z + radius)}}
  end

  defp local_aabb_between({sx, sy, sz}, {tx, ty, tz}, radius) do
    {{clamp_macro(min(sx, tx) - radius), clamp_macro(min(sy, ty) - radius),
      clamp_macro(min(sz, tz) - radius)},
     {clamp_macro(max(sx, tx) + radius), clamp_macro(max(sy, ty) + radius),
      clamp_macro(max(sz, tz) + radius)}}
  end

  defp clamp_macro(value) when value < 0, do: 0
  defp clamp_macro(value) when value > 15, do: 15
  defp clamp_macro(value), do: value

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_any(map, keys, default) do
    Enum.find_value(keys, fn key ->
      cond do
        Map.has_key?(map, key) -> {:found, Map.fetch!(map, key)}
        Map.has_key?(map, Atom.to_string(key)) -> {:found, Map.fetch!(map, Atom.to_string(key))}
        true -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
  end

  defp has_any_key?(map, keys) do
    Enum.any?(keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
    end)
  end

  defp has_axis_keys?(map, keys) do
    Enum.all?(keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
    end)
  end

  defp coord_map({x, y, z}), do: %{x: x, y: y, z: z}

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0
    end
  end

  defp non_negative_int(_value), do: 0

  defp non_negative_float(value) when is_integer(value) and value >= 0, do: value * 1.0
  defp non_negative_float(value) when is_float(value) and value >= 0, do: value

  defp non_negative_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0.0
    end
  end

  defp non_negative_float(_value), do: 0.0

  defp temperature_float(value, _fallback) when is_integer(value), do: value * 1.0
  defp temperature_float(value, _fallback) when is_float(value), do: value

  defp temperature_float(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> fallback
    end
  end

  defp temperature_float(_value, fallback), do: fallback

  defp restore_ambient?(opts) do
    case get_any(opts, [:restore_ambient], false) do
      true -> true
      1 -> true
      "1" -> true
      "true" -> true
      "TRUE" -> true
      "yes" -> true
      "YES" -> true
      _other -> false
    end
  end

  defp cleanup_on_ignore?(opts) do
    case get_any(opts, [:cleanup_on_ignore], false) do
      true -> true
      1 -> true
      "1" -> true
      "true" -> true
      "TRUE" -> true
      "yes" -> true
      "YES" -> true
      _other -> false
    end
  end
end
