defmodule WorldServer.Voxel.DevSeedTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.DevSeed
  alias WorldServer.Voxel.MapLedger

  test "creates an idempotent browser dev region and publishes its lease" do
    token_store = start_supervised!(WriteTokenStore)
    ledger_name = :"dev_seed_ledger_#{System.unique_integer([:positive])}"
    ledger = start_supervised!({MapLedger, name: ledger_name, write_token_store: token_store})

    assert {:ok, created} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 88,
               region_id: 880_001,
               center_chunk: {0, 0, 0}
             )

    assert created.status == :created
    assert created.logical_scene_id == 88
    assert created.region_id == 880_001
    assert created.bounds_chunk_min == [-2, -2, -2]
    assert created.bounds_chunk_max == [3, 3, 3]

    assert {:ok, route} = MapLedger.route_chunk_with_lease(ledger, 88, {0, 0, 0})
    assert route.assignment.region_id == 880_001
    assert route.lease.lease_id == created.lease_id

    assert {:ok, renewed} =
             DevSeed.ensure_default_region(
               ledger: ledger,
               logical_scene_id: 88,
               region_id: 880_001,
               center_chunk: {0, 0, 0}
             )

    assert renewed.status == :renewed
    assert renewed.lease_id != created.lease_id
    assert renewed.owner_epoch > created.owner_epoch

    assert {:ok, renewed_route} = MapLedger.route_chunk_with_lease(ledger, 88, {0, 0, 0})
    assert renewed_route.lease.lease_id == renewed.lease_id
  end
end
