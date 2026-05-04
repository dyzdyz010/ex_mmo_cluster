defmodule WorldServer.Voxel.MapLedgerPersistenceTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.RegionAssignment

  setup do
    tmp_dir = System.tmp_dir!()
    name = "voxel_map_ledger_#{System.unique_integer([:positive, :monotonic])}.bin"
    path = Path.join(tmp_dir, name)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "round-trips region assignments + leases through file persistence", %{path: path} do
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :first_ledger)

    assert {:ok, %RegionAssignment{}} =
             MapLedger.put_region(ledger,
               logical_scene_id: 7,
               region_id: 70,
               owner_scene_instance_ref: 700,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 4, 4},
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 70, 700,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert File.exists?(path)
    payload = File.read!(path)
    assert byte_size(payload) > 0

    snapshot = MapLedger.snapshot(ledger)
    assert Map.has_key?(snapshot.assignments, 70)
    assert Map.has_key?(snapshot.leases, 70)

    stop_supervised!(:first_ledger)

    revived = start_supervised!({MapLedger, persistence_path: path}, id: :revived_ledger)

    revived_snapshot = MapLedger.snapshot(revived)
    assert Map.has_key?(revived_snapshot.assignments, 70)
    assert Map.has_key?(revived_snapshot.leases, 70)
    assert revived_snapshot.assignments[70].owner_scene_instance_ref == 700
  end

  test "init survives an empty/missing persistence file", %{path: path} do
    refute File.exists?(path)
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :empty_ledger)

    snapshot = MapLedger.snapshot(ledger)
    assert snapshot.assignments == %{}
    assert snapshot.leases == %{}
    assert snapshot.migrations == %{}
  end

  test "migration plans round-trip through file persistence", %{path: path} do
    ledger = start_supervised!({MapLedger, persistence_path: path}, id: :migration_ledger)

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger,
               logical_scene_id: 8,
               region_id: 80,
               owner_scene_instance_ref: 800,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 1, 1},
               state: :idle
             )

    assert {:ok, _lease} =
             MapLedger.issue_lease(ledger, 80, 800,
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000
             )

    assert {:ok, plan} = MapLedger.begin_migration(ledger, 80, 900, owner_epoch: 2)
    migration_id = plan.migration_id

    stop_supervised!(:migration_ledger)

    revived = start_supervised!({MapLedger, persistence_path: path}, id: :revived_migration)
    snapshot = MapLedger.snapshot(revived)
    assert Map.has_key?(snapshot.migrations, migration_id)

    revived_plan = snapshot.migrations[migration_id]
    assert revived_plan.target_scene_instance_ref == 900
    assert revived_plan.state == :prewarming
  end
end
