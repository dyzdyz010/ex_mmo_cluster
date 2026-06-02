defmodule GateServer.PartitionRuntime do
  @moduledoc """
  Shared Gate-side runtime bridge for authoritative partition context refreshes.

  Connection workers send movement ACKs immediately, then ask this module to
  refresh the server-side region context when the authoritative movement result
  crosses a chunk boundary. Scene movement positions are server-Z-up; this
  runtime converts them to voxel Y-up world coordinates before routing. World
  remains the route and lease authority, Chat owns channel presence, and Scene
  AOI consumes the same World partition window through the attached player
  actor.
  """

  alias GateServer.{ChatAdapter, PartitionContext}
  alias GateServer.Voxel.ClientAckLedger
  alias GateServer.Voxel.DeliveryScheduler
  alias GateServer.Voxel.SubscriptionRuntime
  alias SceneServer.Voxel.Types

  @default_call_timeout 5_000
  @default_partition_radius 1

  @doc """
  Refreshes one connection state after a Scene-authoritative movement ACK.

  Same-chunk movement is deliberately cheap and does not call World or Chat.
  Chunk-boundary movement fetches a World partition window, delegates the
  decision to `GateServer.PartitionContext`, refreshes Chat presence, and stores
  a Gate-local context/debug summary. Route failures preserve the previous
  context and are surfaced through `:last_partition_refresh`.
  """
  def refresh_after_movement_ack(state, ack, opts \\ []) when is_map(state) do
    with {:ok, decision} <- resolve_after_movement_ack(state, ack, opts) do
      apply_refresh_decision(state, decision, opts)
    end
  end

  @doc """
  Resolves the side-effect-free partition refresh decision for one ACK.

  This may call World to fetch a partition window, but it does not touch Chat,
  Scene subscriptions, or connection state. The returned decision must be
  applied by the owning connection process through `apply_refresh_decision/3`.
  """
  def resolve_after_movement_ack(state, ack, opts \\ []) when is_map(state) do
    ack_map = mapify(ack)
    cid = Map.get(state, :cid, Map.get(ack_map, :cid))
    auth_tick = Map.get(ack_map, :auth_tick)
    previous_context = previous_context(state)

    with {:ok, previous_context} <- ensure_previous_context(previous_context),
         {:ok, location} <- fetch_voxel_location(ack_map),
         logical_scene_id when is_integer(logical_scene_id) <-
           Map.get(previous_context, :logical_scene_id),
         chunk_coord <- Types.chunk_from_world_cm!(location) do
      cond do
        pending_chat_presence?(state, chunk_coord) ->
          {:ok, %{kind: :pending_chat_retry, ack_map: ack_map}}

        Map.get(previous_context, :chunk_coord) == chunk_coord and
            not is_nil(Map.get(previous_context, :region_id)) ->
          outcome = %{
            status: :unchanged,
            boundary_kind: :none,
            cid: cid,
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            previous_chunk_coord: chunk_coord,
            region_id: Map.get(previous_context, :region_id),
            previous_region_id: Map.get(previous_context, :region_id),
            auth_tick: auth_tick,
            subscription_diff: %{
              subscribe_chunks: [],
              unsubscribe_chunks: [],
              retained_chunks: []
            }
          }

          {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok}}

        true ->
          resolve_changed_chunk(
            state,
            ack_map,
            cid,
            logical_scene_id,
            location,
            chunk_coord,
            previous_context,
            opts
          )
      end
    else
      {:error, reason} ->
        outcome = skipped_outcome(state, ack_map, reason)
        {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok, event: :skipped}}

      nil ->
        outcome = skipped_outcome(state, ack_map, :missing_logical_scene)
        {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok, event: :skipped}}
    end
  rescue
    exception in [ArgumentError, KeyError] ->
      outcome = skipped_outcome(state, mapify(ack), {:invalid_ack, Exception.message(exception)})
      {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok, event: :skipped}}
  end

  @doc """
  Applies a previously resolved refresh decision on the owning connection.
  """
  def apply_refresh_decision(state, %{kind: :pending_chat_retry, ack_map: ack_map}, opts)
      when is_map(state) do
    retry_pending_chat_presence(state, ack_map, opts)
  end

  def apply_refresh_decision(state, %{kind: :window, ack_map: ack_map, window: window}, opts)
      when is_map(state) do
    apply_window_decision(state, ack_map, window, opts)
  end

  def apply_refresh_decision(
        state,
        %{kind: :last_refresh, outcome: outcome, status: status} = decision,
        opts
      )
      when is_map(state) do
    case Map.get(decision, :event) do
      :skipped -> emit(opts, "gate_partition_runtime_refresh_skipped", observe_skipped(outcome))
      :failed -> emit(opts, "gate_partition_runtime_refresh_failed", observe_failure(outcome))
      _other -> :ok
    end

    {status, put_last_refresh(state, outcome), outcome}
  end

  defp pending_chat_presence?(state, chunk_coord) do
    match?(%{chunk_coord: ^chunk_coord}, Map.get(state, :pending_chat_presence)) and
      match?(%{chunk_coord: ^chunk_coord}, Map.get(state, :partition_context))
  end

  defp retry_pending_chat_presence(state, ack_map, opts) do
    pending = Map.fetch!(state, :pending_chat_presence)
    pending_subscription_result = Map.get(state, :pending_subscription_result)

    case refresh_or_join_chat(state, pending, opts) do
      {:ok, updated_presence} ->
        pending_subscription_result =
          refresh_subscription_diff(pending_subscription_result, base_subscription_state(state))

        base_outcome =
          pending_chat_retry_outcome(
            state,
            ack_map,
            pending,
            :ok,
            pending_subscription_result
          )

        base_state =
          state
          |> Map.put(:chat_context, chat_context(pending, updated_presence))
          |> Map.put(:chat_session_joined?, true)

        case apply_pending_subscriptions(base_state, pending_subscription_result, opts) do
          {:ok, subscribed_state, apply_summary} ->
            outcome =
              base_outcome
              |> Map.put(:subscription_apply_status, subscription_apply_status(apply_summary))
              |> Map.put(:subscription_apply_summary, apply_summary)

            next_state =
              subscribed_state
              |> Map.delete(:pending_chat_presence)
              |> Map.delete(:pending_subscription_result)
              |> put_last_refresh(outcome)

            emit(opts, "gate_partition_runtime_chat_refresh_retried", observe_updated(outcome))
            {:ok, next_state, outcome}

          {:error, subscription_state, apply_summary} ->
            reason = Map.get(apply_summary, :reason, :subscription_apply_failed)

            outcome =
              base_outcome
              |> Map.put(:subscription_apply_status, {:error, reason})
              |> Map.put(:subscription_apply_summary, apply_summary)

            next_state = put_last_refresh(subscription_state, outcome)

            emit(
              opts,
              "gate_partition_runtime_subscription_apply_failed",
              observe_updated(outcome)
            )

            {:error, next_state, outcome}
        end

      {:error, reason} ->
        outcome =
          pending_chat_retry_outcome(
            state,
            ack_map,
            pending,
            {:chat_refresh_failed, reason},
            pending_subscription_result
          )

        next_state = put_last_refresh(state, outcome)
        emit(opts, "gate_partition_runtime_chat_refresh_failed", observe_updated(outcome))
        {:error, next_state, outcome}
    end
  end

  defp resolve_changed_chunk(
         _state,
         ack_map,
         cid,
         logical_scene_id,
         _location,
         chunk_coord,
         previous_context,
         opts
       ) do
    radius = Keyword.get(opts, :partition_radius, @default_partition_radius)
    route_window_fun = Keyword.get(opts, :route_window_fun, &default_route_window/3)

    case route_window_fun.(logical_scene_id, chunk_coord, radius) do
      {:ok, window} ->
        {:ok, %{kind: :window, ack_map: ack_map, window: window}}

      {:error, reason} ->
        outcome =
          failure_outcome(%{
            cid: cid,
            logical_scene_id: logical_scene_id,
            auth_tick: Map.get(ack_map, :auth_tick),
            chunk_coord: chunk_coord,
            previous_context: previous_context,
            reason: reason,
            boundary_kind: :unroutable
          })

        {:ok, %{kind: :last_refresh, outcome: outcome, status: :error, event: :failed}}
    end
  end

  defp apply_window_decision(state, ack_map, window, opts) do
    cid = Map.get(state, :cid, Map.get(ack_map, :cid))
    previous_context = previous_context(state)

    with {:ok, previous_context} <- ensure_previous_context(previous_context),
         {:ok, location} <- fetch_voxel_location(ack_map),
         logical_scene_id when is_integer(logical_scene_id) <-
           Map.get(previous_context, :logical_scene_id),
         chunk_coord <- Types.chunk_from_world_cm!(location) do
      resolve_partition_context(
        state,
        ack_map,
        cid,
        logical_scene_id,
        location,
        chunk_coord,
        previous_context,
        window,
        opts
      )
    else
      {:error, reason} ->
        outcome = skipped_outcome(state, ack_map, reason)
        emit(opts, "gate_partition_runtime_refresh_skipped", observe_skipped(outcome))
        {:ok, put_last_refresh(state, outcome), outcome}

      nil ->
        outcome = skipped_outcome(state, ack_map, :missing_logical_scene)
        emit(opts, "gate_partition_runtime_refresh_skipped", observe_skipped(outcome))
        {:ok, put_last_refresh(state, outcome), outcome}
    end
  rescue
    exception in [ArgumentError, KeyError] ->
      outcome = skipped_outcome(state, ack_map, {:invalid_ack, Exception.message(exception)})
      emit(opts, "gate_partition_runtime_refresh_skipped", observe_skipped(outcome))
      {:ok, put_last_refresh(state, outcome), outcome}
  end

  defp resolve_partition_context(
         state,
         ack_map,
         cid,
         logical_scene_id,
         location,
         chunk_coord,
         previous_context,
         window,
         opts
       ) do
    attrs =
      %{
        cid: cid,
        request_id: Map.get(ack_map, :auth_tick, 0),
        logical_scene_id: logical_scene_id,
        authoritative_location: location,
        previous_context: context_for_resolve(previous_context),
        partition_window: window,
        current_subscriptions: Map.get(state, :voxel_subscriptions, %{}),
        known_versions: client_ack_known_versions(state, logical_scene_id)
      }
      |> Map.merge(subscription_budget_attrs(state))

    case PartitionContext.resolve(attrs) do
      {:ok, result} ->
        apply_partition_result(state, ack_map, result, opts)

      {:error, reason, result} ->
        outcome =
          failure_outcome(%{
            cid: cid,
            logical_scene_id: logical_scene_id,
            auth_tick: Map.get(ack_map, :auth_tick),
            chunk_coord: chunk_coord,
            previous_context: previous_context,
            reason: reason,
            boundary_kind: result.boundary_kind
          })

        emit(opts, "gate_partition_runtime_refresh_failed", observe_failure(outcome))
        {:error, put_last_refresh(state, outcome), outcome}

      {:error, reason} ->
        outcome =
          failure_outcome(%{
            cid: cid,
            logical_scene_id: logical_scene_id,
            auth_tick: Map.get(ack_map, :auth_tick),
            chunk_coord: chunk_coord,
            previous_context: previous_context,
            reason: reason,
            boundary_kind: :unroutable
          })

        emit(opts, "gate_partition_runtime_refresh_failed", observe_failure(outcome))
        {:error, put_last_refresh(state, outcome), outcome}
    end
  end

  defp context_for_resolve(%{region_id: nil} = context), do: Map.put(context, :chunk_coord, nil)
  defp context_for_resolve(context), do: context

  defp subscription_budget_attrs(state) do
    direct_attrs =
      state
      |> Map.take([
        :last_server_seq,
        :last_client_ack_seq,
        :reliable_pending_bytes,
        :fast_lane_pending_bytes,
        :recovery_request_count,
        :resync_request_count,
        :snapshot_estimate_bytes,
        :delta_estimate_bytes,
        :field_estimate_bytes,
        :recovery_estimate_bytes
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    direct_attrs
    |> maybe_put(:stream_caps, Map.get(state, :voxel_stream_caps, Map.get(state, :stream_caps)))
    |> maybe_put(
      :snapshot_estimate_bytes,
      Map.get(state, :voxel_snapshot_estimate_bytes)
    )
    |> maybe_put(:delta_estimate_bytes, Map.get(state, :voxel_delta_estimate_bytes))
    |> maybe_put(:field_estimate_bytes, Map.get(state, :voxel_field_estimate_bytes))
    |> maybe_put(:recovery_estimate_bytes, Map.get(state, :voxel_recovery_estimate_bytes))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp client_ack_known_versions(state, logical_scene_id) do
    state
    |> Map.get(:client_ack_versions, ClientAckLedger.new())
    |> ClientAckLedger.known_versions(logical_scene_id)
    |> Map.drop(
      DeliveryScheduler.resync_required_chunks(Map.get(state, :voxel_delivery), logical_scene_id)
    )
  end

  defp apply_partition_result(state, ack_map, result, opts) do
    chat_presence = Map.put(result.chat_presence, :cid, result.cid)

    case refresh_or_join_chat(state, chat_presence, opts) do
      {:ok, updated_presence} ->
        base_state =
          state
          |> Map.put(:partition_context, partition_context(result, ack_map))
          |> Map.put(:chat_context, chat_context(chat_presence, updated_presence))
          |> Map.put(:chat_session_joined?, true)
          |> Map.delete(:pending_chat_presence)
          |> Map.delete(:pending_subscription_result)

        result = refresh_subscription_diff(result, base_state)
        base_outcome = updated_outcome(result, ack_map, :ok)

        case apply_subscriptions(base_state, result, opts) do
          {:ok, subscribed_state, apply_summary} ->
            outcome =
              base_outcome
              |> Map.put(:subscription_apply_status, :ok)
              |> Map.put(:subscription_apply_summary, apply_summary)

            apply_scene_partition_window(subscribed_state, result, opts)

            next_state = put_last_refresh(subscribed_state, outcome)

            emit(opts, "gate_partition_runtime_refreshed", observe_updated(outcome))
            {:ok, next_state, outcome}

          {:error, subscription_state, apply_summary} ->
            reason = Map.get(apply_summary, :reason, :subscription_apply_failed)

            outcome =
              base_outcome
              |> Map.put(:subscription_apply_status, {:error, reason})
              |> Map.put(:subscription_apply_summary, apply_summary)

            next_state = put_last_refresh(subscription_state, outcome)

            emit(
              opts,
              "gate_partition_runtime_subscription_apply_failed",
              observe_updated(outcome)
            )

            {:error, next_state, outcome}
        end

      {:error, reason} ->
        result = refresh_subscription_diff(result, state)
        outcome = updated_outcome(result, ack_map, {:chat_refresh_failed, reason})

        next_state =
          state
          |> Map.put(:partition_context, partition_context(result, ack_map))
          |> Map.put(:pending_chat_presence, chat_presence)
          |> Map.put(
            :pending_subscription_result,
            result
            |> refresh_subscription_diff(state)
            |> pending_subscription_result()
          )
          |> Map.put(:voxel_subscription_plan, subscription_plan_summary(result))
          |> put_last_refresh(outcome)

        emit(opts, "gate_partition_runtime_chat_refresh_failed", observe_updated(outcome))
        {:error, next_state, outcome}
    end
  end

  defp apply_scene_partition_window(
         %{scene_ref: scene_ref},
         %{subscription_plan: %{partition_window: partition_window}},
         opts
       )
       when not is_nil(scene_ref) and not is_nil(partition_window) do
    apply_fun = Keyword.get(opts, :scene_partition_apply_fun, &default_scene_partition_apply/2)

    case safe_scene_partition_apply(apply_fun, scene_ref, partition_window) do
      :ok ->
        emit(opts, "gate_partition_runtime_scene_window_applied", %{
          scene_ref: inspect(scene_ref),
          logical_scene_id: Map.get(partition_window, :logical_scene_id),
          center_chunk: Map.get(partition_window, :center_chunk)
        })

      {:error, reason} ->
        emit(opts, "gate_partition_runtime_scene_window_failed", %{
          scene_ref: inspect(scene_ref),
          logical_scene_id: Map.get(partition_window, :logical_scene_id),
          center_chunk: Map.get(partition_window, :center_chunk),
          reason: reason
        })
    end
  end

  defp apply_scene_partition_window(_state, _result, _opts), do: :ok

  defp safe_scene_partition_apply(apply_fun, scene_ref, partition_window) do
    case apply_fun.(scene_ref, partition_window) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_scene_partition_apply_result, other}}
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp default_scene_partition_apply(scene_ref, partition_window) do
    GenServer.cast(scene_ref, {:partition_window, partition_window})
    :ok
  end

  defp apply_subscriptions(state, result, opts) do
    apply_fun =
      Keyword.get(opts, :subscription_apply_fun, fn current_state, partition_result ->
        SubscriptionRuntime.apply_partition_result(current_state, partition_result,
          reason: :movement_boundary,
          subscriber: Keyword.get(opts, :subscriber, self())
        )
      end)

    apply_fun.(state, result)
  end

  defp apply_pending_subscriptions(state, nil, _opts) do
    {:ok, state,
     %{
       status: :skipped,
       reason: :no_pending_subscription_result,
       subscribe_count: 0,
       unsubscribe_count: 0,
       retained_count: 0
     }}
  end

  defp apply_pending_subscriptions(state, pending_result, opts) do
    apply_subscriptions(state, refresh_subscription_diff(pending_result, state), opts)
  end

  defp base_subscription_state(state), do: Map.put_new(state, :voxel_subscriptions, %{})

  defp refresh_subscription_diff(nil, _state), do: nil

  defp refresh_subscription_diff(result, state) when is_map(result) and is_map(state) do
    Map.put(result, :subscription_diff, current_subscription_diff(state, result))
  end

  defp current_subscription_diff(_state, %{subscription_plan: nil}), do: empty_subscription_diff()

  defp current_subscription_diff(state, %{subscription_plan: %{summary: summary} = plan}) do
    logical_scene_id = Map.fetch!(summary, :logical_scene_id)

    current_chunks =
      current_subscription_chunks(Map.get(state, :voxel_subscriptions, %{}), logical_scene_id)

    target_chunks =
      plan
      |> Map.get(:subscribe_entries, [])
      |> Enum.map(&coord!(Map.fetch!(&1, :chunk_coord)))
      |> MapSet.new()

    %{
      subscribe_chunks: sorted_chunks(MapSet.difference(target_chunks, current_chunks)),
      unsubscribe_chunks: sorted_chunks(MapSet.difference(current_chunks, target_chunks)),
      retained_chunks: sorted_chunks(MapSet.intersection(current_chunks, target_chunks))
    }
  end

  defp current_subscription_diff(_state, _result), do: empty_subscription_diff()

  defp current_subscription_chunks(subscriptions, logical_scene_id) when is_map(subscriptions) do
    subscriptions
    |> Enum.flat_map(fn
      {{^logical_scene_id, chunk_coord}, _value} ->
        [coord!(chunk_coord)]

      {_key, %{logical_scene_id: ^logical_scene_id, chunk_coord: chunk_coord}} ->
        [coord!(chunk_coord)]

      {_key, _value} ->
        []
    end)
    |> MapSet.new()
  end

  defp current_subscription_chunks(_subscriptions, _logical_scene_id), do: MapSet.new()

  defp sorted_chunks(chunks) do
    chunks
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp subscription_apply_status(%{status: :skipped}), do: :none
  defp subscription_apply_status(_apply_summary), do: :ok

  defp refresh_or_join_chat(state, chat_presence, opts) do
    chat_refresh_fun = Keyword.get(opts, :chat_refresh_fun, &ChatAdapter.refresh_presence/1)

    if Map.get(state, :chat_session_joined?) == false do
      join_chat(state, chat_presence, opts)
    else
      case chat_refresh_fun.(chat_presence) do
        {:ok, updated_presence} -> {:ok, updated_presence}
        {:error, :session_not_joined} -> join_chat(state, chat_presence, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp join_chat(state, chat_presence, opts) do
    chat_join_fun = Keyword.get(opts, :chat_join_fun, &ChatAdapter.join/1)

    chat_join_fun.(%{
      cid: chat_presence.cid,
      username: Map.get(state, :auth_username) || "anonymous",
      connection_pid: Keyword.get(opts, :connection_pid, self()),
      logical_scene_id: chat_presence.logical_scene_id,
      region_id: chat_presence.region_id,
      chunk_coord: chat_presence.chunk_coord,
      location: Map.get(chat_presence, :location)
    })
  end

  defp previous_context(state) do
    Map.get(state, :partition_context) || Map.get(state, :chat_context)
  end

  defp ensure_previous_context(%{logical_scene_id: id, chunk_coord: {_, _, _}} = context)
       when is_integer(id),
       do: {:ok, context}

  defp ensure_previous_context(_context), do: {:error, :missing_partition_context}

  defp fetch_voxel_location(ack_map) do
    with {:ok, {x, movement_horizontal_y, movement_vertical_z}} <- fetch_location(ack_map) do
      {:ok, {x, movement_vertical_z, movement_horizontal_y}}
    end
  end

  defp fetch_location(%{position: {x, y, z}}) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x, y, z}}

  defp fetch_location(%{position: [x, y, z]}) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x, y, z}}

  defp fetch_location(_ack_map), do: {:error, {:invalid_ack, :missing_authoritative_position}}

  defp updated_outcome(result, ack_map, chat_refresh_status) do
    %{
      status: :updated,
      cid: result.cid,
      logical_scene_id: result.logical_scene_id,
      boundary_kind: result.boundary_kind,
      previous_region_id: result.previous_region_id,
      region_id: result.region_id,
      previous_chunk_coord: result.previous_chunk_coord,
      chunk_coord: result.chunk_coord,
      auth_tick: Map.get(ack_map, :auth_tick),
      ack_seq: Map.get(ack_map, :ack_seq),
      subscription_diff: result.subscription_diff,
      chat_refresh_status: chat_refresh_status
    }
  end

  defp pending_chat_retry_outcome(
         state,
         ack_map,
         pending,
         chat_refresh_status,
         pending_subscription_result
       ) do
    previous_context = previous_context(state) || pending
    subscription_diff = pending_subscription_diff(pending_subscription_result)

    %{
      status: :updated,
      cid: pending.cid,
      logical_scene_id: pending.logical_scene_id,
      boundary_kind: :none,
      previous_region_id: Map.get(previous_context, :region_id),
      region_id: pending.region_id,
      previous_chunk_coord: Map.get(previous_context, :chunk_coord),
      chunk_coord: pending.chunk_coord,
      auth_tick: Map.get(ack_map, :auth_tick),
      ack_seq: Map.get(ack_map, :ack_seq),
      subscription_diff: subscription_diff,
      chat_refresh_status: chat_refresh_status
    }
  end

  defp pending_subscription_diff(%{subscription_diff: diff}), do: diff
  defp pending_subscription_diff(_pending_subscription_result), do: empty_subscription_diff()

  defp failure_outcome(attrs) do
    previous_context = Map.fetch!(attrs, :previous_context)

    %{
      status: :failed,
      cid: attrs.cid,
      logical_scene_id: attrs.logical_scene_id,
      boundary_kind: attrs.boundary_kind,
      previous_region_id: Map.get(previous_context, :region_id),
      region_id: Map.get(previous_context, :region_id),
      previous_chunk_coord: Map.get(previous_context, :chunk_coord),
      chunk_coord: attrs.chunk_coord,
      auth_tick: attrs.auth_tick,
      reason: attrs.reason,
      subscription_diff: empty_subscription_diff()
    }
  end

  defp skipped_outcome(state, ack_map, reason) do
    previous_context = previous_context(state) || %{}

    %{
      status: :skipped,
      cid: Map.get(state, :cid, Map.get(ack_map, :cid)),
      logical_scene_id: Map.get(previous_context, :logical_scene_id),
      boundary_kind: :unknown,
      previous_region_id: Map.get(previous_context, :region_id),
      region_id: Map.get(previous_context, :region_id),
      previous_chunk_coord: Map.get(previous_context, :chunk_coord),
      chunk_coord: Map.get(previous_context, :chunk_coord),
      auth_tick: Map.get(ack_map, :auth_tick),
      ack_seq: Map.get(ack_map, :ack_seq),
      reason: reason,
      subscription_diff: empty_subscription_diff()
    }
  end

  defp partition_context(result, ack_map) do
    %{
      logical_scene_id: result.logical_scene_id,
      region_id: result.region_id,
      chunk_coord: result.chunk_coord,
      authoritative_location: result.authoritative_location,
      auth_tick: Map.get(ack_map, :auth_tick),
      ack_seq: Map.get(ack_map, :ack_seq),
      boundary_kind: result.boundary_kind,
      center_route: route_summary(result.center_route),
      candidate_region_ids: candidate_region_ids(result),
      candidate_region_radius: candidate_region_radius(result)
    }
  end

  defp chat_context(chat_presence, updated_presence) when is_map(updated_presence) do
    chat_presence
    |> Map.merge(
      Map.take(updated_presence, [:cid, :username, :logical_scene_id, :region_id, :chunk_coord])
    )
  end

  defp chat_context(chat_presence, _updated_presence), do: chat_presence

  defp pending_subscription_result(%{subscription_plan: nil}), do: nil

  defp pending_subscription_result(result) do
    %{
      cid: result.cid,
      logical_scene_id: result.logical_scene_id,
      region_id: result.region_id,
      boundary_kind: result.boundary_kind,
      chunk_coord: result.chunk_coord,
      previous_region_id: result.previous_region_id,
      previous_chunk_coord: result.previous_chunk_coord,
      subscription_plan: minimal_subscription_plan(result.subscription_plan),
      subscription_diff: result.subscription_diff
    }
  end

  defp minimal_subscription_plan(nil), do: nil

  defp minimal_subscription_plan(plan) do
    Map.take(plan, [:cid, :request_id, :subscribe_entries, :skipped_entries, :summary])
  end

  defp subscription_plan_summary(%{subscription_plan: nil} = result) do
    %{
      logical_scene_id: result.logical_scene_id,
      region_id: result.region_id,
      center_chunk: result.chunk_coord,
      boundary_kind: result.boundary_kind,
      subscribe_count: 0,
      skipped_count: 0,
      missing_chunk_count: 0,
      unleased_chunk_count: 0,
      pressure: :none
    }
  end

  defp subscription_plan_summary(result) do
    result.subscription_plan.summary
    |> Map.put(:region_id, result.region_id)
    |> Map.put(:boundary_kind, result.boundary_kind)
  end

  defp route_summary(nil), do: nil

  defp route_summary(route) do
    Map.take(route, [:chunk_coord, :tier, :status, :region_id, :lease_id, :assigned_scene_node])
  end

  defp candidate_region_ids(%{
         subscription_plan: %{partition_window: %{region_summaries: summaries}}
       }) do
    summaries
    |> Enum.map(&Map.get(&1, :region_id))
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp candidate_region_ids(%{region_id: region_id}) when is_integer(region_id), do: [region_id]
  defp candidate_region_ids(_result), do: []

  defp candidate_region_radius(%{subscription_plan: %{partition_window: %{halo_radius: radius}}})
       when is_integer(radius) and radius >= 0,
       do: radius

  defp candidate_region_radius(_result), do: 0

  defp put_last_refresh(state, outcome) do
    Map.put(state, :last_partition_refresh, Map.drop(outcome, [:subscription_diff]))
  end

  defp empty_subscription_diff do
    %{subscribe_chunks: [], unsubscribe_chunks: [], retained_chunks: []}
  end

  defp observe_updated(outcome) do
    outcome
    |> Map.take([
      :cid,
      :logical_scene_id,
      :boundary_kind,
      :previous_region_id,
      :region_id,
      :previous_chunk_coord,
      :chunk_coord,
      :auth_tick,
      :ack_seq,
      :chat_refresh_status,
      :subscription_apply_status
    ])
    |> Map.merge(%{
      subscribe_count: length(outcome.subscription_diff.subscribe_chunks),
      unsubscribe_count: length(outcome.subscription_diff.unsubscribe_chunks),
      retained_count: length(outcome.subscription_diff.retained_chunks)
    })
  end

  defp observe_failure(outcome) do
    Map.take(outcome, [
      :cid,
      :logical_scene_id,
      :boundary_kind,
      :previous_region_id,
      :region_id,
      :previous_chunk_coord,
      :chunk_coord,
      :auth_tick,
      :reason
    ])
  end

  defp observe_skipped(outcome) do
    Map.take(outcome, [
      :cid,
      :logical_scene_id,
      :boundary_kind,
      :previous_region_id,
      :region_id,
      :previous_chunk_coord,
      :chunk_coord,
      :auth_tick,
      :ack_seq,
      :reason
    ])
  end

  defp emit(opts, event, payload) do
    observe_fun = Keyword.get(opts, :observe_fun, &GateServer.CliObserve.emit/2)
    observe_fun.(event, payload)
  end

  defp default_route_window(logical_scene_id, center_chunk, radius) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_window_with_leases, logical_scene_id, center_chunk,
              [near_radius: 0, halo_radius: radius]},
             @default_call_timeout
           ) do
        {:ok, %{route_entries: _route_entries} = window} -> {:ok, window}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp fetch_world_node do
    case safe_call(GateServer.Interface, :world_server, @default_call_timeout) do
      {:ok, nil} -> maybe_local_world_node()
      {:ok, node} when is_atom(node) -> {:ok, node}
      {:error, _reason} -> maybe_local_world_node()
    end
  end

  defp maybe_local_world_node do
    if Application.get_env(:gate_server, :allow_local_world_fallback, false) do
      local_world_node()
    else
      {:error, :world_unavailable}
    end
  end

  defp local_world_node do
    case Process.whereis(WorldServer.Voxel.MapLedger) do
      pid when is_pid(pid) -> {:ok, node()}
      nil -> {:error, :world_unavailable}
    end
  end

  defp safe_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp mapify(%_struct{} = value), do: Map.from_struct(value)
  defp mapify(value) when is_map(value), do: value
end
