defmodule GateServer.PartitionRefresh do
  @moduledoc """
  Coordinates asynchronous, fenced partition refreshes for Gate connections.

  TCP and WebSocket workers own the socket/session process. They send movement
  ACKs immediately, then use this module to run the side-effect-free World
  routing and partition-planning step outside the connection process. Results
  are fenced by a monotonically increasing generation; Chat and Scene
  subscription side effects are applied only by the owner connection after the
  fence passes.
  """

  alias GateServer.PartitionRuntime

  @doc """
  Starts one asynchronous partition refresh and returns the pending state.

  The caller must pass `:owner`, usually `self()`. Test and specialized runtime
  callers may place `:partition_refresh_fun` in state; production defaults to
  `GateServer.PartitionRuntime.resolve_after_movement_ack/3`.
  """
  def schedule(state, ack, opts) when is_map(state) do
    if pending_refresh?(state) do
      coalesce_latest(state, ack)
    else
      start_refresh(state, ack, opts)
    end
  end

  defp start_refresh(state, ack, opts) when is_map(state) do
    owner = Keyword.fetch!(opts, :owner)
    generation = Map.get(state, :partition_refresh_generation, 0) + 1
    ack_map = mapify(ack)
    auth_tick = Map.get(ack_map, :auth_tick)
    ack_seq = Map.get(ack_map, :ack_seq)

    runner =
      Map.get(state, :partition_refresh_fun, &PartitionRuntime.resolve_after_movement_ack/3)

    refresh_opts =
      state
      |> Map.get(:partition_refresh_opts, [])
      |> Keyword.merge(Keyword.get(opts, :refresh_opts, []))
      |> Keyword.put(:connection_pid, owner)
      |> Keyword.put(:subscriber, owner)

    snapshot =
      state
      |> Map.delete(:partition_refresh_pending)
      |> Map.put(:partition_refresh_generation, generation)

    {:ok, _pid} =
      Task.start(fn ->
        result = run_refresh(runner, snapshot, ack, refresh_opts)
        send(owner, {:partition_refresh_completed, generation, auth_tick, result})
      end)

    pending = %{
      status: :pending,
      generation: generation,
      auth_tick: auth_tick,
      ack_seq: ack_seq,
      started_at_ms: System.monotonic_time(:millisecond)
    }

    next_state =
      state
      |> Map.put(:partition_refresh_generation, generation)
      |> Map.put(:partition_refresh_pending, pending)

    {:ok, next_state,
     %{
       status: :scheduled,
       generation: generation,
       auth_tick: auth_tick,
       ack_seq: ack_seq
     }}
  end

  defp coalesce_latest(state, ack) do
    generation = Map.get(state, :partition_refresh_generation, 0)
    ack_map = mapify(ack)
    auth_tick = Map.get(ack_map, :auth_tick)
    ack_seq = Map.get(ack_map, :ack_seq)

    next_state =
      Map.put(state, :partition_refresh_queued, %{
        ack: ack,
        auth_tick: auth_tick,
        ack_seq: ack_seq
      })

    {:ok, next_state,
     %{
       status: :coalesced,
       generation: generation,
       auth_tick: auth_tick,
       ack_seq: ack_seq
     }}
  end

  @doc """
  Applies a completed refresh if its generation is still current.

  Returns `{:applied, state, event}` for current results and
  `{:ignored, state, event}` for stale results.
  """
  def apply_completed(state, generation, auth_tick, result) when is_map(state) do
    current_generation = Map.get(state, :partition_refresh_generation, 0)
    pending = Map.get(state, :partition_refresh_pending)

    if refresh_current?(pending, generation, auth_tick, current_generation) do
      {status, next_state, outcome} = apply_result(state, result, auth_tick)

      next_state =
        Map.delete(next_state, :partition_refresh_pending)

      base_event = %{
        status: status,
        generation: generation,
        auth_tick: auth_tick,
        outcome_status: Map.get(outcome, :status),
        boundary_kind: Map.get(outcome, :boundary_kind),
        reason: Map.get(outcome, :reason)
      }

      {next_state, event} = maybe_start_queued_refresh(next_state, base_event)

      {:applied, next_state, event}
    else
      {:ignored, state,
       %{
         status: :ignored,
         generation: generation,
         current_generation: current_generation,
         auth_tick: auth_tick,
         current_auth_tick: pending_auth_tick(pending)
       }}
    end
  end

  defp refresh_current?(pending, generation, auth_tick, current_generation)
       when is_map(pending) do
    generation == current_generation and
      Map.get(pending, :generation) == generation and
      Map.get(pending, :auth_tick) == auth_tick
  end

  defp refresh_current?(_pending, _generation, _auth_tick, _current_generation), do: false

  defp pending_refresh?(%{partition_refresh_pending: %{status: :pending}}), do: true
  defp pending_refresh?(_state), do: false

  defp maybe_start_queued_refresh(state, event) do
    case Map.pop(state, :partition_refresh_queued) do
      {nil, next_state} ->
        {next_state, event}

      {%{ack: ack}, next_state} ->
        {:ok, scheduled_state, scheduled_event} = start_refresh(next_state, ack, owner: self())

        event =
          event
          |> Map.put(:queued_status, Map.get(scheduled_event, :status))
          |> Map.put(:queued_generation, Map.get(scheduled_event, :generation))
          |> Map.put(:queued_auth_tick, Map.get(scheduled_event, :auth_tick))
          |> Map.put(:queued_ack_seq, Map.get(scheduled_event, :ack_seq))

        {scheduled_state, event}
    end
  end

  defp pending_auth_tick(pending) when is_map(pending), do: Map.get(pending, :auth_tick)
  defp pending_auth_tick(_pending), do: nil

  defp run_refresh(runner, state, ack, opts) do
    runner.(state, ack, opts)
  rescue
    exception -> {:error, failed_outcome(state, ack, {:exception, Exception.message(exception)})}
  catch
    kind, reason -> {:error, failed_outcome(state, ack, {kind, reason})}
  end

  defp apply_result(state, {:ok, decision}, _auth_tick) when is_map(decision) do
    apply_fun =
      Map.get(state, :partition_refresh_apply_fun, &PartitionRuntime.apply_refresh_decision/3)

    apply_fun.(state, decision, connection_pid: self(), subscriber: self())
  end

  defp apply_result(state, {:error, outcome}, _auth_tick) when is_map(outcome) do
    {:error, Map.put(state, :last_partition_refresh, outcome), outcome}
  end

  defp apply_result(state, other, auth_tick) do
    outcome = failed_outcome(state, %{auth_tick: auth_tick}, {:invalid_refresh_result, other})
    {:error, Map.put(state, :last_partition_refresh, outcome), outcome}
  end

  defp failed_outcome(state, ack, reason) do
    previous_context = Map.get(state, :partition_context) || Map.get(state, :chat_context) || %{}

    %{
      status: :failed,
      cid: Map.get(state, :cid, Map.get(ack, :cid)),
      logical_scene_id: Map.get(previous_context, :logical_scene_id),
      boundary_kind: :unknown,
      previous_region_id: Map.get(previous_context, :region_id),
      region_id: Map.get(previous_context, :region_id),
      previous_chunk_coord: Map.get(previous_context, :chunk_coord),
      chunk_coord: Map.get(previous_context, :chunk_coord),
      auth_tick: Map.get(ack, :auth_tick),
      ack_seq: Map.get(ack, :ack_seq),
      reason: reason
    }
  end

  defp mapify(%_struct{} = value), do: Map.from_struct(value)
  defp mapify(value) when is_map(value), do: value
end
