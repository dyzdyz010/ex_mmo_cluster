defmodule GateServer.PartitionRefreshTest do
  use ExUnit.Case, async: true

  alias GateServer.PartitionRefresh

  test "drops a late refresh result when a newer generation is pending" do
    parent = self()

    state = %{
      cid: 42,
      partition_refresh_generation: 2,
      partition_refresh_pending: %{status: :pending, generation: 2, auth_tick: 200},
      partition_context: %{logical_scene_id: 1, region_id: 20, chunk_coord: {2, 0, 0}},
      chat_context: %{logical_scene_id: 1, region_id: 20, chunk_coord: {2, 0, 0}},
      last_partition_refresh: %{status: :updated, auth_tick: 200, region_id: 20},
      partition_refresh_apply_fun: fn _state, _decision, _opts ->
        send(parent, :stale_apply_called)
        flunk("stale refresh should not be applied")
      end
    }

    late_outcome = %{status: :updated, auth_tick: 100, boundary_kind: :region, region_id: 10}

    assert {:ignored, next_state, event} =
             PartitionRefresh.apply_completed(
               state,
               1,
               100,
               {:ok, %{kind: :last_refresh, outcome: late_outcome, status: :ok}}
             )

    assert next_state == state
    assert event.status == :ignored
    assert event.generation == 1
    assert event.current_generation == 2
    refute_received :stale_apply_called
  end

  test "drops a current-generation refresh result when auth_tick no longer matches pending state" do
    parent = self()

    state = %{
      cid: 42,
      partition_refresh_generation: 2,
      partition_refresh_pending: %{status: :pending, generation: 2, auth_tick: 201},
      partition_context: %{logical_scene_id: 1, region_id: 20, chunk_coord: {2, 0, 0}},
      chat_context: %{logical_scene_id: 1, region_id: 20, chunk_coord: {2, 0, 0}},
      last_partition_refresh: %{status: :updated, auth_tick: 200, region_id: 20},
      partition_refresh_apply_fun: fn _state, _decision, _opts ->
        send(parent, :mismatched_auth_tick_apply_called)
        flunk("auth-tick mismatched refresh should not be applied")
      end
    }

    late_outcome = %{status: :updated, auth_tick: 200, boundary_kind: :region, region_id: 10}

    assert {:ignored, next_state, event} =
             PartitionRefresh.apply_completed(
               state,
               2,
               200,
               {:ok, %{kind: :last_refresh, outcome: late_outcome, status: :ok}}
             )

    assert next_state == state
    assert event.status == :ignored
    assert event.generation == 2
    assert event.current_generation == 2
    assert event.auth_tick == 200
    assert event.current_auth_tick == 201
    refute_received :mismatched_auth_tick_apply_called
  end

  test "applies current generation decisions without replacing transport-owned state" do
    state = %{
      socket: :socket_ref,
      cid: 42,
      status: :in_scene,
      partition_refresh_generation: 2,
      partition_refresh_pending: %{status: :pending, generation: 2, auth_tick: 200},
      partition_context: %{logical_scene_id: 1, region_id: 10, chunk_coord: {1, 0, 0}},
      chat_context: %{logical_scene_id: 1, region_id: 10, chunk_coord: {1, 0, 0}},
      voxel_subscriptions: %{},
      last_partition_refresh: %{status: :updated, auth_tick: 100, region_id: 10}
    }

    outcome = %{status: :updated, auth_tick: 200, boundary_kind: :region, region_id: 20}

    assert {:applied, next_state, event} =
             PartitionRefresh.apply_completed(
               state,
               2,
               200,
               {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok}}
             )

    assert next_state.socket == :socket_ref
    assert next_state.status == :in_scene
    assert next_state.last_partition_refresh.region_id == 20
    refute Map.has_key?(next_state, :partition_refresh_pending)
    assert event.status == :ok
    assert event.outcome_status == :updated
  end

  test "coalesces movement ACKs while a refresh is in flight and runs only the latest queued ACK" do
    parent = self()

    apply_fun = fn state, decision, _opts ->
      outcome = decision.outcome
      {:ok, Map.put(state, :last_partition_refresh, outcome), outcome}
    end

    runner = fn _state, ack, _opts ->
      send(parent, {:runner_called, ack.auth_tick, self()})

      receive do
        {:release_runner, auth_tick} ->
          {:ok,
           %{
             kind: :last_refresh,
             status: :ok,
             outcome: %{status: :updated, auth_tick: auth_tick, region_id: auth_tick}
           }}
      end
    end

    state = %{
      cid: 42,
      partition_context: %{logical_scene_id: 1, region_id: 10, chunk_coord: {1, 0, 0}},
      partition_refresh_fun: runner,
      partition_refresh_apply_fun: apply_fun
    }

    assert {:ok, pending_state, %{status: :scheduled, generation: 1, auth_tick: 100}} =
             PartitionRefresh.schedule(state, %{ack_seq: 1, auth_tick: 100}, owner: self())

    assert_receive {:runner_called, 100, first_runner}

    assert {:ok, coalesced_state, %{status: :coalesced, generation: 1, auth_tick: 300}} =
             PartitionRefresh.schedule(
               pending_state,
               %{ack_seq: 2, auth_tick: 200},
               owner: self()
             )
             |> elem(1)
             |> PartitionRefresh.schedule(%{ack_seq: 3, auth_tick: 300}, owner: self())

    refute_receive {:runner_called, 200, _pid}, 50
    refute_receive {:runner_called, 300, _pid}, 50

    send(first_runner, {:release_runner, 100})
    assert_receive {:partition_refresh_completed, 1, 100, first_result}

    assert {:applied, chained_state, event} =
             PartitionRefresh.apply_completed(coalesced_state, 1, 100, first_result)

    assert event.status == :ok
    assert event.queued_status == :scheduled
    assert event.queued_auth_tick == 300
    assert chained_state.partition_refresh_generation == 2
    assert chained_state.partition_refresh_pending.auth_tick == 300
    refute Map.has_key?(chained_state, :partition_refresh_queued)
    assert_receive {:runner_called, 300, _second_runner}
  end
end
