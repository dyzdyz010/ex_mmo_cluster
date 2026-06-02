defmodule GateServer.PartitionRuntimeTest do
  use ExUnit.Case, async: false

  alias GateServer.PartitionRuntime
  alias GateServer.Voxel.ClientAckLedger
  alias GateServer.Voxel.ChunkVersionLedger
  alias GateServer.Voxel.DeliveryScheduler
  alias SceneServer.Movement.Ack
  alias WorldServer.Voxel.PartitionWindow

  test "same chunk movement does not call World or Chat" do
    parent = self()

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        last_partition_refresh: %{status: :failed, reason: :previous_failure}
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(state, ack(position: {100.0, 50.0, 0.0}),
               route_window_fun: fn _logical_scene_id, _chunk_coord, _radius ->
                 send(parent, :unexpected_world_call)
                 {:error, :unexpected_world_call}
               end,
               chat_refresh_fun: fn _presence ->
                 send(parent, :unexpected_chat_call)
                 {:error, :unexpected_chat_call}
               end
             )

    assert outcome.status == :unchanged
    assert outcome.boundary_kind == :none
    assert next_state.partition_context == state.partition_context
    assert next_state.chat_context == state.chat_context
    assert next_state.last_partition_refresh.status == :unchanged
    assert next_state.last_partition_refresh.auth_tick == 123
    refute_received :unexpected_world_call
    refute_received :unexpected_chat_call
  end

  test "region boundary movement refreshes partition context and Chat presence from World route" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease),
        {0, 0, 0} => assigned_route(10, lease(10, 100))
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        voxel_subscriptions: %{
          {1, {0, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {0, 0, 0}}
        }
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 321),
               partition_radius: 1,
               route_window_fun: fn logical_scene_id, center_chunk, radius ->
                 send(parent, {:world_window_requested, logical_scene_id, center_chunk, radius})
                 {:ok, window}
               end,
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_presence_refreshed, presence})
                 {:ok, Map.put(presence, :username, "hero")}
               end,
               subscription_apply_fun: &subscription_apply_ok/2,
               observe_fun: fn event, payload ->
                 send(parent, {:observe, event, payload})
                 :ok
               end
             )

    assert_receive {:world_window_requested, 1, {1, 0, 0}, 1}

    assert_receive {:chat_presence_refreshed,
                    %{
                      cid: 42,
                      logical_scene_id: 1,
                      region_id: 20,
                      chunk_coord: {1, 0, 0}
                    }}

    assert_receive {:observe, "gate_partition_runtime_refreshed",
                    %{cid: 42, boundary_kind: :region, region_id: 20}}

    assert outcome.status == :updated
    assert outcome.boundary_kind == :region
    assert outcome.region_id == 20
    assert outcome.subscription_diff.retained_chunks == [{0, 0, 0}]
    assert {1, 0, 0} in outcome.subscription_diff.subscribe_chunks

    assert next_state.partition_context.region_id == 20
    assert next_state.partition_context.chunk_coord == {1, 0, 0}
    assert next_state.partition_context.candidate_region_ids == [10, 20]
    assert next_state.partition_context.candidate_region_radius == 1
    assert next_state.partition_context.auth_tick == 321
    assert next_state.chat_context.region_id == 20
    assert next_state.chat_context.chunk_coord == {1, 0, 0}
    assert next_state.voxel_subscription_plan.region_id == 20
    assert next_state.last_partition_refresh.status == :updated
  end

  test "movement ack positions are converted to voxel Y-up chunks before partition routing" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {-5, 0, 5}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {-5, 0, 5} => assigned_route(20, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {-4, 0, 4}, region_id: 20},
        chat_context: %{logical_scene_id: 1, chunk_coord: {-4, 0, 4}, region_id: 20},
        voxel_subscriptions: %{
          {1, {-4, 0, 4}} => %{logical_scene_id: 1, chunk_coord: {-4, 0, 4}}
        }
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {-6_500.0, 8_100.0, 185.0}, auth_tick: 900),
               route_window_fun: fn logical_scene_id, center_chunk, radius ->
                 send(parent, {:world_window_requested, logical_scene_id, center_chunk, radius})
                 {:ok, window}
               end,
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_presence_refreshed, presence})
                 {:ok, presence}
               end,
               subscription_apply_fun: &subscription_apply_ok/2
             )

    assert_receive {:world_window_requested, 1, {-5, 0, 5}, 1}
    assert_receive {:chat_presence_refreshed, %{chunk_coord: {-5, 0, 5}}}

    assert outcome.status == :updated
    assert next_state.partition_context.chunk_coord == {-5, 0, 5}
    assert next_state.chat_context.chunk_coord == {-5, 0, 5}
  end

  test "region boundary movement applies the subscription plan after Chat presence succeeds" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        voxel_subscriptions: %{
          {1, {0, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {0, 0, 0}}
        }
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 800),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_presence_refreshed, presence})
                 {:ok, presence}
               end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(parent, {:subscription_applied, partition_result.chunk_coord})

                 {:ok,
                  Map.put(current_state, :voxel_subscriptions, %{
                    {1, {1, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {1, 0, 0}}
                  }),
                  %{status: :applied, subscribe_count: 1, unsubscribe_count: 0, retained_count: 0}}
               end
             )

    assert_receive {:chat_presence_refreshed, %{chunk_coord: {1, 0, 0}}}
    assert_receive {:subscription_applied, {1, 0, 0}}

    assert next_state.voxel_subscriptions == %{
             {1, {1, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {1, 0, 0}}
           }

    assert outcome.subscription_apply_status == :ok
    assert next_state.last_partition_refresh.subscription_apply_status == :ok
  end

  test "region boundary subscription plan does not reuse forwarded-only chunk versions" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        forwarded_chunk_versions:
          ChunkVersionLedger.new()
          |> ChunkVersionLedger.record_version!(1, {1, 0, 0}, 9)
      })

    assert {:ok, _next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 802),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(parent, {:subscription_plan, partition_result.subscription_plan})

                 {:ok, current_state,
                  %{status: :applied, subscribe_count: 1, unsubscribe_count: 0, retained_count: 0}}
               end
             )

    assert_receive {:subscription_plan, plan}
    assert [%{chunk_coord: {1, 0, 0}, known_version_for_scene: nil}] = plan.subscribe_entries
    assert outcome.subscription_apply_status == :ok
  end

  test "region boundary subscription plan reuses client-acked chunk versions" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(1, {1, 0, 0}, 9)

    {:ok, client_ack_versions, _event} =
      ClientAckLedger.record_ack(ClientAckLedger.new(), forwarded, 1, {1, 0, 0}, 9)

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        forwarded_chunk_versions: forwarded,
        client_ack_versions: client_ack_versions
      })

    assert {:ok, _next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 802),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(parent, {:subscription_plan, partition_result.subscription_plan})

                 {:ok, current_state,
                  %{status: :applied, subscribe_count: 1, unsubscribe_count: 0, retained_count: 0}}
               end
             )

    assert_receive {:subscription_plan, plan}
    assert [%{chunk_coord: {1, 0, 0}, known_version_for_scene: 9}] = plan.subscribe_entries
    assert outcome.subscription_apply_status == :ok
  end

  test "region boundary subscription plan ignores acked versions marked for resync" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(1, {1, 0, 0}, 9)

    {:ok, client_ack_versions, _event} =
      ClientAckLedger.record_ack(ClientAckLedger.new(), forwarded, 1, {1, 0, 0}, 9)

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        forwarded_chunk_versions: forwarded,
        client_ack_versions: client_ack_versions,
        voxel_delivery: %DeliveryScheduler{
          resync_required_chunks: MapSet.new([{1, {1, 0, 0}}])
        }
      })

    assert {:ok, _next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 802),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(parent, {:subscription_plan, partition_result.subscription_plan})

                 {:ok, current_state,
                  %{status: :applied, subscribe_count: 1, unsubscribe_count: 0, retained_count: 0}}
               end
             )

    assert_receive {:subscription_plan, plan}
    assert [%{chunk_coord: {1, 0, 0}, known_version_for_scene: nil}] = plan.subscribe_entries
    assert outcome.subscription_apply_status == :ok
  end

  test "movement refresh carries stream budget so halo chunks become ghost prewarm subscriptions" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease),
        {0, 0, 0} => assigned_route(10, lease(10, 100))
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        voxel_stream_caps: %{
          reliable_control: 128,
          voxel_snapshot: 128,
          voxel_delta: 0,
          field_state: 0,
          recovery: 0
        },
        voxel_snapshot_estimate_bytes: 128
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 803),
               partition_radius: 1,
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(parent, {:subscription_plan, partition_result.subscription_plan})

                 {:ok,
                  Map.put(
                    current_state,
                    :voxel_subscription_plan,
                    partition_result.subscription_plan.summary
                  ),
                  %{
                    status: :applied,
                    subscribe_count: length(partition_result.subscription_diff.subscribe_chunks),
                    unsubscribe_count: 0,
                    retained_count: 0,
                    initial_snapshot_count:
                      partition_result.subscription_plan.summary.initial_snapshot_count,
                    ghost_subscription_count:
                      partition_result.subscription_plan.summary.ghost_subscription_count
                  }}
               end
             )

    assert_receive {:subscription_plan, plan}
    near = Enum.find(plan.subscribe_entries, &(&1.chunk_coord == {1, 0, 0}))
    halo = Enum.find(plan.subscribe_entries, &(&1.chunk_coord == {0, 0, 0}))

    assert near.send_snapshot? == true
    assert halo.send_snapshot? == false
    assert halo.initial_delivery_mode == :halo_ghost
    assert next_state.voxel_subscription_plan.ghost_subscription_count == 1
    assert outcome.subscription_apply_status == :ok
  end

  test "subscription apply failure preserves movement and chat context but records the sync failure" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        voxel_subscriptions: %{
          {1, {0, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {0, 0, 0}}
        }
      })

    assert {:error, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 801),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(parent, {:subscription_apply_failed, partition_result.chunk_coord})

                 {:error, current_state,
                  %{
                    status: :failed,
                    reason: :scene_unavailable,
                    subscribe_count: 0,
                    unsubscribe_count: 0,
                    retained_count: 0
                  }}
               end,
               observe_fun: fn event, payload ->
                 send(parent, {:observe, event, payload})
                 :ok
               end
             )

    assert_receive {:subscription_apply_failed, {1, 0, 0}}

    assert_receive {:observe, "gate_partition_runtime_subscription_apply_failed",
                    %{cid: 42, subscription_apply_status: {:error, :scene_unavailable}}}

    assert outcome.status == :updated
    assert outcome.subscription_apply_status == {:error, :scene_unavailable}
    assert next_state.partition_context.region_id == 20
    assert next_state.chat_context.region_id == 20
    assert next_state.voxel_subscriptions == state.voxel_subscriptions

    assert next_state.last_partition_refresh.subscription_apply_status ==
             {:error, :scene_unavailable}
  end

  test "unroutable center preserves previous context and records failure" do
    parent = self()
    window = PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        voxel_subscription_plan: %{region_id: 10}
      })

    assert {:error, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn _presence ->
                 send(parent, :unexpected_chat_call)
                 {:error, :unexpected_chat_call}
               end,
               observe_fun: fn event, payload ->
                 send(parent, {:observe, event, payload})
                 :ok
               end
             )

    assert outcome.status == :failed
    assert outcome.reason == :unroutable_center
    assert outcome.boundary_kind == :unroutable
    assert next_state.partition_context == state.partition_context
    assert next_state.chat_context == state.chat_context
    assert next_state.voxel_subscription_plan == state.voxel_subscription_plan
    assert next_state.last_partition_refresh.status == :failed
    assert next_state.last_partition_refresh.reason == :unroutable_center

    assert_receive {:observe, "gate_partition_runtime_refresh_failed",
                    %{cid: 42, reason: :unroutable_center, boundary_kind: :unroutable}}

    refute_received :unexpected_chat_call
  end

  test "same chunk with unknown region routes through World instead of preserving stale bootstrap" do
    parent = self()
    lease = lease(10, 100)

    window =
      PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => assigned_route(10, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: nil},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: nil}
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {100.0, 50.0, 0.0}),
               route_window_fun: fn logical_scene_id, center_chunk, radius ->
                 send(parent, {:world_window_requested, logical_scene_id, center_chunk, radius})
                 {:ok, window}
               end,
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_presence_refreshed, presence})
                 {:ok, presence}
               end,
               subscription_apply_fun: &subscription_apply_ok/2
             )

    assert_receive {:world_window_requested, 1, {0, 0, 0}, 1}
    assert_receive {:chat_presence_refreshed, %{region_id: 10, chunk_coord: {0, 0, 0}}}

    assert outcome.status == :updated
    assert outcome.region_id == 10
    assert next_state.partition_context.region_id == 10
    assert next_state.chat_context.region_id == 10
  end

  test "same chunk with unknown region applies the partition window to the scene actor for AOI" do
    parent = self()
    lease = lease(10, 100)

    window =
      PartitionWindow.build(1, {0, 0, 0}, near_radius: 0, halo_radius: 1)
      |> PartitionWindow.attach_routes(%{
        {0, 0, 0} => assigned_route(10, lease)
      })

    state =
      state(%{
        scene_ref: parent,
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: nil},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: nil}
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {100.0, 50.0, 0.0}),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: &subscription_apply_ok/2
             )

    assert_receive {:"$gen_cast", {:partition_window, scene_window}}, 300
    assert scene_window.logical_scene_id == 1
    assert scene_window.center_chunk == {0, 0, 0}
    assert Enum.any?(scene_window.route_entries, &match?(%{status: :assigned}, &1))
    assert outcome.status == :updated
    assert next_state.partition_context.region_id == 10
  end

  test "chat refresh failure does not apply the Scene partition window early" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        scene_ref: parent,
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10}
      })

    assert {:error, _next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 520),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn _presence -> {:error, :chat_unavailable} end,
               scene_partition_apply_fun: fn _scene_ref, partition_window ->
                 send(parent, {:scene_window_applied, partition_window.center_chunk})
                 :ok
               end,
               subscription_apply_fun: fn _current_state, _partition_result ->
                 send(parent, :unexpected_subscription_apply_before_chat)
                 {:error, state, %{status: :failed, reason: :unexpected}}
               end
             )

    assert outcome.chat_refresh_status == {:chat_refresh_failed, :chat_unavailable}
    refute_received {:scene_window_applied, _center_chunk}
    refute_received :unexpected_subscription_apply_before_chat
  end

  test "subscription apply failure does not apply the Scene partition window early" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        scene_ref: parent,
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10}
      })

    assert {:error, _next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 521),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               scene_partition_apply_fun: fn _scene_ref, partition_window ->
                 send(parent, {:scene_window_applied, partition_window.center_chunk})
                 :ok
               end,
               subscription_apply_fun: fn current_state, _partition_result ->
                 {:error, current_state, %{status: :failed, reason: :subscription_unavailable}}
               end
             )

    assert outcome.subscription_apply_status == {:error, :subscription_unavailable}
    refute_received {:scene_window_applied, _center_chunk}
  end

  test "chat refresh failure records pending presence and retries it on same chunk without World" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        voxel_subscriptions: %{
          {1, {0, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {0, 0, 0}}
        }
      })

    assert {:error, failed_state, failed_outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 500),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_refresh_failed_for, presence})
                 {:error, :chat_unavailable}
               end,
               subscription_apply_fun: fn _current_state, _partition_result ->
                 send(parent, :unexpected_subscription_apply_before_chat)
                 {:error, state, %{status: :failed, reason: :unexpected}}
               end
             )

    assert_receive {:chat_refresh_failed_for, %{region_id: 20, chunk_coord: {1, 0, 0}}}
    refute_received :unexpected_subscription_apply_before_chat
    assert failed_outcome.chat_refresh_status == {:chat_refresh_failed, :chat_unavailable}
    assert failed_state.partition_context.region_id == 20
    assert failed_state.chat_context.region_id == 10
    assert failed_state.pending_chat_presence.region_id == 20

    assert {:ok, retried_state, retry_outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               failed_state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 501),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius ->
                 send(parent, :unexpected_world_retry)
                 {:error, :unexpected_world_retry}
               end,
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_presence_retried, presence})
                 {:ok, presence}
               end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(
                   parent,
                   {:subscription_applied_after_retry, partition_result.subscription_diff}
                 )

                 {:ok,
                  Map.put(current_state, :voxel_subscriptions, %{
                    {1, {1, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {1, 0, 0}}
                  }),
                  %{
                    status: :applied,
                    subscribe_count: 1,
                    unsubscribe_count: 1,
                    retained_count: 0
                  }}
               end
             )

    assert_receive {:chat_presence_retried, %{region_id: 20, chunk_coord: {1, 0, 0}}}

    assert_receive {:subscription_applied_after_retry,
                    %{subscribe_chunks: [{1, 0, 0}], unsubscribe_chunks: [{0, 0, 0}]}}

    refute_received :unexpected_world_retry
    assert retry_outcome.status == :updated
    assert retry_outcome.chat_refresh_status == :ok
    assert retry_outcome.subscription_apply_status == :ok
    assert retried_state.chat_context.region_id == 20
    assert Map.has_key?(retried_state.voxel_subscriptions, {1, {1, 0, 0}})
    refute Map.has_key?(retried_state.voxel_subscriptions, {1, {0, 0, 0}})
    refute Map.has_key?(retried_state, :pending_chat_presence)
  end

  test "pending chat retry recomputes subscription diff from current owner subscriptions" do
    parent = self()
    lease = lease(20, 200)

    plan = %{
      cid: 42,
      request_id: 500,
      subscribe_entries: [
        %{
          chunk_coord: {1, 0, 0},
          region_id: 20,
          assigned_scene_node: :"scene-a@local",
          lease: lease,
          tier: :near,
          priority: 0,
          send_snapshot?: true
        }
      ],
      skipped_entries: [],
      summary: %{
        cid: 42,
        request_id: 500,
        logical_scene_id: 1,
        requested_chunk_count: 1,
        pressure: :nominal
      }
    }

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {1, 0, 0}, region_id: 20},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        pending_chat_presence: %{
          cid: 42,
          logical_scene_id: 1,
          region_id: 20,
          chunk_coord: {1, 0, 0}
        },
        pending_subscription_result: %{
          cid: 42,
          logical_scene_id: 1,
          region_id: 20,
          boundary_kind: :region,
          chunk_coord: {1, 0, 0},
          previous_region_id: 10,
          previous_chunk_coord: {0, 0, 0},
          subscription_plan: plan,
          subscription_diff: %{
            subscribe_chunks: [{1, 0, 0}],
            unsubscribe_chunks: [{0, 0, 0}],
            retained_chunks: []
          }
        },
        voxel_subscriptions: %{
          {1, {1, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {1, 0, 0}},
          {1, {2, 0, 0}} => %{logical_scene_id: 1, chunk_coord: {2, 0, 0}}
        }
      })

    assert {:ok, retried_state, retry_outcome} =
             PartitionRuntime.apply_refresh_decision(
               state,
               %{
                 kind: :pending_chat_retry,
                 ack_map: Map.from_struct(ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 501))
               },
               chat_refresh_fun: fn presence ->
                 send(parent, {:chat_presence_retried, presence})
                 {:ok, presence}
               end,
               subscription_apply_fun: fn current_state, partition_result ->
                 send(
                   parent,
                   {:subscription_applied_after_retry, partition_result.subscription_diff}
                 )

                 {:ok, current_state,
                  %{
                    status: :applied,
                    subscribe_count: length(partition_result.subscription_diff.subscribe_chunks),
                    unsubscribe_count:
                      length(partition_result.subscription_diff.unsubscribe_chunks),
                    retained_count: length(partition_result.subscription_diff.retained_chunks)
                  }}
               end
             )

    assert_receive {:chat_presence_retried, %{region_id: 20, chunk_coord: {1, 0, 0}}}

    assert_receive {:subscription_applied_after_retry,
                    %{
                      subscribe_chunks: [],
                      unsubscribe_chunks: [{2, 0, 0}],
                      retained_chunks: [{1, 0, 0}]
                    }}

    assert retry_outcome.subscription_diff.subscribe_chunks == []
    assert retry_outcome.subscription_diff.unsubscribe_chunks == [{2, 0, 0}]
    assert retry_outcome.subscription_diff.retained_chunks == [{1, 0, 0}]
    refute Map.has_key?(retried_state, :pending_chat_presence)
  end

  test "successful World-backed refresh clears stale pending chat presence" do
    lease = lease(30, 300)

    window =
      PartitionWindow.build(1, {2, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {2, 0, 0} => assigned_route(30, lease)
      })

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {1, 0, 0}, region_id: 20},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        pending_chat_presence: %{
          cid: 42,
          logical_scene_id: 1,
          region_id: 20,
          chunk_coord: {1, 0, 0}
        }
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {3_250.0, 50.0, 0.0}, auth_tick: 600),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn presence -> {:ok, presence} end,
               subscription_apply_fun: &subscription_apply_ok/2
             )

    assert outcome.status == :updated
    assert next_state.partition_context.region_id == 30
    assert next_state.chat_context.region_id == 30
    refute Map.has_key?(next_state, :pending_chat_presence)
  end

  test "unjoined chat session recovers by joining with authoritative presence" do
    parent = self()
    lease = lease(20, 200)

    window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    state =
      state(%{
        auth_username: "hero",
        chat_session_joined?: false,
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: nil
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 700),
               route_window_fun: fn _logical_scene_id, _center_chunk, _radius -> {:ok, window} end,
               chat_refresh_fun: fn _presence ->
                 send(parent, :unexpected_refresh_before_join)
                 {:error, :unexpected_refresh_before_join}
               end,
               chat_join_fun: fn join_attrs ->
                 send(parent, {:chat_joined, join_attrs})
                 {:ok, join_attrs}
               end,
               subscription_apply_fun: &subscription_apply_ok/2
             )

    assert_receive {:chat_joined,
                    %{
                      cid: 42,
                      username: "hero",
                      connection_pid: _pid,
                      logical_scene_id: 1,
                      region_id: 20,
                      chunk_coord: {1, 0, 0}
                    }}

    refute_received :unexpected_refresh_before_join
    assert outcome.chat_refresh_status == :ok
    assert next_state.chat_session_joined? == true
    assert next_state.chat_context.region_id == 20
  end

  test "missing context emits a skipped observe event" do
    parent = self()
    state = state(%{partition_context: nil, chat_context: nil})

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(state, ack(position: {100.0, 50.0, 0.0}),
               observe_fun: fn event, payload ->
                 send(parent, {:observe, event, payload})
                 :ok
               end
             )

    assert outcome.status == :skipped
    assert outcome.reason == :missing_partition_context
    assert next_state.last_partition_refresh.reason == :missing_partition_context

    assert_receive {:observe, "gate_partition_runtime_refresh_skipped",
                    %{cid: 42, reason: :missing_partition_context}}
  end

  test "invalid ACK emits a skipped observe event" do
    parent = self()

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10}
      })

    assert {:ok, next_state, outcome} =
             PartitionRuntime.refresh_after_movement_ack(state, %{cid: 42, position: :bad},
               observe_fun: fn event, payload ->
                 send(parent, {:observe, event, payload})
                 :ok
               end
             )

    assert outcome.status == :skipped
    assert match?({:invalid_ack, _message}, outcome.reason)
    assert match?({:invalid_ack, _message}, next_state.last_partition_refresh.reason)

    assert_receive {:observe, "gate_partition_runtime_refresh_skipped",
                    %{cid: 42, reason: {:invalid_ack, _message}}}
  end

  test "default World lookup does not silently fall back to a local MapLedger" do
    lease = lease(20, 200)

    local_window =
      PartitionWindow.build(1, {1, 0, 0}, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        {1, 0, 0} => assigned_route(20, lease)
      })

    fake_started? = maybe_start_fake_local_map_ledger(local_window)

    state =
      state(%{
        partition_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10},
        chat_context: %{logical_scene_id: 1, chunk_coord: {0, 0, 0}, region_id: 10}
      })

    assert {:ok,
            %{
              kind: :last_refresh,
              status: :error,
              outcome: %{status: :failed, reason: :world_unavailable}
            }} =
             PartitionRuntime.resolve_after_movement_ack(
               state,
               ack(position: {1_650.0, 50.0, 0.0}, auth_tick: 900)
             )

    if fake_started? do
      refute_received {:local_map_ledger_called, _logical_scene_id, _center_chunk}
    end
  end

  defp state(overrides) do
    Map.merge(
      %{
        cid: 42,
        status: :in_scene,
        chat_context: nil,
        partition_context: nil,
        voxel_subscriptions: %{},
        forwarded_chunk_versions: ChunkVersionLedger.new(),
        voxel_subscription_plan: nil
      },
      overrides
    )
  end

  defp ack(overrides) do
    attrs =
      Map.merge(
        %{
          cid: 42,
          ack_seq: 7,
          auth_tick: 123,
          position: {0.0, 0.0, 0.0},
          velocity: {0.0, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0},
          movement_mode: :grounded,
          correction_flags: 0,
          fixed_dt_ms: 50,
          ground_z: 0.0
        },
        Map.new(overrides)
      )

    struct!(Ack, attrs)
  end

  defp assigned_route(region_id, lease) do
    %{
      region_id: region_id,
      lease_id: lease.lease_id,
      lease: lease,
      assigned_scene_node: :"scene-a@local"
    }
  end

  defp lease(region_id, lease_id) do
    %{
      logical_scene_id: 1,
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: region_id * 100,
      owner_epoch: 1,
      expires_at_ms: 9_999
    }
  end

  defp subscription_apply_ok(current_state, partition_result) do
    diff = partition_result.subscription_diff

    plan_summary =
      partition_result.subscription_plan.summary
      |> Map.put(:region_id, partition_result.region_id)
      |> Map.put(:boundary_kind, partition_result.boundary_kind)

    {:ok, Map.put(current_state, :voxel_subscription_plan, plan_summary),
     %{
       status: :applied,
       subscribe_count: length(diff.subscribe_chunks),
       unsubscribe_count: length(diff.unsubscribe_chunks),
       retained_count: length(diff.retained_chunks)
     }}
  end

  defp maybe_start_fake_local_map_ledger(reply) do
    parent = self()
    name = WorldServer.Voxel.MapLedger

    if Process.whereis(name) do
      false
    else
      pid =
        spawn_link(fn ->
          fake_local_map_ledger_loop(parent, reply)
        end)

      true = Process.register(pid, name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      true
    end
  end

  defp fake_local_map_ledger_loop(parent, reply) do
    receive do
      {:"$gen_call", from, {:route_window_with_leases, logical_scene_id, center_chunk, _opts}} ->
        send(parent, {:local_map_ledger_called, logical_scene_id, center_chunk})
        GenServer.reply(from, reply)
        fake_local_map_ledger_loop(parent, reply)

      _other ->
        fake_local_map_ledger_loop(parent, reply)
    end
  end
end
