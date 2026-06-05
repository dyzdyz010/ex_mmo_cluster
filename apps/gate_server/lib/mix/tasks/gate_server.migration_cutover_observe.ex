defmodule Mix.Tasks.GateServer.MigrationCutoverObserve do
  @moduledoc """
  Runs a Gate-side migration-cutover rebind observe smoke.

      mix gate_server.migration_cutover_observe --logical-scene-id 1 --cid 42

  The task demonstrates the non-GUI path for a staged World migration:
  World handoff -> target Scene prewarm -> source Scene final catch-up -> World
  route/lease cutover -> migration invalidate -> Gate subscription rebind ->
  Scene snapshot restore. It writes World, Scene, and Gate observe events to the
  same log so the control flow can be inspected without a browser.
  """

  use Mix.Task

  alias DataService.Voxel.WriteTokenStore
  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.Voxel.SubscriptionRebind
  alias SceneServer.CliObserve, as: SceneObserve
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.MigrationPrewarm
  alias SceneServer.Voxel.NormalBlockData
  alias WorldServer.Voxel.AuthorityObserve
  alias WorldServer.CliObserve, as: WorldObserve
  alias WorldServer.Voxel.MapLedger

  @shortdoc "Runs Gate migration-cutover rebind CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    simulate_rebind_failure: :boolean,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :cid, o: :observe_dir]

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
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    cid = Keyword.get(opts, :cid, 42)
    observe_log = observe_path(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)
    previous_scene_log = Application.fetch_env(:scene_server, :cli_observe_log)
    previous_world_log = Application.fetch_env(:world_server, :cli_observe_log)
    scene_started = ensure_scene_voxel_started()

    invalidator =
      AuthorityObserve.scene_directory_invalidator(scene_started.source_chunk_directory)

    {:ok, ledger} =
      MapLedger.start_link(write_token_store: WriteTokenStore, scene_invalidator: invalidator)

    try do
      reset_log(observe_log)
      Application.delete_env(:gate_server, :cli_observe_log)
      Application.delete_env(:scene_server, :cli_observe_log)
      Application.delete_env(:world_server, :cli_observe_log)

      routes = register_observe_routes(logical_scene_id, observe_log)

      try do
        summary =
          run_cutover_rebind(ledger, logical_scene_id, cid, observe_log, opts, scene_started)

        GateObserve.emit("gate_migration_cutover_rebind_resolved", summary)
        GateObserve.flush()
        SceneObserve.flush_path(observe_log)
        WorldObserve.flush()
        Mix.shell().info(summary_line(summary))
      after
        unregister_observe_routes(routes, logical_scene_id)
      end
    after
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      stop_scene_voxel_started(scene_started)
      GateObserve.flush()
      SceneObserve.flush_path(observe_log)
      WorldObserve.flush()
      restore_env(:gate_server, previous_gate_log)
      restore_env(:scene_server, previous_scene_log)
      restore_env(:world_server, previous_world_log)
    end
  end

  defp run_cutover_rebind(ledger, logical_scene_id, cid, observe_log, opts, scene_runtime) do
    region_id = 10
    chunk_coord = {0, 0, 0}
    future_ms = System.system_time(:millisecond) + :timer.minutes(10)
    source_scene_node = :scene_a@local
    target_scene_node = :scene_b@local
    source_ref = 1_000
    target_ref = 2_000
    migration_id = "gate-cutover-cli-#{logical_scene_id}-#{region_id}"
    token_version_base = next_token_version(logical_scene_id, region_id)

    {:ok, old_lease} =
      seed_region!(
        ledger,
        logical_scene_id,
        region_id,
        source_ref,
        future_ms,
        source_scene_node,
        token_version_base
      )

    seed_source_chunk!(
      scene_runtime.source_chunk_directory,
      logical_scene_id,
      chunk_coord,
      old_lease
    )

    subscribe_existing_chunk!(
      scene_runtime.source_chunk_directory,
      logical_scene_id,
      chunk_coord,
      old_lease
    )

    drain_initial_snapshot()

    state = %{
      cid: cid,
      partition_context: %{
        logical_scene_id: logical_scene_id,
        region_id: region_id,
        chunk_coord: chunk_coord,
        lease_id: old_lease.lease_id,
        owner_scene_instance_ref: old_lease.owner_scene_instance_ref,
        owner_epoch: old_lease.owner_epoch,
        assigned_scene_node: source_scene_node
      },
      voxel_subscriptions: %{
        {logical_scene_id, chunk_coord} =>
          subscription_handle(logical_scene_id, chunk_coord, region_id, source_scene_node)
      }
    }

    GateObserve.emit("gate_migration_cutover_rebind_started", %{
      cid: cid,
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      chunk_coord: chunk_coord,
      old_lease_id: 100,
      old_owner_scene_instance_ref: source_ref,
      source_scene_node: source_scene_node,
      target_scene_node: target_scene_node
    })

    {:ok, _migration_plan} =
      MapLedger.begin_migration(ledger, region_id, target_ref,
        migration_id: migration_id,
        lease_id: 101,
        owner_epoch: 2,
        expires_at_ms: future_ms,
        token_version: token_version_base + 1,
        target_scene_node: target_scene_node,
        slice_width: 1
      )

    {:ok, _planned_slices} = plan_all_migration_slices(ledger, migration_id)
    {:ok, prewarm_handoff} = MapLedger.migration_handoff(ledger, migration_id)

    {:ok, %{acks: prewarm_acks}} =
      MigrationPrewarm.prewarm_slices(prewarm_handoff,
        chunk_directory: scene_runtime.target_chunk_directory
      )

    {:ok, prewarmed_slices} = mark_prewarm_acks(ledger, migration_id, prewarm_acks)
    {:ok, _prewarmed_plan} = MapLedger.mark_prewarmed(ledger, migration_id)
    {:ok, catchup_handoff} = MapLedger.migration_handoff(ledger, migration_id)

    {:ok, %{acks: final_catchup_acks}} =
      MigrationPrewarm.final_catchup_slices(catchup_handoff,
        source_chunk_directory: scene_runtime.source_chunk_directory,
        target_chunk_directory: scene_runtime.target_chunk_directory
      )

    {:ok, final_catchup_slices} =
      mark_final_catchup_acks(ledger, migration_id, final_catchup_acks)

    {:ok, cutover_plan} = MapLedger.cutover_migration(ledger, migration_id)
    {:ok, completed_plan} = MapLedger.complete_migration(ledger, migration_id)
    new_lease = completed_plan.new_lease
    invalidate_event = receive_invalidate!(logical_scene_id, chunk_coord)
    stale_validation = stale_validation(ledger, old_lease, chunk_coord)

    {rebind_status, next_state, rebind_summary} =
      case SubscriptionRebind.apply_cutover_invalidation(state, invalidate_event,
             route_fun: fn scene_id, routed_chunk ->
               MapLedger.route_chunk_with_lease(ledger, scene_id, routed_chunk)
             end,
             scene_call_fun:
               scene_call_fun(opts, scene_runtime, source_scene_node, target_scene_node),
             subscriber: self(),
             connection_pid: self()
           ) do
        {:ok, rebound_state, summary} -> {:ok, rebound_state, summary}
        {:error, rebound_state, summary} -> {:error, rebound_state, summary}
      end

    {snapshot_restored?, snapshot_summary} =
      if rebind_status == :ok do
        receive_rebind_snapshot()
      else
        {false, nil}
      end

    key = {logical_scene_id, chunk_coord}

    %{
      cid: cid,
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      chunk_coord: Tuple.to_list(chunk_coord),
      old_lease_id: 100,
      new_lease_id: new_lease.lease_id,
      old_owner_scene_instance_ref: source_ref,
      new_owner_scene_instance_ref: new_lease.owner_scene_instance_ref,
      old_owner_epoch: 1,
      new_owner_epoch: new_lease.owner_epoch,
      source_scene_node: source_scene_node,
      target_scene_node: target_scene_node,
      prewarm_ack_count: length(prewarm_acks),
      prewarmed_slice_count: length(prewarmed_slices),
      final_catchup_ack_count: length(final_catchup_acks),
      final_catchup_slice_count: length(final_catchup_slices),
      source_persisted_count: sum_ack(final_catchup_acks, :source_persisted_count),
      source_missing_count: sum_ack(final_catchup_acks, :source_missing_count),
      source_error_count: sum_ack(final_catchup_acks, :source_error_count),
      target_loaded_count: sum_ack(final_catchup_acks, :loaded_count),
      target_empty_count: sum_ack(final_catchup_acks, :empty_count),
      migration_state_after_cutover: cutover_plan.state,
      migration_state_completed: completed_plan.state,
      stale_world_status: stale_validation.world,
      stale_data_service_status: stale_validation.data_service,
      rebind_status: rebind_summary.status,
      rebind_result: rebind_status,
      rebound_count: rebind_summary.rebound_count,
      skipped_count: rebind_summary.skipped_count,
      error_count: rebind_summary.error_count,
      invalidated_subscription_count: Map.get(rebind_summary, :invalidated_subscription_count, 0),
      pending_rebind_count: Map.get(rebind_summary, :pending_rebind_count, 0),
      snapshot_restored?: snapshot_restored?,
      snapshot: snapshot_summary,
      active_subscription:
        subscription_summary(Map.get(Map.get(next_state, :voxel_subscriptions, %{}), key)),
      partition_context: partition_context_summary(Map.get(next_state, :partition_context)),
      pending_rebind:
        pending_rebind_summary(
          Map.get(Map.get(next_state, :voxel_subscription_rebind_pending, %{}), key)
        ),
      invalidate_reason: invalidate_event.reason_name,
      observe_log: observe_log
    }
  end

  defp scene_call_fun(opts, scene_runtime, source_scene_node, target_scene_node) do
    if Keyword.get(opts, :simulate_rebind_failure, false) do
      fn _server, _message, _timeout -> {:ok, {:error, :simulated_scene_down}} end
    else
      fn
        {ChunkDirectory, ^source_scene_node}, message, timeout ->
          default_scene_call(scene_runtime.source_chunk_directory, message, timeout)

        {ChunkDirectory, ^target_scene_node}, message, timeout ->
          default_scene_call(scene_runtime.target_chunk_directory, message, timeout)

        server, message, timeout ->
          default_scene_call(server, message, timeout)
      end
    end
  end

  defp default_scene_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp seed_region!(
         ledger,
         logical_scene_id,
         region_id,
         owner_ref,
         future_ms,
         source_scene_node,
         token_version
       ) do
    {:ok, _assignment} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: logical_scene_id,
        region_id: region_id,
        bounds_chunk_min: {0, 0, 0},
        bounds_chunk_max: {1, 1, 1},
        owner_scene_instance_ref: owner_ref,
        owner_epoch: 0,
        assigned_scene_node: source_scene_node
      })

    {:ok, _lease} =
      MapLedger.issue_lease(ledger, region_id, owner_ref,
        lease_id: 100,
        owner_epoch: 1,
        expires_at_ms: future_ms,
        token_version: token_version
      )
  end

  defp next_token_version(logical_scene_id, region_id) do
    case WriteTokenStore.snapshot(WriteTokenStore) do
      tokens when is_map(tokens) ->
        case Map.get(tokens, {logical_scene_id, region_id}) do
          %{token_version: token_version} when is_integer(token_version) -> token_version + 1
          _other -> 1
        end
    end
  catch
    :exit, _reason -> 1
  end

  defp receive_invalidate!(logical_scene_id, chunk_coord) do
    receive do
      {:voxel_chunk_invalidate_payload, payload} when is_binary(payload) ->
        case SceneVoxelCodec.decode_chunk_invalidate_payload(payload) do
          {:ok,
           %{
             logical_scene_id: ^logical_scene_id,
             chunk_coord: ^chunk_coord,
             reason_name: :migration_cutover
           } = invalidate} ->
            invalidate

          {:ok, other} ->
            Mix.raise("unexpected migration cutover invalidation: #{inspect(other)}")

          {:error, reason} ->
            Mix.raise("malformed migration cutover invalidation: #{inspect(reason)}")
        end
    after
      1_000 -> Mix.raise("migration cutover invalidation was not emitted")
    end
  end

  defp seed_source_chunk!(source_chunk_directory, logical_scene_id, chunk_coord, lease) do
    case ChunkDirectory.apply_intent(source_chunk_directory, %{
           request_id: 76,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           lease: lease,
           operation: :put_solid_block,
           macro: {0, 0, 0},
           block: NormalBlockData.new(23, health: 70)
         }) do
      {:ok, _summary} -> :ok
      {:error, reason} -> Mix.raise("failed to seed source chunk: #{inspect(reason)}")
    end
  end

  defp subscribe_existing_chunk!(source_chunk_directory, logical_scene_id, chunk_coord, lease) do
    case ChunkDirectory.subscribe(source_chunk_directory, %{
           request_id: 77,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           subscriber: self(),
           lease: lease,
           send_snapshot?: true
         }) do
      {:ok, _payload} -> :ok
      {:error, reason} -> Mix.raise("failed to subscribe source chunk: #{inspect(reason)}")
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

  defp mark_prewarm_acks(ledger, migration_id, acks) do
    Enum.reduce_while(acks, {:ok, []}, fn ack, {:ok, acc} ->
      case MapLedger.mark_slice_prewarmed(ledger, migration_id, ack) do
        {:ok, _plan, slice} -> {:cont, {:ok, [slice | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, slices} -> {:ok, Enum.reverse(slices)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_final_catchup_acks(ledger, migration_id, acks) do
    Enum.reduce_while(acks, {:ok, []}, fn ack, {:ok, acc} ->
      case MapLedger.mark_slice_final_caught_up(ledger, migration_id, ack) do
        {:ok, _plan, slice} -> {:cont, {:ok, [slice | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, slices} -> {:ok, Enum.reverse(slices)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stale_validation(ledger, old_lease, chunk_coord) do
    attrs = %{
      logical_scene_id: old_lease.logical_scene_id,
      region_id: old_lease.region_id,
      chunk_coord: chunk_coord,
      lease_id: old_lease.lease_id,
      owner_scene_instance_ref: old_lease.owner_scene_instance_ref,
      owner_epoch: old_lease.owner_epoch
    }

    %{
      world: MapLedger.validate_write(ledger, attrs),
      data_service: WriteTokenStore.validate_write(WriteTokenStore, attrs)
    }
  end

  defp sum_ack(acks, key) do
    Enum.reduce(acks, 0, fn ack, acc -> acc + Map.get(ack, key, 0) end)
  end

  defp drain_initial_snapshot do
    receive do
      {:voxel_chunk_snapshot_payload, _payload} -> :ok
    after
      0 -> :ok
    end
  end

  defp receive_rebind_snapshot do
    receive do
      {:voxel_delivery_envelope, %{frame_kind: :snapshot, payload: payload} = envelope}
      when is_binary(payload) ->
        decode_rebind_snapshot(payload, envelope)

      {:voxel_chunk_snapshot_payload, payload} when is_binary(payload) ->
        decode_rebind_snapshot(payload, %{delivery_format: :raw})
    after
      1_000 -> {false, nil}
    end
  end

  defp decode_rebind_snapshot(payload, metadata) do
    case SceneVoxelCodec.decode_chunk_snapshot_payload(payload) do
      {:ok, snapshot} ->
        {true,
         %{
           request_id: snapshot.request_id,
           logical_scene_id: snapshot.storage.logical_scene_id,
           chunk_coord: Tuple.to_list(snapshot.storage.chunk_coord),
           chunk_version: snapshot.storage.chunk_version,
           delivery_format: Map.get(metadata, :delivery_format, :envelope),
           tier: Map.get(metadata, :tier),
           lease_id: Map.get(metadata, :lease_id),
           owner_epoch: Map.get(metadata, :owner_epoch)
         }}

      {:error, reason} ->
        {false, %{decode_error: reason}}
    end
  end

  defp subscription_handle(logical_scene_id, chunk_coord, region_id, scene_node) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      request_id: 77,
      scene_node: scene_node,
      region_id: region_id,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1
    }
  end

  defp subscription_summary(nil), do: nil

  defp subscription_summary(subscription) do
    Map.take(subscription, [
      :logical_scene_id,
      :chunk_coord,
      :region_id,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch,
      :scene_node
    ])
  end

  defp partition_context_summary(nil), do: nil

  defp partition_context_summary(context) do
    Map.take(context, [
      :logical_scene_id,
      :region_id,
      :chunk_coord,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch,
      :assigned_scene_node,
      :boundary_kind,
      :route_refresh_reason
    ])
  end

  defp pending_rebind_summary(nil), do: nil

  defp pending_rebind_summary(pending) do
    Map.take(pending, [
      :logical_scene_id,
      :chunk_coord,
      :region_id,
      :old_lease_id,
      :old_owner_scene_instance_ref,
      :old_owner_epoch,
      :reason,
      :rebind_reason,
      :retry_count
    ])
  end

  defp ensure_scene_voxel_started do
    ensure_data_service_started()

    # ChunkProcess auto-circuit refresh (`refresh_auto_circuit_after_mutation`)
    # starts per-region field workers through this DynamicSupervisor. Without it
    # any mutation that energizes a circuit crashes with `no process`. Mirror the
    # scene test runtime (`TestVoxelRuntime`), which boots it alongside the chunk
    # directory.
    case SceneServer.Voxel.Field.FieldTickSupervisor.start_link(
           name: SceneServer.Voxel.Field.FieldTickSupervisor
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Scene-side cutover/prewarm/invalidate observe events
    # (`voxel_chunk_invalidate_pushed`, `voxel_migration_slice_prewarm_started`,
    # ...) are written by the supervised `SceneServer.CliObserve.Manager`.
    # Routes are registered below, but without the manager the routed scene log
    # stays empty and cutover evidence is lost.
    case SceneServer.CliObserve.Manager.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # 阶段3.1：用两套独立 (Registry + VoxelChunkSup + ChunkDirectory) 模拟
    # source / target 两个 scene_node 的隔离权威域。同 {scene_id, coord} 在
    # 各自注册表里互不冲突，正确还原跨节点迁移的双权威隔离。
    {:ok, _source_registry} =
      Registry.start_link(keys: :unique, name: __MODULE__.SourceChunkRegistry)

    {:ok, _target_registry} =
      Registry.start_link(keys: :unique, name: __MODULE__.TargetChunkRegistry)

    {:ok, source_chunk_sup} = SceneServer.VoxelChunkSup.start_link([])
    {:ok, target_chunk_sup} = SceneServer.VoxelChunkSup.start_link([])

    {:ok, source_chunk_directory} =
      ChunkDirectory.start_link(
        chunk_sup: source_chunk_sup,
        chunk_registry: __MODULE__.SourceChunkRegistry
      )

    {:ok, target_chunk_directory} =
      ChunkDirectory.start_link(
        chunk_sup: target_chunk_sup,
        chunk_registry: __MODULE__.TargetChunkRegistry
      )

    %{
      source_chunk_sup: source_chunk_sup,
      target_chunk_sup: target_chunk_sup,
      source_chunk_directory: source_chunk_directory,
      target_chunk_directory: target_chunk_directory
    }
  end

  defp ensure_data_service_started do
    {:ok, _apps} = Application.ensure_all_started(:data_service)

    case Process.whereis(DataService.Repo) do
      nil ->
        case DataService.Repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp stop_scene_voxel_started(%{source_chunk_directory: pid} = started) when is_pid(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_down(ref)
    stop_scene_voxel_started(%{started | source_chunk_directory: :stopped})
  end

  defp stop_scene_voxel_started(%{target_chunk_directory: pid} = started) when is_pid(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_down(ref)
    stop_scene_voxel_started(%{started | target_chunk_directory: :stopped})
  end

  defp stop_scene_voxel_started(%{source_chunk_sup: pid} = started) when is_pid(pid) do
    ref = Process.monitor(pid)
    DynamicSupervisor.stop(pid)
    assert_down(ref)
    stop_scene_voxel_started(%{started | source_chunk_sup: :stopped})
  end

  defp stop_scene_voxel_started(%{target_chunk_sup: pid} = started) when is_pid(pid) do
    ref = Process.monitor(pid)
    DynamicSupervisor.stop(pid)
    assert_down(ref)
    stop_scene_voxel_started(%{started | target_chunk_sup: :stopped})
  end

  defp stop_scene_voxel_started(_started), do: :ok

  defp assert_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp summary_line(summary) do
    [
      "gate_migration_cutover_rebind=#{format_result(summary.rebind_result)}",
      "cid=#{summary.cid}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "region_id=#{summary.region_id}",
      "chunk=#{Enum.join(summary.chunk_coord, ",")}",
      "old_lease_id=#{summary.old_lease_id}",
      "new_lease_id=#{summary.new_lease_id}",
      "old_owner=#{summary.old_owner_scene_instance_ref}",
      "new_owner=#{summary.new_owner_scene_instance_ref}",
      "old_epoch=#{summary.old_owner_epoch}",
      "new_epoch=#{summary.new_owner_epoch}",
      "partition_context_lease_id=#{Map.get(summary.partition_context || %{}, :lease_id, :none)}",
      "partition_context_epoch=#{Map.get(summary.partition_context || %{}, :owner_epoch, :none)}",
      "partition_context_owner=#{Map.get(summary.partition_context || %{}, :owner_scene_instance_ref, :none)}",
      "partition_context_scene_node=#{inspect(Map.get(summary.partition_context || %{}, :assigned_scene_node, :none))}",
      "source_scene_node=#{inspect(summary.source_scene_node)}",
      "target_scene_node=#{inspect(summary.target_scene_node)}",
      "prewarm_ack_count=#{summary.prewarm_ack_count}",
      "prewarmed_slice_count=#{summary.prewarmed_slice_count}",
      "final_catchup_ack_count=#{summary.final_catchup_ack_count}",
      "final_catchup_slice_count=#{summary.final_catchup_slice_count}",
      "source_persisted_count=#{summary.source_persisted_count}",
      "source_missing_count=#{summary.source_missing_count}",
      "source_error_count=#{summary.source_error_count}",
      "target_loaded_count=#{summary.target_loaded_count}",
      "target_empty_count=#{summary.target_empty_count}",
      "migration_state_after_cutover=#{summary.migration_state_after_cutover}",
      "migration_state_completed=#{summary.migration_state_completed}",
      "stale_world_status=#{format_status(summary.stale_world_status)}",
      "stale_data_service_status=#{format_status(summary.stale_data_service_status)}",
      "invalidate_reason=#{summary.invalidate_reason}",
      "rebind_result=#{summary.rebind_result}",
      "rebind_status=#{summary.rebind_status}",
      "rebound_count=#{summary.rebound_count}",
      "skipped_count=#{summary.skipped_count}",
      "error_count=#{summary.error_count}",
      "invalidated_subscription_count=#{summary.invalidated_subscription_count}",
      "pending_rebind_count=#{summary.pending_rebind_count}",
      "snapshot_restored=#{summary.snapshot_restored?}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp format_result(:ok), do: "ok"
  defp format_result(:error), do: "failed"
  defp format_result(other), do: inspect(other)

  defp format_status(:ok), do: "ok"
  defp format_status({:error, reason}), do: "error:#{reason}"
  defp format_status(other), do: inspect(other)

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "gate-migration-cutover-#{logical_scene_id}.log")
    )
  end

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp register_observe_routes(logical_scene_id, observe_log) do
    [
      GateObserve,
      SceneObserve,
      WorldObserve
    ]
    |> Enum.flat_map(fn observe_module ->
      case observe_module.register_route(logical_scene_id, observe_log) do
        {:ok, token} -> [{observe_module, token}]
        {:error, _reason} -> []
      end
    end)
  end

  defp unregister_observe_routes(routes, logical_scene_id) do
    Enum.each(routes, fn {observe_module, token} ->
      observe_module.unregister_route(logical_scene_id, token)
    end)
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
