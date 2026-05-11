defmodule WorldServer.Voxel.AuthorityObserveTest do
  use ExUnit.Case, async: false

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.AuthorityObserve
  alias WorldServer.Voxel.MapLedger

  setup do
    previous = Application.fetch_env(:world_server, :cli_observe_log)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:world_server, :cli_observe_log, value)
        :error -> Application.delete_env(:world_server, :cli_observe_log)
      end
    end)

    :ok
  end

  test "runs a logical scene lease, route, migration, and token validation observe flow" do
    token_store = start_supervised!(WriteTokenStore)
    ledger = start_supervised!({MapLedger, write_token_store: token_store})
    observe_log = observe_log_path("authority-observe")

    assert {:ok, result} =
             AuthorityObserve.run(
               logical_scene_id: 77,
               observe_log: observe_log,
               ledger: ledger,
               write_token_store: token_store
             )

    assert result.logical_scene_id == 77
    assert Path.expand(result.observe_log) == Path.expand(observe_log)
    assert result.leases.before_migration.lease_id == 100
    assert result.leases.after_migration.lease_id == 101
    assert result.routes.before_migration.owner_scene_instance_ref == 1_000
    assert result.routes.after_migration.owner_scene_instance_ref == 2_000
    assert result.migration.plan.state == :prewarming
    assert result.migration.plan.source_scene_instance_ref == 1_000
    assert result.migration.plan.target_scene_instance_ref == 2_000
    assert result.migration.slice.bounds_chunk_min == [0, 0, 0]
    assert result.migration.slice.bounds_chunk_max == [2, 4, 4]
    assert result.migration.handoff.old_lease.lease_id == 100
    assert result.migration.handoff.new_lease.lease_id == 101
    assert length(result.migration.acked_slices) == 2
    assert Enum.all?(result.migration.acked_slices, &(&1.state == :prewarmed))
    assert length(result.migration.final_catchup_slices) == 2

    assert Enum.all?(
             result.migration.final_catchup_slices,
             &Map.has_key?(&1, :final_catchup_ack)
           )

    assert result.migration.prewarmed_snapshot.state == :prewarmed
    assert result.migration.completed.state == :completed
    assert result.validations.current_before_migration == %{world: :ok, data_service: :ok}

    assert result.validations.stale_after_migration == %{
             world: {:error, :lease_id_mismatch},
             data_service: {:error, :lease_id_mismatch}
           }

    assert result.validations.current_after_migration == %{world: :ok, data_service: :ok}

    assert event?(observe_log, "voxel_authority_acceptance_started")
    assert event?(observe_log, "voxel_region_put")
    assert event?(observe_log, "voxel_lease_issued")
    assert event?(observe_log, "voxel_authority_write_token_published")
    assert event?(observe_log, "voxel_authority_chunk_routed")
    assert event?(observe_log, "voxel_migration_begun")
    assert event?(observe_log, "voxel_migration_slice_planned")
    assert event?(observe_log, "voxel_migration_slice_prewarmed")
    assert event?(observe_log, "voxel_migration_handoff_read")
    assert event?(observe_log, "voxel_migration_prewarmed")
    assert event?(observe_log, "voxel_authority_migration_snapshot")
    assert event?(observe_log, "voxel_migration_slice_final_caught_up")
    assert event?(observe_log, "voxel_migration_cutover")
    assert event?(observe_log, "voxel_region_migrated")
    assert event?(observe_log, "voxel_migration_completed")
    assert event?(observe_log, "voxel_authority_write_token_validated")
    assert event?(observe_log, "voxel_authority_acceptance_completed")

    lines = read_observe_lines(observe_log)
    assert Enum.any?(lines, &String.contains?(&1, "logical_scene_id: 77"))
    assert Enum.any?(lines, &String.contains?(&1, "world_status: \"error:lease_id_mismatch\""))

    assert Enum.any?(
             lines,
             &String.contains?(&1, "data_service_status: \"error:lease_id_mismatch\"")
           )
  end

  describe "scene invalidator wiring" do
    setup do
      ensure_scene_server_loaded!()
      :ok
    end

    test "real ChunkDirectory subscriber receives ChunkInvalidate after cutover" do
      directory_module = Module.concat(["SceneServer", "Voxel", "ChunkDirectory"])
      chunk_sup_module = Module.concat(["SceneServer", "VoxelChunkSup"])

      token_store = start_supervised!(WriteTokenStore)
      chunk_sup = start_supervised!(chunk_sup_module)

      directory =
        start_supervised!(
          {directory_module,
           chunk_sup: chunk_sup, snapshot_store: DataService.Voxel.ChunkSnapshotStore}
        )

      invalidator = WorldServer.Voxel.AuthorityObserve.scene_directory_invalidator(directory)

      ledger =
        start_supervised!(
          {MapLedger, write_token_store: token_store, scene_invalidator: invalidator}
        )

      observe_log = observe_log_path("authority-cutover-invalidate")

      logical_scene_id = 88
      chunk_coord = {1, 0, 0}

      # Pre-stage region/lease so we can subscribe to the chunk before kicking the run.
      future_ms = System.system_time(:millisecond) + 60_000

      assert {:ok, _assignment} =
               MapLedger.put_region(ledger, %{
                 logical_scene_id: logical_scene_id,
                 region_id: 10,
                 bounds_chunk_min: {0, 0, 0},
                 bounds_chunk_max: {4, 4, 4},
                 owner_scene_instance_ref: 1_000,
                 owner_epoch: 0,
                 assigned_scene_node: node()
               })

      assert {:ok, lease} =
               MapLedger.issue_lease(ledger, 10, 1_000,
                 lease_id: 100,
                 owner_epoch: 1,
                 expires_at_ms: future_ms,
                 token_version: 1
               )

      # Subscribe BEFORE running the migration; this should receive the invalidate
      # payload after cutover.
      assert {:ok, _payload} =
               directory_module.subscribe(directory, %{
                 logical_scene_id: logical_scene_id,
                 chunk_coord: chunk_coord,
                 lease: lease,
                 subscriber: self()
               })

      # Drain the immediate snapshot push from the subscribe call.
      assert_receive {:voxel_chunk_snapshot_payload, _snapshot}, 500

      # AuthorityObserve normally calls put_region/issue_lease itself, but we already
      # did so above so we can subscribe pre-cutover. Use begin_migration onward
      # directly to drive the rest of the flow.
      migration_id = "authority-#{logical_scene_id}-region-10"

      assert {:ok, _plan} =
               MapLedger.begin_migration(ledger, 10, 2_000,
                 migration_id: migration_id,
                 lease_id: 101,
                 owner_epoch: 2,
                 expires_at_ms: future_ms,
                 token_version: 2,
                 slice_width: 4
               )

      assert {:ok, slice} = MapLedger.plan_next_migration_slice(ledger, migration_id)

      assert {:ok, _plan, _acked_slice} =
               MapLedger.mark_slice_prewarmed(ledger, migration_id, %{
                 slice_id: slice.slice_id,
                 scene_ref: 2_000
               })

      assert {:ok, _prewarmed} = MapLedger.mark_prewarmed(ledger, migration_id)

      assert {:ok, _final_plan, _final_slice} =
               MapLedger.mark_slice_final_caught_up(ledger, migration_id, %{
                 slice_id: slice.slice_id,
                 scene_ref: 2_000
               })

      previous_log = Application.fetch_env(:world_server, :cli_observe_log)
      File.mkdir_p!(Path.dirname(observe_log))
      File.rm(observe_log)
      Application.put_env(:world_server, :cli_observe_log, observe_log)

      try do
        assert {:ok, cutover_plan} = MapLedger.cutover_migration(ledger, migration_id)
        assert cutover_plan.state == :cutover
      after
        WorldServer.CliObserve.flush()

        case previous_log do
          {:ok, value} -> Application.put_env(:world_server, :cli_observe_log, value)
          :error -> Application.delete_env(:world_server, :cli_observe_log)
        end
      end

      assert_receive {:voxel_chunk_invalidate_payload, payload}, 500
      assert is_binary(payload)

      lines = read_observe_lines(observe_log)
      assert Enum.any?(lines, &String.contains?(&1, "voxel_migration_cutover_invalidate_emitted"))
    end
  end

  defp ensure_scene_server_loaded! do
    scene_ebin = Path.expand("../../../../../_build/test/lib/scene_server/ebin", __DIR__)

    if File.dir?(scene_ebin) do
      _ = :code.add_path(String.to_charlist(scene_ebin))
    end

    directory_module = Module.concat(["SceneServer", "Voxel", "ChunkDirectory"])

    unless Code.ensure_loaded?(directory_module) do
      raise """
      SceneServer.Voxel.ChunkDirectory is not loadable. Compile from the umbrella root with
      `mix compile` so scene_server beams exist under #{scene_ebin}.
      """
    end

    # Make sure the supporting application is started so its ETS-backed dependencies behave.
    _ = Application.ensure_all_started(:scene_server)
  end

  defp observe_log_path(name) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "world-server-observe-tests",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "#{name}.log")
  end

  defp event?(observe_log, event) do
    observe_log
    |> read_observe_lines()
    |> Enum.any?(fn line -> String.contains?(line, ~s(event="#{event}")) end)
  end

  defp read_observe_lines(observe_log) do
    observe_log
    |> File.read!()
    |> String.split("\n", trim: true)
  end
end
