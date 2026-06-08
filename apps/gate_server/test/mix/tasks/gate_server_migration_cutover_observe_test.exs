defmodule Mix.Tasks.GateServerMigrationCutoverObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DataService.Voxel.WriteTokenStore
  alias Mix.Tasks.GateServer.MigrationCutoverObserve
  alias SceneServer.VoxelChunkSup

  test "prints and logs migration cutover rebind evidence" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-migration-cutover-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        MigrationCutoverObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42"
        ])
      end)

    assert output =~ "gate_migration_cutover_rebind=ok"
    assert output =~ "cid=42"
    assert output =~ "logical_scene_id=1"
    assert output =~ "chunk=0,0,0"
    assert output =~ "old_lease_id=100"
    assert output =~ "new_lease_id=101"
    assert output =~ "old_owner=1000"
    assert output =~ "new_owner=2000"
    assert output =~ "partition_context_lease_id=101"
    assert output =~ "partition_context_epoch=2"
    assert output =~ "partition_context_owner=2000"
    assert output =~ "partition_context_scene_node=:scene_b@local"
    assert output =~ "rebind_status=rebound"
    assert output =~ "rebound_count=1"
    assert output =~ "snapshot_restored=true"
    assert output =~ "prewarm_ack_count=1"
    assert output =~ "final_catchup_ack_count=1"
    assert output =~ "source_persisted_count=1"
    assert output =~ "target_loaded_count=1"
    assert output =~ "stale_world_status=error:lease_id_mismatch"
    assert output =~ "stale_data_service_status=error:lease_id_mismatch"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_migration_cutover_rebind_started")
    assert log =~ ~s(event="voxel_migration_begun")
    assert log =~ ~s(event="voxel_migration_slice_planned")
    assert log =~ ~s(event="voxel_migration_slice_prewarm_started")
    assert log =~ ~s(event="voxel_migration_slice_prewarm_completed")
    assert log =~ ~s(event="voxel_migration_prewarmed")
    assert log =~ ~s(event="voxel_migration_slice_final_catchup_started")
    assert log =~ ~s(event="voxel_migration_slice_final_catchup_completed")
    assert log =~ ~s(event="voxel_migration_slice_final_caught_up")
    assert log =~ ~s(event="voxel_migration_cutover")
    assert log =~ ~s(event="voxel_migration_cutover_invalidate_emitted")
    assert log =~ ~s(event="voxel_chunk_invalidate_pushed")
    assert log =~ ~s(event="voxel_subscription_rebind_requested")
    assert log =~ ~s(event="voxel_subscription_rebind_subscribed_new")
    assert log =~ ~s(event="gate_migration_cutover_rebind_resolved")
    assert log =~ "partition_context: %{"
    assert log =~ "boundary_kind: :authority_cutover"
    assert log =~ "lease_id: 101"
    assert log =~ "assigned_scene_node: :scene_b@local"
    assert log =~ "snapshot_restored?: true"
    assert log =~ "source_persisted_count: 1"
    assert log =~ "loaded_count: 1"
  end

  test "prints pending recovery evidence when migration cutover rebind fails" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-migration-cutover-failed-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        MigrationCutoverObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "2",
          "--cid",
          "43",
          "--simulate-rebind-failure"
        ])
      end)

    assert output =~ "gate_migration_cutover_rebind=failed"
    assert output =~ "cid=43"
    assert output =~ "logical_scene_id=2"
    assert output =~ "rebind_result=error"
    assert output =~ "rebind_status=failed"
    assert output =~ "error_count=1"
    assert output =~ "invalidated_subscription_count=1"
    assert output =~ "pending_rebind_count=1"
    assert output =~ "snapshot_restored=false"

    log = File.read!(observe_log)
    assert log =~ ~s(event="voxel_chunk_invalidate_pushed")
    assert log =~ ~s(event="voxel_subscription_rebind_error")
    assert log =~ "active_subscription_removed?: true"
    assert log =~ "pending_rebind_count: 1"
    assert log =~ ~s(event="gate_migration_cutover_rebind_resolved")
  end

  test "keeps temporary migration smoke chunks out of the existing scene supervisor" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-migration-cutover-cleanup-#{System.unique_integer([:positive])}.log"
      )

    logical_scene_id = 1_000 + System.unique_integer([:positive])
    existing_sup = ensure_named_chunk_sup!()
    before_children = DynamicSupervisor.which_children(existing_sup)

    output =
      capture_io(fn ->
        MigrationCutoverObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          Integer.to_string(logical_scene_id),
          "--cid",
          "44"
        ])
      end)

    assert output =~ "gate_migration_cutover_rebind=ok"
    assert output =~ "logical_scene_id=#{logical_scene_id}"

    assert existing_sup |> DynamicSupervisor.which_children() |> MapSet.new() ==
             MapSet.new(before_children)
  end

  test "chooses fresh token versions when the global token store already has the smoke region" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-migration-cutover-token-isolation-#{System.unique_integer([:positive])}.log"
      )

    logical_scene_id = 2_000 + System.unique_integer([:positive])
    future_ms = System.system_time(:millisecond) + 60_000

    {:ok, _apps} = Application.ensure_all_started(:data_service)

    assert {:ok, _result} =
             WriteTokenStore.upsert_token(WriteTokenStore, %{
               logical_scene_id: logical_scene_id,
               region_id: 10,
               lease_id: 90,
               owner_scene_instance_ref: 900,
               owner_epoch: 9,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               expires_at_ms: future_ms,
               token_version: System.unique_integer([:positive, :monotonic])
             })

    output =
      capture_io(fn ->
        MigrationCutoverObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          Integer.to_string(logical_scene_id),
          "--cid",
          "45"
        ])
      end)

    assert output =~ "gate_migration_cutover_rebind=ok"
    assert output =~ "logical_scene_id=#{logical_scene_id}"
    assert output =~ "stale_data_service_status=error:lease_id_mismatch"
  end

  defp ensure_named_chunk_sup! do
    case Process.whereis(VoxelChunkSup) do
      nil -> start_supervised!({VoxelChunkSup, name: VoxelChunkSup})
      pid -> pid
    end
  end
end
