defmodule SceneServer.Voxel.RegionRuntimeTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.RegionRuntime

  test "accepts current boundary events and rejects events after target lease migration" do
    runtime = start_supervised!(RegionRuntime)

    source_lease = lease(10, 100, 1_000, 1)
    target_lease_v1 = lease(20, 200, 2_000, 3)
    target_lease_v2 = lease(20, 201, 3_000, 4)

    assert {:ok, _lease} = RegionRuntime.cache_neighbor_lease(runtime, source_lease)
    assert {:ok, _lease} = RegionRuntime.apply_lease(runtime, target_lease_v1)

    event = boundary_event(source_lease, target_lease_v1, 900)

    assert {:ok, :accepted} = RegionRuntime.accept_boundary_event(runtime, event)
    assert {:ok, :duplicate} = RegionRuntime.accept_boundary_event(runtime, event)

    assert {:ok, _lease} = RegionRuntime.apply_lease(runtime, target_lease_v2)

    stale_event = boundary_event(source_lease, target_lease_v1, 901)

    assert {:error, :target_lease_mismatch} =
             RegionRuntime.accept_boundary_event(runtime, stale_event)
  end

  test "rejects boundary events when source lease cache is stale" do
    runtime = start_supervised!(RegionRuntime)

    source_lease_v1 = lease(10, 100, 1_000, 1)
    source_lease_v2 = lease(10, 101, 1_000, 2)
    target_lease = lease(20, 200, 2_000, 3)

    assert {:ok, _lease} = RegionRuntime.cache_neighbor_lease(runtime, source_lease_v2)
    assert {:ok, _lease} = RegionRuntime.apply_lease(runtime, target_lease)

    assert {:error, :source_lease_mismatch} =
             RegionRuntime.accept_boundary_event(
               runtime,
               boundary_event(source_lease_v1, target_lease, 902)
             )
  end

  defp lease(region_id, lease_id, owner_ref, owner_epoch) do
    %{
      logical_scene_id: 1,
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: owner_ref,
      owner_epoch: owner_epoch,
      bounds_chunk_min: {region_id, 0, 0},
      bounds_chunk_max: {region_id + 1, 1, 1},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }
  end

  defp boundary_event(source_lease, target_lease, event_id) do
    %{
      event_id: event_id,
      logical_scene_id: 1,
      source_region_id: source_lease.region_id,
      target_region_id: target_lease.region_id,
      source_lease_id: source_lease.lease_id,
      target_lease_id: target_lease.lease_id,
      source_scene_instance_ref: source_lease.owner_scene_instance_ref,
      target_scene_instance_ref: target_lease.owner_scene_instance_ref,
      source_owner_epoch: source_lease.owner_epoch,
      target_owner_epoch: target_lease.owner_epoch,
      boundary_chunks: [{20, 0, 0}],
      event_kind: :burning,
      payload_hash: 12_345,
      payload: <<1, 2, 3>>
    }
  end
end
