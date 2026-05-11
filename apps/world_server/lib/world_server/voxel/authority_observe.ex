defmodule WorldServer.Voxel.AuthorityObserve do
  @moduledoc """
  Non-GUI acceptance runner for world-side server-authoritative voxel state.

  The runner exercises the real `WorldServer.Voxel.MapLedger` and
  `DataService.Voxel.WriteTokenStore` boundary for one `logical_scene_id`. It is
  intentionally CLI-shaped: every important state transition is emitted through
  `WorldServer.CliObserve`, and the returned summary is small enough for Mix
  tasks and tests to inspect directly.
  """

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.CliObserve
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.MigrationPlan

  @default_observe_dir ".demo/observe"
  @default_region_id 10
  @default_source_scene_instance_ref 1_000
  @default_target_scene_instance_ref 2_000
  @default_chunk_coord {1, 0, 0}
  @lease_ttl_ms 60_000

  @doc """
  Runs the end-to-end authority acceptance scenario.

  Options:

    * `:logical_scene_id` - logical scene to exercise, defaults to `1`.
    * `:observe_dir` - directory for the default observe log.
    * `:observe_log` - explicit observe log path.
    * `:ledger` - optional `MapLedger` process for tests.
    * `:write_token_store` - optional `WriteTokenStore` process for tests.
    * `:scene_invalidator` - optional 1-arity function passed through to a
      caller-managed `MapLedger`. Tests and the e2e CLI can use this to wire a
      real `SceneServer.Voxel.ChunkDirectory.invalidate_chunk/2` call. Ignored
      when the runner manages its own `MapLedger` process.
    * `:scene_chunk_directory` - optional `SceneServer.Voxel.ChunkDirectory`
      pid/name. When supplied without `:ledger`, the runner builds a default
      `:scene_invalidator` that calls
      `SceneServer.Voxel.ChunkDirectory.invalidate_chunk/2` against it.

  When no log path is configured, the runner writes to
  `.demo/observe/world-voxel-authority-<logical_scene_id>.log`.
  """
  def run(opts \\ []) when is_list(opts) do
    observe_log = resolve_observe_log(opts)

    with_observe_log(observe_log, fn ->
      with_runtime(opts, fn ledger, token_store ->
        result = do_run(ledger, token_store, opts, observe_log)
        CliObserve.flush()
        result
      end)
    end)
  end

  @doc """
  Builds a 1-arity scene invalidator that forwards to
  `SceneServer.Voxel.ChunkDirectory.invalidate_chunk/2`.

  The returned function accepts `%{logical_scene_id, chunk_coord, reason}` and
  is suitable to pass as the `:scene_invalidator` option to `MapLedger`. The
  helper does not require `scene_server` at compile time; if the directory
  module is unavailable at runtime it returns `{:error, :scene_directory_unavailable}`.
  """
  def scene_directory_invalidator(directory) when not is_nil(directory) do
    fn attrs ->
      directory_module = Module.concat(["SceneServer", "Voxel", "ChunkDirectory"])

      if Code.ensure_loaded?(directory_module) and
           function_exported?(directory_module, :invalidate_chunk, 2) do
        directory_module.invalidate_chunk(directory, attrs)
      else
        {:error, :scene_directory_unavailable}
      end
    end
  end

  @doc "Returns the default observe log path for a logical scene id."
  def default_observe_log(logical_scene_id, observe_dir \\ @default_observe_dir) do
    Path.expand(Path.join(observe_dir, "world-voxel-authority-#{logical_scene_id}.log"))
  end

  defp do_run(ledger, token_store, opts, observe_log) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    region_id = Keyword.get(opts, :region_id, @default_region_id)
    chunk_coord = Keyword.get(opts, :chunk_coord, @default_chunk_coord)
    source_ref = Keyword.get(opts, :source_scene_instance_ref, @default_source_scene_instance_ref)
    target_ref = Keyword.get(opts, :target_scene_instance_ref, @default_target_scene_instance_ref)
    future_ms = System.system_time(:millisecond) + @lease_ttl_ms
    migration_id = "authority-#{logical_scene_id}-region-#{region_id}"

    emit_step("voxel_authority_acceptance_started", %{
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      chunk_coord: coord_list(chunk_coord),
      observe_log: observe_log
    })

    with {:ok, _assignment} <-
           MapLedger.put_region(ledger, %{
             logical_scene_id: logical_scene_id,
             region_id: region_id,
             bounds_chunk_min: {0, 0, 0},
             bounds_chunk_max: {4, 4, 4},
             owner_scene_instance_ref: source_ref,
             owner_epoch: 0,
             assigned_scene_node: node()
           }),
         {:ok, lease_v1} <-
           MapLedger.issue_lease(ledger, region_id, source_ref,
             lease_id: 100,
             owner_epoch: 1,
             expires_at_ms: future_ms,
             token_version: 1
           ),
         {:ok, token_v1} <- fetch_current_token(token_store, logical_scene_id, region_id),
         {:ok, route_v1} <-
           route_and_observe(ledger, logical_scene_id, chunk_coord, "before_migration"),
         {:ok, current_before} <-
           validate_expected(
             :current_before_migration,
             validate_both(ledger, token_store, write_attrs(lease_v1, chunk_coord)),
             %{world: :ok, data_service: :ok}
           ),
         {:ok, migration_plan} <-
           MapLedger.begin_migration(ledger, region_id, target_ref,
             migration_id: migration_id,
             lease_id: 101,
             owner_epoch: 2,
             expires_at_ms: future_ms,
             token_version: 2,
             slice_width: 2
           ),
         {:ok, migration_slices} <- plan_all_migration_slices(ledger, migration_id),
         {:ok, migration_handoff} <- MapLedger.migration_handoff(ledger, migration_id),
         {:ok, acked_slices} <-
           ack_migration_slices(ledger, migration_id, migration_slices, target_ref),
         {:ok, prewarmed_plan} <- MapLedger.mark_prewarmed(ledger, migration_id),
         {:ok, prewarmed_snapshot} <-
           migration_snapshot_and_observe(ledger, migration_id, "prewarmed"),
         {:ok, final_catchup_slices} <-
           final_catchup_migration_slices(ledger, migration_id, migration_slices, target_ref),
         {:ok, cutover_plan} <- MapLedger.cutover_migration(ledger, migration_id),
         {:ok, completed_plan} <- MapLedger.complete_migration(ledger, migration_id),
         {:ok, token_v2} <- fetch_current_token(token_store, logical_scene_id, region_id),
         {:ok, route_v2} <-
           route_and_observe(ledger, logical_scene_id, chunk_coord, "after_migration"),
         {:ok, stale_after} <-
           validate_expected(
             :stale_after_migration,
             validate_both(ledger, token_store, write_attrs(lease_v1, chunk_coord)),
             %{world: {:error, :lease_id_mismatch}, data_service: {:error, :lease_id_mismatch}}
           ),
         {:ok, current_after} <-
           validate_expected(
             :current_after_migration,
             validate_both(
               ledger,
               token_store,
               write_attrs(completed_plan.new_lease, chunk_coord)
             ),
             %{world: :ok, data_service: :ok}
           ) do
      lease_v2 = completed_plan.new_lease

      result = %{
        logical_scene_id: logical_scene_id,
        observe_log: observe_log,
        region_id: region_id,
        chunk_coord: coord_list(chunk_coord),
        migration: %{
          plan: MigrationPlan.summary(migration_plan),
          slice: migration_slices |> List.first() |> MigrationPlan.slice_summary(),
          slices: Enum.map(migration_slices, &MigrationPlan.slice_summary/1),
          acked_slices: Enum.map(acked_slices, &MigrationPlan.slice_summary/1),
          final_catchup_slices: Enum.map(final_catchup_slices, &MigrationPlan.slice_summary/1),
          handoff: migration_handoff_summary(migration_handoff),
          prewarmed: MigrationPlan.summary(prewarmed_plan),
          prewarmed_snapshot: MigrationPlan.summary(prewarmed_snapshot),
          cutover: MigrationPlan.summary(cutover_plan),
          completed: MigrationPlan.summary(completed_plan)
        },
        leases: %{
          before_migration: lease_summary(lease_v1),
          after_migration: lease_summary(lease_v2)
        },
        routes: %{
          before_migration: assignment_summary(route_v1),
          after_migration: assignment_summary(route_v2)
        },
        tokens: %{
          before_migration: token_summary(token_v1),
          after_migration: token_summary(token_v2)
        },
        validations: %{
          current_before_migration: current_before,
          stale_after_migration: stale_after,
          current_after_migration: current_after
        }
      }

      emit_step("voxel_authority_acceptance_completed", result_for_log(result))
      {:ok, result}
    else
      {:error, reason} = error ->
        emit_step("voxel_authority_acceptance_failed", %{
          logical_scene_id: logical_scene_id,
          region_id: region_id,
          reason: inspect(reason)
        })

        error
    end
  end

  defp migration_snapshot_and_observe(ledger, migration_id, phase) do
    case MapLedger.migration_snapshot(ledger, migration_id) do
      {:ok, plan} ->
        summary =
          plan
          |> MigrationPlan.summary()
          |> Map.put(:phase, phase)

        emit_step("voxel_authority_migration_snapshot", summary)
        {:ok, plan}

      {:error, _reason} = error ->
        error
    end
  end

  defp plan_all_migration_slices(ledger, migration_id, acc \\ []) do
    case MapLedger.plan_next_migration_slice(ledger, migration_id) do
      {:ok, slice} ->
        plan_all_migration_slices(ledger, migration_id, [slice | acc])

      {:error, :migration_slices_exhausted} ->
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ack_migration_slices(ledger, migration_id, slices, target_ref) do
    Enum.reduce_while(slices, {:ok, []}, fn slice, {:ok, acc} ->
      chunk_count = slice_chunk_count(slice)

      case MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
             slice_id: slice.slice_id,
             scene_ref: target_ref,
             loaded_count: chunk_count,
             empty_count: 0,
             max_chunk_version: 0
           }) do
        {:ok, _plan, acked_slice} -> {:cont, {:ok, [acked_slice | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acked_slices} -> {:ok, Enum.reverse(acked_slices)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp final_catchup_migration_slices(ledger, migration_id, slices, target_ref) do
    Enum.reduce_while(slices, {:ok, []}, fn slice, {:ok, acc} ->
      chunk_count = slice_chunk_count(slice)

      case MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
             slice_id: slice.slice_id,
             scene_ref: target_ref,
             loaded_count: chunk_count,
             empty_count: 0,
             max_chunk_version: 0,
             source_persisted_count: chunk_count,
             source_missing_count: 0,
             source_error_count: 0
           }) do
        {:ok, _plan, caught_up_slice} -> {:cont, {:ok, [caught_up_slice | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, caught_up_slices} -> {:ok, Enum.reverse(caught_up_slices)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slice_chunk_count(slice) do
    {min_x, min_y, min_z} = slice.bounds_chunk_min
    {max_x, max_y, max_z} = slice.bounds_chunk_max
    (max_x - min_x) * (max_y - min_y) * (max_z - min_z)
  end

  defp route_and_observe(ledger, logical_scene_id, chunk_coord, phase) do
    case MapLedger.route_chunk(ledger, logical_scene_id, chunk_coord) do
      {:ok, assignment} ->
        emit_step("voxel_authority_chunk_routed", %{
          phase: phase,
          logical_scene_id: logical_scene_id,
          chunk_coord: coord_list(chunk_coord),
          region_id: assignment.region_id,
          lease_id: assignment.lease_id,
          owner_scene_instance_ref: assignment.owner_scene_instance_ref,
          owner_epoch: assignment.owner_epoch
        })

        {:ok, assignment}

      {:error, reason} = error ->
        emit_step("voxel_authority_chunk_route_failed", %{
          phase: phase,
          logical_scene_id: logical_scene_id,
          chunk_coord: coord_list(chunk_coord),
          reason: reason
        })

        error
    end
  end

  defp validate_both(ledger, token_store, attrs) do
    result = %{
      world: MapLedger.validate_write(ledger, attrs),
      data_service: WriteTokenStore.validate_write(token_store, attrs)
    }

    emit_step("voxel_authority_write_token_validated", %{
      logical_scene_id: attrs.logical_scene_id,
      region_id: attrs.region_id,
      chunk_coord: coord_list(attrs.chunk_coord),
      lease_id: attrs.lease_id,
      owner_scene_instance_ref: attrs.owner_scene_instance_ref,
      owner_epoch: attrs.owner_epoch,
      world_status: status_for_log(result.world),
      data_service_status: status_for_log(result.data_service)
    })

    result
  end

  defp validate_expected(step, actual, expected) do
    if actual == expected do
      {:ok, actual}
    else
      {:error, %{step: step, expected: expected, actual: actual}}
    end
  end

  defp fetch_current_token(token_store, logical_scene_id, region_id) do
    token_store
    |> WriteTokenStore.snapshot()
    |> Map.fetch({logical_scene_id, region_id})
    |> case do
      {:ok, token} ->
        emit_step("voxel_authority_write_token_published", %{
          logical_scene_id: logical_scene_id,
          region_id: region_id,
          lease_id: token.lease_id,
          owner_scene_instance_ref: token.owner_scene_instance_ref,
          owner_epoch: token.owner_epoch,
          token_version: token.token_version,
          bounds_chunk_min: coord_list(token.bounds_chunk_min),
          bounds_chunk_max: coord_list(token.bounds_chunk_max)
        })

        {:ok, token}

      :error ->
        {:error, :write_token_not_published}
    end
  end

  defp with_runtime(opts, fun) do
    case {Keyword.get(opts, :ledger), Keyword.get(opts, :write_token_store)} do
      {ledger, token_store} when not is_nil(ledger) and not is_nil(token_store) ->
        fun.(ledger, token_store)

      {nil, nil} ->
        start_runtime(opts, fun)

      {_ledger, _token_store} ->
        {:error, :ledger_and_write_token_store_must_be_passed_together}
    end
  end

  defp start_runtime(opts, fun) do
    ledger_opts =
      case resolve_scene_invalidator(opts) do
        nil -> []
        invalidator -> [scene_invalidator: invalidator]
      end

    case WriteTokenStore.start_link([]) do
      {:ok, token_store} ->
        case MapLedger.start_link([{:write_token_store, token_store} | ledger_opts]) do
          {:ok, ledger} ->
            try do
              fun.(ledger, token_store)
            after
              stop_if_alive(ledger)
              stop_if_alive(token_store)
            end

          {:error, reason} ->
            stop_if_alive(token_store)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_scene_invalidator(opts) do
    cond do
      invalidator = Keyword.get(opts, :scene_invalidator) ->
        invalidator

      directory = Keyword.get(opts, :scene_chunk_directory) ->
        scene_directory_invalidator(directory)

      true ->
        nil
    end
  end

  defp with_observe_log(observe_log, fun) do
    previous = Application.fetch_env(:world_server, :cli_observe_log)
    clear_observe_log(observe_log)
    Application.put_env(:world_server, :cli_observe_log, observe_log)

    try do
      fun.()
    after
      CliObserve.flush()
      restore_observe_log(previous)
    end
  end

  defp clear_observe_log(observe_log) do
    File.mkdir_p!(Path.dirname(observe_log))
    File.rm(observe_log)
    :ok
  end

  defp restore_observe_log({:ok, previous}) do
    Application.put_env(:world_server, :cli_observe_log, previous)
  end

  defp restore_observe_log(:error) do
    Application.delete_env(:world_server, :cli_observe_log)
  end

  defp resolve_observe_log(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)

    opts
    |> Keyword.get(:observe_log)
    |> case do
      nil ->
        observe_dir = Keyword.get(opts, :observe_dir, @default_observe_dir)
        default_observe_log(logical_scene_id, observe_dir)

      observe_log ->
        Path.expand(observe_log)
    end
  end

  defp write_attrs(lease, chunk_coord) do
    %{
      logical_scene_id: lease.logical_scene_id,
      region_id: lease.region_id,
      chunk_coord: chunk_coord,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch
    }
  end

  defp lease_summary(lease) do
    %{
      logical_scene_id: lease.logical_scene_id,
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      bounds_chunk_min: coord_list(lease.bounds_chunk_min),
      bounds_chunk_max: coord_list(lease.bounds_chunk_max)
    }
  end

  defp assignment_summary(assignment) do
    %{
      logical_scene_id: assignment.logical_scene_id,
      region_id: assignment.region_id,
      lease_id: assignment.lease_id,
      owner_scene_instance_ref: assignment.owner_scene_instance_ref,
      owner_epoch: assignment.owner_epoch,
      state: assignment.state,
      bounds_chunk_min: coord_list(assignment.bounds_chunk_min),
      bounds_chunk_max: coord_list(assignment.bounds_chunk_max)
    }
  end

  defp token_summary(token) do
    %{
      logical_scene_id: token.logical_scene_id,
      region_id: token.region_id,
      lease_id: token.lease_id,
      owner_scene_instance_ref: token.owner_scene_instance_ref,
      owner_epoch: token.owner_epoch,
      token_version: token.token_version,
      bounds_chunk_min: coord_list(token.bounds_chunk_min),
      bounds_chunk_max: coord_list(token.bounds_chunk_max)
    }
  end

  defp migration_handoff_summary(handoff) do
    %{
      migration_id: handoff.migration_id,
      logical_scene_id: handoff.logical_scene_id,
      region_id: handoff.region_id,
      state: handoff.state,
      source_scene_instance_ref: handoff.source_scene_instance_ref,
      target_scene_instance_ref: handoff.target_scene_instance_ref,
      old_lease: lease_summary(handoff.old_lease),
      new_lease: lease_summary(handoff.new_lease),
      token_version: handoff.token_version,
      affected_chunk_bounds: %{
        min: coord_list(handoff.affected_chunk_bounds.min),
        max: coord_list(handoff.affected_chunk_bounds.max)
      },
      planned_slices: Enum.map(handoff.planned_slices, &MigrationPlan.slice_summary/1),
      prewarm_ack_count: map_size(Map.get(handoff, :prewarm_acks, %{})),
      final_catchup_ack_count: map_size(Map.get(handoff, :final_catchup_acks, %{})),
      next_slice_index: handoff.next_slice_index,
      total_slices: handoff.total_slices
    }
  end

  defp result_for_log(result) do
    %{
      logical_scene_id: result.logical_scene_id,
      observe_log: result.observe_log,
      region_id: result.region_id,
      chunk_coord: result.chunk_coord,
      migration: result.migration,
      lease_before_migration: result.leases.before_migration,
      lease_after_migration: result.leases.after_migration,
      route_before_migration: result.routes.before_migration,
      route_after_migration: result.routes.after_migration,
      token_before_migration: result.tokens.before_migration,
      token_after_migration: result.tokens.after_migration,
      validations: %{
        current_before_migration: statuses_for_log(result.validations.current_before_migration),
        stale_after_migration: statuses_for_log(result.validations.stale_after_migration),
        current_after_migration: statuses_for_log(result.validations.current_after_migration)
      }
    }
  end

  defp statuses_for_log(statuses) do
    Map.new(statuses, fn {key, value} -> {key, status_for_log(value)} end)
  end

  defp status_for_log(:ok), do: "ok"
  defp status_for_log({:error, reason}), do: "error:#{reason}"
  defp status_for_log(other), do: inspect(other)

  defp coord_list({x, y, z}), do: [x, y, z]
  defp coord_list([x, y, z]), do: [x, y, z]

  defp emit_step(event, fields), do: CliObserve.emit(event, fields)

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
