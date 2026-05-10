defmodule SceneServer.Voxel.RegionRuntimeTest do
  # async: false because the cluster-routing tests boot the singleton
  # `BeaconServer.DistributedRegistry` Horde registry and exercise
  # process-exit reaping, which can race with other concurrent tests
  # touching the same registry.
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{RegionRouting, RegionRuntime}

  # `BeaconServer.DistributedRegistry` is started in
  # `apps/scene_server/test/test_helper.exs` for all scene_server tests.
  setup do
    on_exit(fn -> RegionRouting.__clear_stub__() end)
    :ok
  end

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

  describe "cluster region routing (Phase A4-bis-3)" do
    test "apply_lease registers the local node in BeaconServer for the region" do
      region_id = unique_region_id()
      runtime = start_supervised!(RegionRuntime)

      # Sanity: not registered yet.
      assert :error = RegionRouting.resolve_scene_node(region_id, nil)

      assert {:ok, _} = RegionRuntime.apply_lease(runtime, lease(region_id, 100, 1_000, 1))

      # Horde CRDT propagation: register/3 returns immediately but the
      # `lookup` ETS may take a few ms to converge.
      local_node = node()
      assert {:ok, ^local_node} = await_resolve_to(region_id, {:ok, local_node}, 500)
    end

    test "applying the same region twice (lease upgrade) is idempotent" do
      region_id = unique_region_id()
      runtime = start_supervised!(RegionRuntime)

      assert {:ok, _} = RegionRuntime.apply_lease(runtime, lease(region_id, 100, 1_000, 1))
      # Second apply (e.g. lease epoch bump) must not return error or
      # crash the process; BeaconServer's `:already_registered` is
      # treated as `:ok` by the client.
      assert {:ok, _} = RegionRuntime.apply_lease(runtime, lease(region_id, 101, 1_000, 2))
      assert {:ok, _node} = await_resolve_to(region_id, {:ok, node()}, 500)
    end

    test "RegionRuntime exit clears its BeaconServer entries (Horde reaping)" do
      region_id = unique_region_id()
      runtime = start_supervised!(RegionRuntime)
      ref = Process.monitor(runtime)

      assert {:ok, _} = RegionRuntime.apply_lease(runtime, lease(region_id, 100, 1_000, 1))
      assert {:ok, _node} = await_resolve_to(region_id, {:ok, node()}, 500)

      :ok = stop_supervised!(RegionRuntime)
      assert_receive {:DOWN, ^ref, :process, ^runtime, _reason}, 1_000

      # Horde reaps registry entries on owner exit. Allow a brief
      # window for the CRDT to converge.
      assert :error = await_resolve_to(region_id, :error, 500)
    end
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

  # Use a high integer so we don't collide with the legacy
  # boundary-event tests above (which hard-code region 10/20).
  defp unique_region_id, do: 1_000 + System.unique_integer([:positive, :monotonic])

  # Horde's CRDT is eventually consistent; poll until the resolver
  # matches `expected` or the deadline elapses. Returns the most
  # recently observed value (may be `:error` after a successful
  # propagation, or `{:ok, node}` after an unexpected race).
  defp await_resolve_to(region_id, expected, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    poll = fn poll ->
      observed =
        case RegionRouting.resolve_scene_node(region_id, nil) do
          :error -> :error
          {:ok, _} = ok -> ok
        end

      cond do
        observed == expected ->
          observed

        System.monotonic_time(:millisecond) >= deadline ->
          observed

        true ->
          Process.sleep(10)
          poll.(poll)
      end
    end

    poll.(poll)
  end
end
