defmodule GateServer.Voxel.SubscriptionRuntime do
  @moduledoc """
  Applies Gate-side voxel subscription plans to one connection state.

  World remains the partition and lease authority, and Scene remains the hot
  chunk truth owner. This module only keeps the per-connection subscription
  handles that let a Gate transport process subscribe, unsubscribe, roll back
  partial application, and expose deterministic observe logs.
  """

  alias GateServer.Voxel.{ChunkVersionLedger, DeliveryScheduler}

  @default_call_timeout 15_000

  @doc """
  Applies a `GateServer.Voxel.SubscriptionPlanner` plan to a connection state.

  The operation subscribes new target chunks before unsubscribing removed
  chunks. If a new subscribe fails, newly-created subscriptions are rolled back
  and the previous connection state is returned unchanged.
  """
  def apply_plan(state, plan, opts \\ []) when is_map(state) and is_map(plan) do
    plan = normalize_plan(plan)
    state = Map.put_new(state, :voxel_subscriptions, %{})

    diff =
      Keyword.get(opts, :subscription_diff) ||
        subscription_diff(state, plan, Keyword.get(opts, :diff_mode, :replace))

    entries_by_chunk = entries_by_chunk(plan.subscribe_entries)
    entries_to_subscribe = entries_to_subscribe(diff.subscribe_chunks, entries_by_chunk)

    case subscribe_entries(state, plan, entries_to_subscribe, opts) do
      {:ok, subscribed_state, new_subscriptions} ->
        case promote_retained_subscriptions(
               subscribed_state,
               plan,
               diff.retained_chunks,
               entries_by_chunk,
               opts
             ) do
          {:ok, promoted_state, promotion_summary} ->
            {unsubscribe_count, next_state} =
              unsubscribe_chunks(
                diff.unsubscribe_chunks,
                plan.logical_scene_id,
                promoted_state,
                opts
              )

            next_state =
              clear_forwarded_versions(next_state, plan.logical_scene_id, diff.unsubscribe_chunks)

            next_state =
              clear_queued_delivery(next_state, plan.logical_scene_id, diff.unsubscribe_chunks)

            summary =
              success_summary(
                plan,
                diff,
                length(new_subscriptions),
                unsubscribe_count,
                Keyword.get(opts, :reason, :subscription_plan),
                promotion_summary
              )

            next_state = Map.put(next_state, :voxel_subscription_plan, plan.summary)

            emit(opts, "voxel_subscription_diff_applied", summary)
            {:ok, next_state, summary}

          {:error, reason, failed_state, promotion_summary} ->
            rollback_subscriptions(new_subscriptions, opts)

            summary =
              failure_summary(
                plan,
                diff,
                reason,
                length(new_subscriptions),
                Keyword.get(opts, :reason, :subscription_plan),
                promotion_summary
              )

            emit(opts, "voxel_subscription_diff_failed", summary)
            {:error, failed_state, summary}
        end

      {:error, reason, _failed_state, new_subscriptions} ->
        rollback_subscriptions(new_subscriptions, opts)

        summary =
          failure_summary(
            plan,
            diff,
            reason,
            length(new_subscriptions),
            Keyword.get(opts, :reason, :subscription_plan),
            empty_promotion_summary()
          )

        emit(opts, "voxel_subscription_diff_failed", summary)
        {:error, state, summary}
    end
  rescue
    exception in [ArgumentError, KeyError] ->
      plan_summary = Map.get(plan, :summary, %{})

      summary = %{
        status: :failed,
        cid: Map.get(state, :cid, Map.get(plan_summary, :cid)),
        request_id: Map.get(plan_summary, :request_id),
        logical_scene_id: Map.get(plan_summary, :logical_scene_id),
        reason: {:invalid_subscription_plan, Exception.message(exception)},
        subscribe_count: 0,
        unsubscribe_count: 0,
        retained_count: 0,
        skipped_count: 0
      }

      emit(opts, "voxel_subscription_diff_failed", summary)
      {:error, state, summary}
  end

  @doc """
  Applies the subscription plan embedded in a partition-context result.
  """
  def apply_partition_result(state, %{subscription_plan: nil}, _opts),
    do: {:ok, state, no_plan_summary(state)}

  def apply_partition_result(state, %{subscription_plan: plan}, opts) do
    apply_plan(state, plan, opts)
  end

  defp normalize_plan(plan) do
    summary = Map.fetch!(plan, :summary)
    logical_scene_id = Map.fetch!(summary, :logical_scene_id)

    %{
      cid: Map.get(plan, :cid, Map.get(summary, :cid)),
      request_id: Map.get(plan, :request_id, Map.get(summary, :request_id)),
      logical_scene_id: logical_scene_id,
      subscribe_entries: Map.get(plan, :subscribe_entries, []),
      skipped_entries: Map.get(plan, :skipped_entries, []),
      summary: summary
    }
  end

  defp subscription_diff(state, plan, mode) do
    current_chunks = current_subscription_chunks(state.voxel_subscriptions, plan.logical_scene_id)

    target_chunks =
      plan.subscribe_entries |> Enum.map(&coord!(Map.fetch!(&1, :chunk_coord))) |> MapSet.new()

    subscribe_chunks = sorted_chunks(MapSet.difference(target_chunks, current_chunks))
    retained_chunks = sorted_chunks(MapSet.intersection(current_chunks, target_chunks))

    unsubscribe_chunks =
      case mode do
        :additive -> []
        _replace -> sorted_chunks(MapSet.difference(current_chunks, target_chunks))
      end

    %{
      subscribe_chunks: subscribe_chunks,
      unsubscribe_chunks: unsubscribe_chunks,
      retained_chunks: retained_chunks
    }
  end

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

  defp entries_by_chunk(entries) do
    Map.new(entries, fn entry -> {coord!(Map.fetch!(entry, :chunk_coord)), entry} end)
  end

  defp entries_to_subscribe(chunks, entries_by_chunk) do
    chunks
    |> Enum.flat_map(fn chunk ->
      case Map.fetch(entries_by_chunk, coord!(chunk)) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    end)
  end

  defp subscribe_entries(state, plan, entries, opts) do
    Enum.reduce_while(entries, {:ok, state, []}, fn entry, {:ok, acc_state, new_subscriptions} ->
      case subscribe_entry(acc_state, plan, entry, opts) do
        {:ok, next_state, nil} ->
          {:cont, {:ok, next_state, new_subscriptions}}

        {:ok, next_state, subscription} ->
          {:cont, {:ok, next_state, [subscription | new_subscriptions]}}

        {:error, reason, failed_state} ->
          {:halt, {:error, reason, failed_state, new_subscriptions}}
      end
    end)
  end

  defp promote_retained_subscriptions(state, plan, retained_chunks, entries_by_chunk, opts) do
    Enum.reduce_while(retained_chunks, {:ok, state, empty_promotion_summary()}, fn chunk_coord,
                                                                                   {:ok,
                                                                                    acc_state,
                                                                                    acc_summary} ->
      key = subscription_key(plan.logical_scene_id, coord!(chunk_coord))
      entry = Map.get(entries_by_chunk, coord!(chunk_coord))
      current = Map.get(acc_state.voxel_subscriptions, key)

      case promote_retained_subscription(acc_state, plan, key, current, entry, opts) do
        {:ok, next_state, promotion} ->
          {:cont, {:ok, next_state, merge_promotion_summary(acc_summary, promotion)}}

        {:error, reason, failed_state, promotion} ->
          {:halt, {:error, reason, failed_state, merge_promotion_summary(acc_summary, promotion)}}
      end
    end)
  end

  defp promote_retained_subscription(state, _plan, _key, nil, _entry, _opts),
    do: {:ok, state, empty_promotion_summary()}

  defp promote_retained_subscription(state, _plan, _key, _current, nil, _opts),
    do: {:ok, state, empty_promotion_summary()}

  defp promote_retained_subscription(state, plan, key, current, entry, opts) do
    send_snapshot? = send_snapshot?(entry, opts)
    needs_snapshot? = Map.get(current, :send_snapshot?) == false and send_snapshot?
    promoted? = retained_subscription_promoted?(current, entry, send_snapshot?)

    cond do
      needs_snapshot? ->
        case subscribe_entry(state, plan, entry, opts) do
          {:ok, next_state, _subscription} ->
            {:ok, next_state,
             %{
               promoted_count: if(promoted?, do: 1, else: 0),
               promotion_snapshot_count: 1
             }}

          {:error, reason, failed_state} ->
            {:error, reason, failed_state,
             %{
               promoted_count: 0,
               promotion_snapshot_count: 0
             }}
        end

      promoted? ->
        case refresh_retained_scene_delivery_metadata(state, plan, current, entry, opts) do
          {:ok, refreshed_state} ->
            next_subscription =
              current
              |> Map.merge(%{
                tier: Map.get(entry, :tier),
                priority: Map.get(entry, :priority),
                send_snapshot?: send_snapshot?,
                initial_delivery_mode: Map.get(entry, :initial_delivery_mode),
                snapshot_defer_reason: Map.get(entry, :snapshot_defer_reason),
                requested_bytes: Map.get(entry, :requested_bytes),
                budget_bytes: Map.get(entry, :budget_bytes)
              })

            {:ok, put_in(refreshed_state.voxel_subscriptions[key], next_subscription),
             %{promoted_count: 1, promotion_snapshot_count: 0}}

          {:error, reason, failed_state} ->
            {:error, reason, failed_state,
             %{
               promoted_count: 0,
               promotion_snapshot_count: 0
             }}
        end

      true ->
        {:ok, state, empty_promotion_summary()}
    end
  end

  defp refresh_retained_scene_delivery_metadata(state, plan, current, entry, opts) do
    if retained_scene_delivery_metadata_changed?(current, entry) do
      refresh_scene_subscription_metadata(state, plan, entry, opts)
    else
      {:ok, state}
    end
  end

  defp retained_scene_delivery_metadata_changed?(current, entry) do
    Map.get(current, :tier) != Map.get(entry, :tier)
  end

  defp retained_subscription_promoted?(current, entry, send_snapshot?) do
    retained_subscription_has_delivery_metadata?(current) and
      (Map.get(current, :tier) != Map.get(entry, :tier) or
         Map.get(current, :priority) != Map.get(entry, :priority) or
         Map.get(current, :send_snapshot?) != send_snapshot? or
         Map.get(current, :initial_delivery_mode) != Map.get(entry, :initial_delivery_mode) or
         Map.get(current, :snapshot_defer_reason) != Map.get(entry, :snapshot_defer_reason))
  end

  defp retained_subscription_has_delivery_metadata?(subscription) do
    Map.has_key?(subscription, :tier) or
      Map.has_key?(subscription, :send_snapshot?) or
      Map.has_key?(subscription, :initial_delivery_mode)
  end

  defp subscribe_entry(state, plan, entry, opts) do
    with {:ok, scene_node} <- fetch_scene_node(entry),
         {:ok, lease} <- fetch_lease(entry) do
      chunk_coord = coord!(Map.fetch!(entry, :chunk_coord))
      send_snapshot? = send_snapshot?(entry, opts)

      emit_subscribe_routed(opts, state, plan, entry, lease, send_snapshot?)

      attrs = scene_subscribe_attrs(plan, entry, lease, opts, send_snapshot?)

      case scene_call(opts, {SceneServer.Voxel.ChunkDirectory, scene_node}, {:subscribe, attrs}) do
        {:ok, {:ok, _payload}} ->
          key = subscription_key(plan.logical_scene_id, chunk_coord)
          already_subscribed? = Map.has_key?(state.voxel_subscriptions, key)

          subscription =
            subscription(plan, entry, lease, scene_node, chunk_coord, attrs.send_snapshot?)

          next_state = put_in(state.voxel_subscriptions[key], subscription)
          {:ok, next_state, if(already_subscribed?, do: nil, else: subscription)}

        {:ok, {:error, reason}} ->
          {:error, reason, state}

        {:ok, _other} ->
          {:error, :scene_unavailable, state}

        {:error, _reason} ->
          {:error, :scene_unavailable, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp refresh_scene_subscription_metadata(state, plan, entry, opts) do
    with {:ok, scene_node} <- fetch_scene_node(entry),
         {:ok, lease} <- fetch_lease(entry) do
      emit_subscribe_routed(opts, state, plan, entry, lease, false)

      attrs = scene_subscribe_attrs(plan, entry, lease, opts, false)

      case scene_call(opts, {SceneServer.Voxel.ChunkDirectory, scene_node}, {:subscribe, attrs}) do
        {:ok, {:ok, _payload}} -> {:ok, state}
        {:ok, {:error, reason}} -> {:error, reason, state}
        {:ok, _other} -> {:error, :scene_unavailable, state}
        {:error, _reason} -> {:error, :scene_unavailable, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp scene_subscribe_attrs(plan, entry, lease, opts, send_snapshot?) do
    %{
      request_id: plan.request_id,
      logical_scene_id: plan.logical_scene_id,
      chunk_coord: coord!(Map.fetch!(entry, :chunk_coord)),
      subscriber: Keyword.get(opts, :subscriber, self()),
      lease: lease,
      delivery_format: :envelope,
      tier: Map.get(entry, :tier),
      send_snapshot?: send_snapshot?,
      known_version: Map.get(entry, :known_version_for_scene)
    }
  end

  defp unsubscribe_chunks(chunks, logical_scene_id, state, opts) do
    Enum.reduce(chunks, {0, state}, fn chunk_coord, {count, acc_state} ->
      key = subscription_key(logical_scene_id, coord!(chunk_coord))

      case Map.pop(acc_state.voxel_subscriptions, key) do
        {nil, _subscriptions} ->
          {count, acc_state}

        {subscription, subscriptions} ->
          scene_unsubscribe(subscription, opts)
          {count + 1, Map.put(acc_state, :voxel_subscriptions, subscriptions)}
      end
    end)
  end

  defp rollback_subscriptions(subscriptions, opts) do
    Enum.each(subscriptions, &scene_unsubscribe(&1, opts))
  end

  defp scene_unsubscribe(
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord} = subscription,
         opts
       ) do
    scene_node = Map.fetch!(subscription, :scene_node)

    _ =
      scene_call(
        opts,
        {SceneServer.Voxel.ChunkDirectory, scene_node},
        {:unsubscribe,
         %{
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           subscriber: Keyword.get(opts, :subscriber, self())
         }}
      )

    :ok
  end

  defp fetch_scene_node(%{assigned_scene_node: scene_node}) when not is_nil(scene_node),
    do: {:ok, scene_node}

  defp fetch_scene_node(_entry), do: {:error, :scene_node_unassigned}

  defp fetch_lease(%{lease: lease}) when is_map(lease), do: {:ok, lease}
  defp fetch_lease(_entry), do: {:error, :missing_lease}

  defp send_snapshot?(entry, opts) do
    Keyword.get(opts, :send_snapshot?, true) and Map.get(entry, :send_snapshot?, true)
  end

  defp subscription(plan, entry, lease, scene_node, chunk_coord, send_snapshot?) do
    %{
      logical_scene_id: plan.logical_scene_id,
      chunk_coord: chunk_coord,
      request_id: plan.request_id,
      scene_node: scene_node,
      region_id: Map.get(lease, :region_id, Map.get(entry, :region_id)),
      lease_id: Map.fetch!(lease, :lease_id),
      owner_scene_instance_ref: Map.fetch!(lease, :owner_scene_instance_ref),
      owner_epoch: Map.fetch!(lease, :owner_epoch),
      tier: Map.get(entry, :tier),
      priority: Map.get(entry, :priority),
      send_snapshot?: send_snapshot?,
      initial_delivery_mode: Map.get(entry, :initial_delivery_mode),
      snapshot_defer_reason: Map.get(entry, :snapshot_defer_reason),
      requested_bytes: Map.get(entry, :requested_bytes),
      budget_bytes: Map.get(entry, :budget_bytes)
    }
  end

  defp emit_subscribe_routed(opts, state, plan, entry, lease, send_snapshot?) do
    emit(opts, "voxel_chunk_subscribe_routed", %{
      connection_pid: self(),
      cid: Map.get(state, :cid, plan.cid),
      request_id: plan.request_id,
      logical_scene_id: plan.logical_scene_id,
      center_chunk: entry.chunk_coord,
      region_id: Map.get(entry, :region_id, Map.get(lease, :region_id)),
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      tier: Map.get(entry, :tier),
      priority: Map.get(entry, :priority),
      send_snapshot?: send_snapshot?,
      initial_delivery_mode: Map.get(entry, :initial_delivery_mode),
      snapshot_defer_reason: Map.get(entry, :snapshot_defer_reason)
    })
  end

  defp success_summary(
         plan,
         diff,
         subscribe_count,
         unsubscribe_count,
         reason,
         promotion_summary
       ) do
    %{
      status: :applied,
      cid: plan.cid,
      request_id: plan.request_id,
      logical_scene_id: plan.logical_scene_id,
      reason: reason,
      subscribe_count: subscribe_count,
      unsubscribe_count: unsubscribe_count,
      retained_count: length(diff.retained_chunks),
      skipped_count: length(plan.skipped_entries),
      requested_chunk_count: Map.get(plan.summary, :requested_chunk_count, 0),
      pressure: Map.get(plan.summary, :pressure, :none),
      initial_snapshot_count: initial_snapshot_count(plan),
      ghost_subscription_count: ghost_subscription_count(plan),
      promoted_count: promotion_summary.promoted_count,
      promotion_snapshot_count: promotion_summary.promotion_snapshot_count
    }
  end

  defp failure_summary(plan, diff, reason, subscribe_count, apply_reason, promotion_summary) do
    %{
      status: :failed,
      cid: plan.cid,
      request_id: plan.request_id,
      logical_scene_id: plan.logical_scene_id,
      reason: reason,
      apply_reason: apply_reason,
      subscribe_count: subscribe_count,
      unsubscribe_count: 0,
      retained_count: length(diff.retained_chunks),
      skipped_count: length(plan.skipped_entries),
      requested_chunk_count: Map.get(plan.summary, :requested_chunk_count, 0),
      pressure: Map.get(plan.summary, :pressure, :none),
      initial_snapshot_count: initial_snapshot_count(plan),
      ghost_subscription_count: ghost_subscription_count(plan),
      promoted_count: promotion_summary.promoted_count,
      promotion_snapshot_count: promotion_summary.promotion_snapshot_count
    }
  end

  defp empty_promotion_summary, do: %{promoted_count: 0, promotion_snapshot_count: 0}

  defp merge_promotion_summary(left, right) do
    %{
      promoted_count: left.promoted_count + right.promoted_count,
      promotion_snapshot_count: left.promotion_snapshot_count + right.promotion_snapshot_count
    }
  end

  defp initial_snapshot_count(plan) do
    Map.get(
      plan.summary,
      :initial_snapshot_count,
      Enum.count(plan.subscribe_entries, &Map.get(&1, :send_snapshot?, true))
    )
  end

  defp ghost_subscription_count(plan) do
    Map.get(
      plan.summary,
      :ghost_subscription_count,
      Enum.count(plan.subscribe_entries, &(Map.get(&1, :initial_delivery_mode) == :halo_ghost))
    )
  end

  defp no_plan_summary(state) do
    %{
      status: :skipped,
      cid: Map.get(state, :cid),
      request_id: nil,
      logical_scene_id: nil,
      reason: :no_subscription_plan,
      subscribe_count: 0,
      unsubscribe_count: 0,
      retained_count: 0,
      skipped_count: 0
    }
  end

  defp clear_forwarded_versions(
         %{forwarded_chunk_versions: ledger} = state,
         logical_scene_id,
         chunks
       ) do
    ledger =
      Enum.reduce(chunks, ledger, fn chunk_coord, acc ->
        ChunkVersionLedger.clear_chunk(acc, logical_scene_id, coord!(chunk_coord))
      end)

    Map.put(state, :forwarded_chunk_versions, ledger)
  end

  defp clear_forwarded_versions(state, _logical_scene_id, _chunks), do: state

  defp clear_queued_delivery(%{voxel_delivery: scheduler} = state, logical_scene_id, chunks) do
    Map.put(
      state,
      :voxel_delivery,
      DeliveryScheduler.prune_chunks(scheduler, logical_scene_id, chunks)
    )
  end

  defp clear_queued_delivery(state, _logical_scene_id, _chunks), do: state

  defp scene_call(opts, server, message) do
    call_fun = Keyword.get(opts, :scene_call_fun, &default_scene_call/3)
    timeout = Keyword.get(opts, :call_timeout, @default_call_timeout)
    call_fun.(server, message, timeout)
  end

  defp default_scene_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp emit(opts, event, payload) do
    observe_fun = Keyword.get(opts, :observe_fun, &GateServer.CliObserve.emit/2)
    observe_fun.(event, payload)
  end

  defp subscription_key(logical_scene_id, chunk_coord), do: {logical_scene_id, chunk_coord}

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
end
