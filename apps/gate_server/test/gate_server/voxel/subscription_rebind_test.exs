defmodule GateServer.Voxel.SubscriptionRebindTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.SubscriptionRebind

  test "rebinds the subscription targeted by a migration-cutover invalidate" do
    parent = self()

    state =
      subscription({0, 0, 0})
      |> state()
      |> Map.put(:partition_context, %{
        logical_scene_id: 1,
        region_id: 10,
        chunk_coord: {0, 0, 0},
        lease_id: 100,
        owner_scene_instance_ref: 1_000,
        owner_epoch: 1,
        assigned_scene_node: :scene_a
      })

    event = %{
      reason_name: :migration_cutover,
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0}
    }

    assert {:ok, next_state, summary} =
             SubscriptionRebind.apply_cutover_invalidation(state, event,
               route_fun: route_fun(:scene_b, lease(10, 101, 2_000, 2)),
               scene_call_fun: scene_call_fun(parent),
               observe_fun: observe_fun(parent),
               subscriber: self()
             )

    assert summary.status == :rebound
    assert summary.rebound_count == 1

    assert %{
             scene_node: :scene_b,
             lease_id: 101,
             owner_scene_instance_ref: 2_000,
             owner_epoch: 2,
             tier: :near
           } = next_state.voxel_subscriptions[{1, {0, 0, 0}}]

    assert %{
             logical_scene_id: 1,
             region_id: 10,
             chunk_coord: {0, 0, 0},
             lease_id: 101,
             owner_scene_instance_ref: 2_000,
             owner_epoch: 2,
             assigned_scene_node: :scene_b,
             boundary_kind: :authority_cutover
           } = next_state.partition_context

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_b},
                    {:subscribe,
                     %{
                       chunk_coord: {0, 0, 0},
                       delivery_format: :envelope,
                       tier: :near,
                       lease: %{lease_id: 101}
                     }}, _timeout}

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:unsubscribe, %{chunk_coord: {0, 0, 0}}}, _timeout}

    assert_receive {:observe, "voxel_subscription_rebind_requested",
                    %{reason: :migration_cutover_invalidate}}

    assert_receive {:observe, "voxel_subscription_rebind_completed",
                    %{rebound_count: 1, error_count: 0}}
  end

  test "skips non-migration invalidates without routing to World" do
    event = %{reason_name: :manual, logical_scene_id: 1, chunk_coord: {0, 0, 0}}

    assert {:ok, next_state, summary} =
             SubscriptionRebind.apply_cutover_invalidation(state(subscription({0, 0, 0})), event)

    assert summary.status == :skipped
    assert summary.reason == {:not_migration_cutover, :manual}
    assert next_state.voxel_subscriptions[{1, {0, 0, 0}}].lease_id == 100
  end

  test "skips migration invalidates for chunks this connection does not subscribe to" do
    parent = self()
    state = state(subscription({1, 0, 0}))

    event = %{
      reason_name: :migration_cutover,
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0}
    }

    assert {:ok, ^state, summary} =
             SubscriptionRebind.apply_cutover_invalidation(state, event,
               observe_fun: observe_fun(parent)
             )

    assert summary.status == :skipped
    assert summary.reason == :subscription_not_found

    assert_receive {:observe, "voxel_subscription_rebind_skipped",
                    %{reason: :subscription_not_found}}
  end

  test "failed rebind removes the invalidated active subscription and records pending recovery" do
    parent = self()
    state = state(subscription({0, 0, 0}))

    event = %{
      reason_name: :migration_cutover,
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0}
    }

    assert {:error, next_state, summary} =
             SubscriptionRebind.apply_cutover_invalidation(state, event,
               route_fun: route_fun(:scene_b, lease(10, 101, 2_000, 2)),
               scene_call_fun: fn _server, _message, _timeout -> {:ok, {:error, :scene_down}} end,
               observe_fun: observe_fun(parent),
               subscriber: self()
             )

    key = {1, {0, 0, 0}}
    refute Map.has_key?(next_state.voxel_subscriptions, key)
    assert summary.status == :failed
    assert summary.reason == :scene_down
    assert summary.invalidated_subscription_count == 1

    assert %{
             reason: :scene_down,
             rebind_reason: :migration_cutover_invalidate,
             old_lease_id: 100,
             old_owner_scene_instance_ref: 1_000,
             retry_count: 0
           } = next_state.voxel_subscription_rebind_pending[key]

    assert_receive {:observe, "voxel_subscription_rebind_error",
                    %{active_subscription_removed?: true, reason: :scene_down}}

    assert_receive {:observe, "voxel_subscription_rebind_completed",
                    %{rebound_count: 0, error_count: 1, invalidated_subscription_count: 1}}
  end

  test "manual rebind retries pending cutover recovery after Scene returns" do
    parent = self()
    state = state(subscription({0, 0, 0}))

    event = %{
      reason_name: :migration_cutover,
      logical_scene_id: 1,
      chunk_coord: {0, 0, 0}
    }

    assert {:error, failed_state, %{pending_rebind_count: 1}} =
             SubscriptionRebind.apply_cutover_invalidation(state, event,
               route_fun: route_fun(:scene_b, lease(10, 101, 2_000, 2)),
               scene_call_fun: fn _server, _message, _timeout -> {:ok, {:error, :scene_down}} end,
               observe_fun: observe_fun(parent),
               subscriber: self()
             )

    assert {:ok, recovered_state, summary} =
             SubscriptionRebind.rebind_selected_subscriptions(failed_state, 1, :all, :manual,
               route_fun: route_fun(:scene_b, lease(10, 101, 2_000, 2)),
               scene_call_fun: scene_call_fun(parent),
               observe_fun: observe_fun(parent),
               subscriber: self()
             )

    key = {1, {0, 0, 0}}
    assert summary.status == :rebound
    assert summary.rebound_count == 1
    assert summary.pending_rebind_count == 0
    assert recovered_state.voxel_subscription_rebind_pending == %{}

    assert %{
             scene_node: :scene_b,
             lease_id: 101,
             owner_scene_instance_ref: 2_000,
             owner_epoch: 2,
             tier: :near
           } = recovered_state.voxel_subscriptions[key]

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_b},
                    {:subscribe,
                     %{
                       chunk_coord: {0, 0, 0},
                       delivery_format: :envelope,
                       tier: :near,
                       lease: %{lease_id: 101}
                     }}, _timeout}
  end

  defp state(subscription) do
    %{
      cid: 42,
      voxel_subscriptions: %{
        {subscription.logical_scene_id, subscription.chunk_coord} => subscription
      }
    }
  end

  defp subscription(chunk_coord) do
    %{
      logical_scene_id: 1,
      chunk_coord: chunk_coord,
      request_id: 77,
      scene_node: :scene_a,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      tier: :near
    }
  end

  defp route_fun(scene_node, lease) do
    fn 1, {0, 0, 0} ->
      {:ok, %{assignment: %{assigned_scene_node: scene_node}, lease: lease}}
    end
  end

  defp lease(region_id, lease_id, owner_ref, owner_epoch) do
    %{
      logical_scene_id: 1,
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: owner_ref,
      owner_epoch: owner_epoch,
      expires_at_ms: 9_999
    }
  end

  defp scene_call_fun(parent) do
    fn server, message, timeout ->
      send(parent, {:scene_call, server, message, timeout})
      {:ok, {:ok, %{}}}
    end
  end

  defp observe_fun(parent) do
    fn event, payload ->
      send(parent, {:observe, event, payload})
      :ok
    end
  end
end
