defmodule GateServer.Voxel.SubscriptionRuntimeTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.ChunkVersionLedger
  alias GateServer.Voxel.SubscriptionRuntime

  test "applies subscribe entries, stores handles, and emits an apply summary" do
    parent = self()
    plan = plan([{1, 0, 0}, {1, 0, 1}], skipped: [{2, 0, 0}])

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state(), plan,
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent),
               observe_fun: observe_fun(parent)
             )

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:subscribe,
                     %{
                       chunk_coord: {1, 0, 0},
                       send_snapshot?: true,
                       delivery_format: :envelope,
                       tier: :near
                     }}, 15_000}

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:subscribe,
                     %{
                       chunk_coord: {1, 0, 1},
                       send_snapshot?: true,
                       delivery_format: :envelope,
                       tier: :near
                     }}, 15_000}

    refute_received {:scene_call, _server, {:subscribe, %{chunk_coord: {2, 0, 0}}}, _timeout}

    assert summary.status == :applied
    assert summary.subscribe_count == 2
    assert summary.unsubscribe_count == 0
    assert summary.retained_count == 0
    assert summary.skipped_count == 1
    assert next_state.voxel_subscription_plan == plan.summary

    assert %{
             logical_scene_id: 1,
             chunk_coord: {1, 0, 0},
             request_id: 77,
             scene_node: :scene_a,
             region_id: 10,
             lease_id: 100,
             owner_scene_instance_ref: 1_000,
             owner_epoch: 1
           } = next_state.voxel_subscriptions[{1, {1, 0, 0}}]

    assert_receive {:observe, "voxel_subscription_diff_applied",
                    %{cid: 42, subscribe_count: 2, unsubscribe_count: 0, skipped_count: 1}}
  end

  test "applies halo ghost subscriptions without requesting an initial Scene snapshot" do
    parent = self()

    plan =
      plan([{1, 0, 0}, {1, 0, 1}],
        entry_overrides: %{
          {1, 0, 1} => %{
            tier: :halo,
            priority: :opportunistic,
            send_snapshot?: false,
            initial_delivery_mode: :halo_ghost,
            snapshot_defer_reason: :snapshot_budget_exhausted
          }
        }
      )

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state(), plan,
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent),
               observe_fun: observe_fun(parent)
             )

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:subscribe,
                     %{
                       chunk_coord: {1, 0, 0},
                       send_snapshot?: true,
                       delivery_format: :envelope,
                       tier: :near
                     }}, 15_000}

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:subscribe,
                     %{
                       chunk_coord: {1, 0, 1},
                       send_snapshot?: false,
                       delivery_format: :envelope,
                       tier: :halo
                     }}, 15_000}

    assert next_state.voxel_subscriptions[{1, {1, 0, 1}}].tier == :halo
    assert next_state.voxel_subscriptions[{1, {1, 0, 1}}].initial_delivery_mode == :halo_ghost
    assert next_state.voxel_subscriptions[{1, {1, 0, 1}}].send_snapshot? == false

    assert summary.initial_snapshot_count == 1
    assert summary.ghost_subscription_count == 1

    assert_receive {:observe, "voxel_subscription_diff_applied",
                    %{initial_snapshot_count: 1, ghost_subscription_count: 1}}
  end

  test "promotes a retained halo ghost subscription to near and requests an authoritative snapshot" do
    parent = self()
    existing_ghost = Map.merge(subscription({1, 0, 0}), %{tier: :halo, send_snapshot?: false})

    plan =
      plan([{1, 0, 0}],
        entry_overrides: %{
          {1, 0, 0} => %{
            tier: :near,
            priority: :critical,
            send_snapshot?: true,
            initial_delivery_mode: :authoritative_snapshot,
            snapshot_defer_reason: nil
          }
        }
      )

    state =
      state(%{
        voxel_subscriptions: %{
          {1, {1, 0, 0}} => existing_ghost
        }
      })

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state, plan,
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent),
               observe_fun: observe_fun(parent)
             )

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:subscribe, %{chunk_coord: {1, 0, 0}, send_snapshot?: true}}, 15_000}

    promoted = next_state.voxel_subscriptions[{1, {1, 0, 0}}]
    assert promoted.tier == :near
    assert promoted.send_snapshot? == true
    assert promoted.initial_delivery_mode == :authoritative_snapshot

    assert summary.subscribe_count == 0
    assert summary.retained_count == 1
    assert summary.promoted_count == 1
    assert summary.promotion_snapshot_count == 1

    assert_receive {:observe, "voxel_subscription_diff_applied",
                    %{promoted_count: 1, promotion_snapshot_count: 1}}
  end

  test "refreshes retained Scene delivery metadata when tier changes without snapshot replay" do
    parent = self()
    existing_near = Map.merge(subscription({1, 0, 0}), %{tier: :near, send_snapshot?: false})

    plan =
      plan([{1, 0, 0}],
        entry_overrides: %{
          {1, 0, 0} => %{
            tier: :halo,
            priority: :opportunistic,
            send_snapshot?: false,
            initial_delivery_mode: :halo_ghost,
            snapshot_defer_reason: :snapshot_budget_exhausted
          }
        }
      )

    state =
      state(%{
        voxel_subscriptions: %{
          {1, {1, 0, 0}} => existing_near
        }
      })

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state, plan,
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent),
               observe_fun: observe_fun(parent)
             )

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:subscribe,
                     %{
                       chunk_coord: {1, 0, 0},
                       send_snapshot?: false,
                       delivery_format: :envelope,
                       tier: :halo
                     }}, 15_000}

    refreshed = next_state.voxel_subscriptions[{1, {1, 0, 0}}]
    assert refreshed.tier == :halo
    assert refreshed.send_snapshot? == false
    assert refreshed.initial_delivery_mode == :halo_ghost

    assert summary.subscribe_count == 0
    assert summary.retained_count == 1
    assert summary.promoted_count == 1
    assert summary.promotion_snapshot_count == 0

    assert_receive {:observe, "voxel_subscription_diff_applied",
                    %{promoted_count: 1, promotion_snapshot_count: 0}}
  end

  test "unsubscribes chunks absent from the target plan while retaining existing subscriptions" do
    parent = self()
    retained = subscription({1, 0, 0})
    removed = subscription({0, 0, 0})
    other_scene = Map.put(subscription({9, 0, 0}), :logical_scene_id, 2)

    state =
      state(%{
        voxel_subscriptions: %{
          {1, {1, 0, 0}} => retained,
          {1, {0, 0, 0}} => removed,
          {2, {9, 0, 0}} => other_scene
        }
      })

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state, plan([{1, 0, 0}]),
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent)
             )

    assert_receive {:scene_call, {SceneServer.Voxel.ChunkDirectory, :scene_a},
                    {:unsubscribe, %{logical_scene_id: 1, chunk_coord: {0, 0, 0}}}, 15_000}

    refute_received {:scene_call, _server, {:subscribe, _attrs}, _timeout}
    refute Map.has_key?(next_state.voxel_subscriptions, {1, {0, 0, 0}})
    assert next_state.voxel_subscriptions[{1, {1, 0, 0}}] == retained
    assert next_state.voxel_subscriptions[{2, {9, 0, 0}}] == other_scene
    assert summary.subscribe_count == 0
    assert summary.unsubscribe_count == 1
    assert summary.retained_count == 1
  end

  test "prunes forwarded chunk versions for dropped subscriptions after replace diffs" do
    parent = self()
    retained = subscription({1, 0, 0})
    removed = subscription({0, 0, 0})
    other_scene = Map.put(subscription({9, 0, 0}), :logical_scene_id, 2)

    state =
      state(%{
        voxel_subscriptions: %{
          {1, {1, 0, 0}} => retained,
          {1, {0, 0, 0}} => removed,
          {2, {9, 0, 0}} => other_scene
        },
        forwarded_chunk_versions:
          ChunkVersionLedger.new()
          |> ChunkVersionLedger.record_version!(1, {1, 0, 0}, 7)
          |> ChunkVersionLedger.record_version!(1, {0, 0, 0}, 8)
          |> ChunkVersionLedger.record_version!(2, {9, 0, 0}, 3)
      })

    assert {:ok, next_state, _summary} =
             SubscriptionRuntime.apply_plan(state, plan([{1, 0, 0}]),
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent)
             )

    assert ChunkVersionLedger.to_sorted_list(next_state.forwarded_chunk_versions) == [
             {1, {1, 0, 0}, 7},
             {2, {9, 0, 0}, 3}
           ]
  end

  test "additive diff mode preserves existing subscriptions outside the target plan" do
    parent = self()
    existing = subscription({0, 0, 0})

    state =
      state(%{
        voxel_subscriptions: %{
          {1, {0, 0, 0}} => existing
        }
      })

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state, plan([{1, 0, 0}]),
               subscriber: self(),
               scene_call_fun: scene_call_fun(parent),
               diff_mode: :additive
             )

    assert_receive {:scene_call, _server, {:subscribe, %{chunk_coord: {1, 0, 0}}}, _timeout}
    refute_received {:scene_call, _server, {:unsubscribe, %{chunk_coord: {0, 0, 0}}}, _timeout}

    assert next_state.voxel_subscriptions[{1, {0, 0, 0}}] == existing
    assert Map.has_key?(next_state.voxel_subscriptions, {1, {1, 0, 0}})
    assert summary.subscribe_count == 1
    assert summary.unsubscribe_count == 0
    assert summary.retained_count == 0
  end

  test "rolls back newly subscribed chunks when a later subscribe fails" do
    parent = self()
    existing = subscription({0, 0, 0})
    original_state = state(%{voxel_subscriptions: %{{1, {0, 0, 0}} => existing}})

    scene_call_fun = fn
      {SceneServer.Voxel.ChunkDirectory, :scene_a} = server,
      {:subscribe, %{chunk_coord: {1, 0, 0}}} = message,
      timeout ->
        send(parent, {:scene_call, server, message, timeout})
        {:ok, {:ok, %{}}}

      {SceneServer.Voxel.ChunkDirectory, :scene_a} = server,
      {:subscribe, %{chunk_coord: {2, 0, 0}}} = message,
      timeout ->
        send(parent, {:scene_call, server, message, timeout})
        {:ok, {:error, :scene_rejected}}

      {SceneServer.Voxel.ChunkDirectory, :scene_a} = server,
      {:unsubscribe, %{chunk_coord: {1, 0, 0}}} = message,
      timeout ->
        send(parent, {:rollback_call, server, message, timeout})
        {:ok, :ok}
    end

    assert {:error, next_state, summary} =
             SubscriptionRuntime.apply_plan(original_state, plan([{1, 0, 0}, {2, 0, 0}]),
               subscriber: self(),
               scene_call_fun: scene_call_fun,
               observe_fun: observe_fun(parent)
             )

    assert_receive {:scene_call, _server, {:subscribe, %{chunk_coord: {1, 0, 0}}}, _timeout}
    assert_receive {:scene_call, _server, {:subscribe, %{chunk_coord: {2, 0, 0}}}, _timeout}
    assert_receive {:rollback_call, _server, {:unsubscribe, %{chunk_coord: {1, 0, 0}}}, _timeout}

    assert next_state.voxel_subscriptions == original_state.voxel_subscriptions
    assert summary.status == :failed
    assert summary.reason == :scene_rejected

    assert_receive {:observe, "voxel_subscription_diff_failed",
                    %{cid: 42, reason: :scene_rejected, subscribe_count: 1}}
  end

  test "does not call Scene for skipped entries" do
    parent = self()
    plan = plan([], skipped: [{7, 0, 0}])

    assert {:ok, next_state, summary} =
             SubscriptionRuntime.apply_plan(state(), plan,
               scene_call_fun: fn server, message, timeout ->
                 send(parent, {:unexpected_scene_call, server, message, timeout})
                 {:ok, {:ok, %{}}}
               end
             )

    assert next_state.voxel_subscriptions == %{}
    assert summary.status == :applied
    assert summary.subscribe_count == 0
    assert summary.unsubscribe_count == 0
    assert summary.retained_count == 0
    assert summary.skipped_count == 1
    refute_received {:unexpected_scene_call, _server, _message, _timeout}
  end

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        cid: 42,
        voxel_subscriptions: %{},
        voxel_subscription_plan: nil
      },
      overrides
    )
  end

  defp plan(chunks, opts \\ []) do
    skipped = Keyword.get(opts, :skipped, [])
    entry_overrides = Keyword.get(opts, :entry_overrides, %{})

    entries =
      Enum.map(chunks, fn chunk_coord ->
        Map.merge(entry(chunk_coord), Map.get(entry_overrides, chunk_coord, %{}))
      end)

    %{
      cid: 42,
      request_id: 77,
      subscribe_entries: entries,
      skipped_entries: Enum.map(skipped, &skipped_entry/1),
      summary: %{
        cid: 42,
        request_id: 77,
        logical_scene_id: 1,
        center_chunk: List.first(chunks) || List.first(skipped) || {0, 0, 0},
        pressure: :nominal,
        requested_chunk_count: length(chunks) + length(skipped),
        subscribe_count: length(chunks),
        skipped_count: length(skipped),
        missing_chunk_count: 0,
        unleased_chunk_count: 0
      }
    }
  end

  defp entry(chunk_coord) do
    %{
      chunk_coord: chunk_coord,
      tier: :near,
      priority: 0,
      region_id: 10,
      lease_id: 100,
      lease: lease(10, 100),
      assigned_scene_node: :scene_a,
      known_version_for_scene: nil,
      budget_bytes: 128,
      send_snapshot?: true,
      initial_delivery_mode: :authoritative_snapshot,
      snapshot_defer_reason: nil,
      reason: :near
    }
  end

  defp skipped_entry(chunk_coord) do
    %{
      chunk_coord: chunk_coord,
      tier: :halo,
      priority: 1,
      status: :missing_route,
      reason: :missing_route,
      region_id: nil,
      lease_id: nil
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
      owner_epoch: 1
    }
  end

  defp lease(region_id, lease_id) do
    %{
      logical_scene_id: 1,
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
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
