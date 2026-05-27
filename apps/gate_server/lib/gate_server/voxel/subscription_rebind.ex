defmodule GateServer.Voxel.SubscriptionRebind do
  @moduledoc """
  Rebinds existing Gate voxel subscriptions after authoritative route changes.

  World remains the route and lease authority. This module only updates one
  connection's subscription handles after a cutover/invalidation says a chunk may
  now belong to a different lease or Scene node.

  If the old Scene has already invalidated the subscriber but the new route or
  subscribe fails, the affected handle is removed from the active subscription
  table and recorded under `:voxel_subscription_rebind_pending`. Gate must not
  keep advertising an invalidated Scene lease as an active stream.
  """

  @scene_call_timeout 15_000

  @doc """
  Rebinds the subscription affected by a migration-cutover invalidate event.

  Non-migration invalidations are ignored; they still invalidate client cache but
  do not imply an owner/lease cutover.
  """
  def apply_cutover_invalidation(state, invalidate_event, opts \\ [])
      when is_map(state) and is_map(invalidate_event) do
    case migration_cutover_chunk(invalidate_event) do
      {:ok, logical_scene_id, chunk_coord} ->
        key = {logical_scene_id, chunk_coord}

        case Map.fetch(Map.get(state, :voxel_subscriptions, %{}), key) do
          {:ok, subscription} ->
            apply_subscription_rebind(
              state,
              key,
              subscription,
              :migration_cutover_invalidate,
              opts
            )

          :error ->
            summary =
              skipped_summary(state, logical_scene_id, chunk_coord, :subscription_not_found)

            emit(opts, "voxel_subscription_rebind_skipped", summary)
            {:ok, state, summary}
        end

      {:skip, reason} ->
        summary = skipped_summary(state, nil, nil, reason)
        {:ok, state, summary}
    end
  end

  @doc """
  Rebinds all active subscriptions selected by logical scene and region.

  This is the manual/debug counterpart of `apply_cutover_invalidation/3`. It
  intentionally uses the same per-subscription implementation so failures keep
  the same pending-recovery semantics as automatic migration cutover handling.
  """
  def rebind_selected_subscriptions(
        state,
        logical_scene_id,
        region_selector \\ :all,
        reason \\ :manual,
        opts \\ []
      )
      when is_map(state) and is_integer(logical_scene_id) do
    pending_entries =
      state
      |> Map.get(:voxel_subscription_rebind_pending, %{})
      |> Map.to_list()

    {status, active_state, active_summary} =
      state
      |> Map.get(:voxel_subscriptions, %{})
      |> Map.to_list()
      |> Enum.reduce({:ok, state, empty_aggregate(state)}, fn {key, subscription},
                                                              {status, acc_state, acc_summary} ->
        if rebind_subscription_selected?(subscription, logical_scene_id, region_selector) do
          case apply_subscription_rebind(acc_state, key, subscription, reason, opts) do
            {:ok, next_state, summary} ->
              {status, next_state, aggregate_summary(acc_summary, summary)}

            {:error, next_state, summary} ->
              {:error, next_state, aggregate_summary(acc_summary, summary)}
          end
        else
          {status, acc_state, acc_summary}
        end
      end)

    Enum.reduce(pending_entries, {status, active_state, active_summary}, fn {key, pending},
                                                                            {status, acc_state,
                                                                             acc_summary} ->
      if pending_rebind_selected?(pending, logical_scene_id, region_selector) do
        case apply_pending_rebind(acc_state, key, pending, reason, opts) do
          {:ok, next_state, summary} ->
            {status, next_state, aggregate_summary(acc_summary, summary)}

          {:error, next_state, summary} ->
            {:error, next_state, aggregate_summary(acc_summary, summary)}
        end
      else
        {status, acc_state, acc_summary}
      end
    end)
  end

  defp apply_subscription_rebind(state, key, subscription, reason, opts) do
    emit_rebind_requested(state, subscription, reason, opts)

    case rebind_subscription(subscription, reason, opts) do
      {:ok, next_subscription, :rebound} ->
        next_state =
          state
          |> put_in([:voxel_subscriptions, key], next_subscription)
          |> refresh_partition_context_after_rebind(next_subscription, reason)

        summary = %{
          status: :rebound,
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: next_subscription.region_id,
          reason: reason,
          rebound_count: 1,
          skipped_count: 0,
          error_count: 0
        }

        emit_completed(next_state, summary, opts)
        {:ok, next_state, summary}

      {:ok, _next_subscription, :skipped} ->
        summary = %{
          status: :skipped,
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: Map.get(subscription, :region_id),
          reason: :already_current,
          rebound_count: 0,
          skipped_count: 1,
          error_count: 0
        }

        emit_completed(state, summary, opts)
        {:ok, state, summary}

      {:error, rebind_reason} ->
        next_state =
          invalidate_failed_subscription(
            state,
            key,
            subscription,
            reason,
            rebind_reason
          )

        summary = %{
          status: :failed,
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: Map.get(subscription, :region_id),
          reason: rebind_reason,
          rebound_count: 0,
          skipped_count: 0,
          error_count: 1,
          invalidated_subscription_count: 1,
          pending_rebind_count: pending_rebind_count(next_state)
        }

        emit(opts, "voxel_subscription_rebind_error", %{
          connection_pid: connection_pid(opts),
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: Map.get(subscription, :region_id),
          reason: rebind_reason,
          active_subscription_removed?: true,
          pending_rebind_count: summary.pending_rebind_count
        })

        emit_completed(next_state, summary, opts)
        {:error, next_state, summary}
    end
  end

  defp apply_pending_rebind(state, key, pending, reason, opts) do
    subscription = subscription_from_pending(pending)
    emit_rebind_requested(state, subscription, reason, opts)

    case rebind_pending_subscription(subscription, reason, opts) do
      {:ok, next_subscription} ->
        next_state =
          state
          |> put_active_subscription(key, next_subscription)
          |> clear_pending_subscription(key)
          |> refresh_partition_context_after_rebind(next_subscription, reason)

        summary = %{
          status: :rebound,
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: next_subscription.region_id,
          reason: reason,
          rebound_count: 1,
          skipped_count: 0,
          error_count: 0,
          pending_rebind_count: pending_rebind_count(next_state)
        }

        emit_completed(next_state, summary, opts)
        {:ok, next_state, summary}

      {:error, rebind_reason} ->
        next_state = update_pending_retry(state, key, pending, reason, rebind_reason)

        summary = %{
          status: :failed,
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: Map.get(subscription, :region_id),
          reason: rebind_reason,
          rebound_count: 0,
          skipped_count: 0,
          error_count: 1,
          invalidated_subscription_count: 0,
          pending_rebind_count: pending_rebind_count(next_state)
        }

        emit(opts, "voxel_subscription_rebind_error", %{
          connection_pid: connection_pid(opts),
          cid: Map.get(state, :cid),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          region_id: Map.get(subscription, :region_id),
          reason: rebind_reason,
          active_subscription_removed?: false,
          pending_rebind_count: summary.pending_rebind_count
        })

        emit_completed(next_state, summary, opts)
        {:error, next_state, summary}
    end
  end

  defp rebind_subscription(subscription, reason, opts) do
    with {:ok, route} <-
           route_chunk(subscription.logical_scene_id, subscription.chunk_coord, opts),
         {:ok, scene_node} <- fetch_scene_node_for_route(route),
         {:ok, lease} <- fetch_lease_for_route(route) do
      emit(opts, "voxel_subscription_rebind_routed", %{
        connection_pid: connection_pid(opts),
        logical_scene_id: subscription.logical_scene_id,
        chunk_coord: subscription.chunk_coord,
        reason: reason,
        old_scene_node: Map.get(subscription, :scene_node),
        new_scene_node: scene_node,
        old_lease_id: Map.get(subscription, :lease_id),
        new_lease_id: lease.lease_id,
        old_owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
        new_owner_scene_instance_ref: lease.owner_scene_instance_ref,
        new_owner_epoch: lease.owner_epoch
      })

      if subscription_matches_route?(subscription, scene_node, lease) do
        emit(opts, "voxel_subscription_rebind_skipped", %{
          connection_pid: connection_pid(opts),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          lease_id: lease.lease_id,
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          owner_epoch: lease.owner_epoch
        })

        {:ok, subscription, :skipped}
      else
        subscribe_rebound(subscription, scene_node, lease, opts)
      end
    end
  end

  defp rebind_pending_subscription(subscription, reason, opts) do
    with {:ok, route} <-
           route_chunk(subscription.logical_scene_id, subscription.chunk_coord, opts),
         {:ok, scene_node} <- fetch_scene_node_for_route(route),
         {:ok, lease} <- fetch_lease_for_route(route) do
      emit(opts, "voxel_subscription_rebind_routed", %{
        connection_pid: connection_pid(opts),
        logical_scene_id: subscription.logical_scene_id,
        chunk_coord: subscription.chunk_coord,
        reason: reason,
        old_scene_node: Map.get(subscription, :scene_node),
        new_scene_node: scene_node,
        old_lease_id: Map.get(subscription, :lease_id),
        new_lease_id: lease.lease_id,
        old_owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
        new_owner_scene_instance_ref: lease.owner_scene_instance_ref,
        new_owner_epoch: lease.owner_epoch
      })

      subscribe_rebound(subscription, scene_node, lease, opts)
      |> case do
        {:ok, next_subscription, :rebound} -> {:ok, next_subscription}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp subscribe_rebound(subscription, scene_node, lease, opts) do
    tier = subscription_delivery_tier(subscription)

    attrs = %{
      request_id: subscription.request_id,
      logical_scene_id: subscription.logical_scene_id,
      chunk_coord: subscription.chunk_coord,
      subscriber: Keyword.get(opts, :subscriber, self()),
      lease: lease,
      delivery_format: :envelope,
      tier: tier,
      send_snapshot?: true,
      known_version: nil
    }

    case scene_call(opts, {SceneServer.Voxel.ChunkDirectory, scene_node}, {:subscribe, attrs}) do
      {:ok, {:ok, _payload}} ->
        maybe_unsubscribe_rebound_source(subscription, scene_node, opts)

        next_subscription =
          Map.merge(subscription, %{
            scene_node: scene_node,
            region_id: lease.region_id,
            lease_id: lease.lease_id,
            owner_scene_instance_ref: lease.owner_scene_instance_ref,
            owner_epoch: lease.owner_epoch,
            tier: tier
          })

        emit(opts, "voxel_subscription_rebind_subscribed_new", %{
          connection_pid: connection_pid(opts),
          logical_scene_id: next_subscription.logical_scene_id,
          chunk_coord: next_subscription.chunk_coord,
          scene_node: next_subscription.scene_node,
          region_id: next_subscription.region_id,
          lease_id: next_subscription.lease_id,
          owner_scene_instance_ref: next_subscription.owner_scene_instance_ref,
          owner_epoch: next_subscription.owner_epoch
        })

        {:ok, next_subscription, :rebound}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _other} ->
        {:error, :scene_unavailable}

      {:error, _reason} ->
        {:error, :scene_unavailable}
    end
  end

  defp maybe_unsubscribe_rebound_source(subscription, new_scene_node, opts) do
    if Map.get(subscription, :scene_node) != new_scene_node do
      scene_unsubscribe(subscription, opts)

      emit(opts, "voxel_subscription_rebind_unsubscribed_old", %{
        connection_pid: connection_pid(opts),
        logical_scene_id: subscription.logical_scene_id,
        chunk_coord: subscription.chunk_coord,
        scene_node: Map.get(subscription, :scene_node),
        lease_id: Map.get(subscription, :lease_id),
        owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
        owner_epoch: Map.get(subscription, :owner_epoch)
      })
    end

    :ok
  end

  defp scene_unsubscribe(subscription, opts) do
    _ =
      scene_call(
        opts,
        {SceneServer.Voxel.ChunkDirectory, Map.fetch!(subscription, :scene_node)},
        {:unsubscribe,
         %{
           logical_scene_id: subscription.logical_scene_id,
           chunk_coord: subscription.chunk_coord,
           subscriber: Keyword.get(opts, :subscriber, self())
         }}
      )

    :ok
  end

  defp migration_cutover_chunk(%{
         reason_name: :migration_cutover,
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord
       }) do
    {:ok, logical_scene_id, coord!(chunk_coord)}
  end

  defp migration_cutover_chunk(%{reason_name: reason_name}),
    do: {:skip, {:not_migration_cutover, reason_name}}

  defp migration_cutover_chunk(_event), do: {:skip, :invalid_invalidate_event}

  defp route_chunk(logical_scene_id, chunk_coord, opts) do
    route_fun = Keyword.fetch!(opts, :route_fun)
    route_fun.(logical_scene_id, chunk_coord)
  end

  defp scene_call(opts, server, message) do
    scene_call_fun = Keyword.get(opts, :scene_call_fun, &safe_call/3)
    scene_call_fun.(server, message, Keyword.get(opts, :scene_call_timeout, @scene_call_timeout))
  end

  defp fetch_scene_node_for_route(%{assignment: %{assigned_scene_node: scene_node}})
       when not is_nil(scene_node),
       do: {:ok, scene_node}

  defp fetch_scene_node_for_route(_route), do: {:error, :scene_node_unassigned}

  defp fetch_lease_for_route(%{lease: lease}) when is_map(lease), do: {:ok, lease}
  defp fetch_lease_for_route(_route), do: {:error, :missing_lease}

  defp subscription_matches_route?(subscription, scene_node, lease) do
    Map.get(subscription, :scene_node) == scene_node and
      Map.get(subscription, :lease_id) == lease.lease_id and
      Map.get(subscription, :owner_scene_instance_ref) == lease.owner_scene_instance_ref and
      Map.get(subscription, :owner_epoch) == lease.owner_epoch
  end

  defp refresh_partition_context_after_rebind(state, subscription, reason) do
    case Map.get(state, :partition_context) do
      %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord} = context
      when logical_scene_id == subscription.logical_scene_id ->
        if coord!(chunk_coord) == subscription.chunk_coord do
          Map.put(
            state,
            :partition_context,
            Map.merge(context, %{
              logical_scene_id: subscription.logical_scene_id,
              region_id: subscription.region_id,
              chunk_coord: subscription.chunk_coord,
              lease_id: subscription.lease_id,
              owner_scene_instance_ref: subscription.owner_scene_instance_ref,
              owner_epoch: subscription.owner_epoch,
              assigned_scene_node: subscription.scene_node,
              boundary_kind: :authority_cutover,
              route_refresh_reason: reason
            })
          )
        else
          state
        end

      _other ->
        state
    end
  end

  defp emit_rebind_requested(state, subscription, reason, opts) do
    emit(opts, "voxel_subscription_rebind_requested", %{
      connection_pid: connection_pid(opts),
      cid: Map.get(state, :cid),
      logical_scene_id: subscription.logical_scene_id,
      region_selector: Map.get(subscription, :region_id),
      reason: reason,
      subscription_count: map_size(Map.get(state, :voxel_subscriptions, %{})),
      pending_rebind_count: pending_rebind_count(state)
    })
  end

  defp emit_completed(state, summary, opts) do
    emit(opts, "voxel_subscription_rebind_completed", %{
      connection_pid: connection_pid(opts),
      cid: Map.get(state, :cid),
      logical_scene_id: summary.logical_scene_id,
      region_selector: Map.get(summary, :region_id),
      reason: Map.get(summary, :reason),
      rebound_count: summary.rebound_count,
      skipped_count: summary.skipped_count,
      error_count: summary.error_count,
      invalidated_subscription_count: Map.get(summary, :invalidated_subscription_count, 0),
      pending_rebind_count: Map.get(summary, :pending_rebind_count, pending_rebind_count(state)),
      subscription_count: map_size(Map.get(state, :voxel_subscriptions, %{}))
    })
  end

  defp rebind_subscription_selected?(subscription, logical_scene_id, region_selector) do
    subscription.logical_scene_id == logical_scene_id and
      (region_selector == :all or Map.get(subscription, :region_id) == region_selector)
  end

  defp pending_rebind_selected?(pending, logical_scene_id, region_selector) do
    Map.get(pending, :logical_scene_id) == logical_scene_id and
      (region_selector == :all or Map.get(pending, :region_id) == region_selector)
  end

  defp empty_aggregate(state) do
    %{
      status: :ok,
      rebound_count: 0,
      skipped_count: 0,
      error_count: 0,
      invalidated_subscription_count: 0,
      pending_rebind_count: pending_rebind_count(state)
    }
  end

  defp aggregate_summary(acc, summary) do
    %{
      acc
      | status: aggregate_status(acc.status, summary.status),
        rebound_count: acc.rebound_count + Map.get(summary, :rebound_count, 0),
        skipped_count: acc.skipped_count + Map.get(summary, :skipped_count, 0),
        error_count: acc.error_count + Map.get(summary, :error_count, 0),
        invalidated_subscription_count:
          acc.invalidated_subscription_count +
            Map.get(summary, :invalidated_subscription_count, 0),
        pending_rebind_count: Map.get(summary, :pending_rebind_count, acc.pending_rebind_count)
    }
  end

  defp aggregate_status(_status, :failed), do: :failed
  defp aggregate_status(:failed, _status), do: :failed
  defp aggregate_status(_status, :rebound), do: :rebound
  defp aggregate_status(:rebound, _status), do: :rebound
  defp aggregate_status(:ok, status), do: status
  defp aggregate_status(status, _status), do: status

  defp invalidate_failed_subscription(state, key, subscription, rebind_reason, failure_reason) do
    pending = %{
      logical_scene_id: subscription.logical_scene_id,
      chunk_coord: subscription.chunk_coord,
      region_id: Map.get(subscription, :region_id),
      old_scene_node: Map.get(subscription, :scene_node),
      old_lease_id: Map.get(subscription, :lease_id),
      old_owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
      old_owner_epoch: Map.get(subscription, :owner_epoch),
      tier: subscription_delivery_tier(subscription),
      request_id: Map.get(subscription, :request_id),
      rebind_reason: rebind_reason,
      reason: failure_reason,
      retry_count: 0,
      invalidated_at_ms: System.system_time(:millisecond)
    }

    state
    |> Map.put(:voxel_subscriptions, Map.delete(Map.get(state, :voxel_subscriptions, %{}), key))
    |> Map.put(
      :voxel_subscription_rebind_pending,
      Map.put(Map.get(state, :voxel_subscription_rebind_pending, %{}), key, pending)
    )
  end

  defp subscription_from_pending(pending) do
    %{
      logical_scene_id: Map.fetch!(pending, :logical_scene_id),
      chunk_coord: coord!(Map.fetch!(pending, :chunk_coord)),
      request_id: Map.get(pending, :request_id),
      scene_node: Map.get(pending, :old_scene_node),
      region_id: Map.get(pending, :region_id),
      lease_id: Map.get(pending, :old_lease_id),
      owner_scene_instance_ref: Map.get(pending, :old_owner_scene_instance_ref),
      owner_epoch: Map.get(pending, :old_owner_epoch),
      tier: Map.get(pending, :tier, :near) || :near
    }
  end

  defp subscription_delivery_tier(subscription), do: Map.get(subscription, :tier, :near) || :near

  defp put_active_subscription(state, key, subscription) do
    Map.put(
      state,
      :voxel_subscriptions,
      Map.put(Map.get(state, :voxel_subscriptions, %{}), key, subscription)
    )
  end

  defp clear_pending_subscription(state, key) do
    pending =
      state
      |> Map.get(:voxel_subscription_rebind_pending, %{})
      |> Map.delete(key)

    if map_size(pending) == 0 do
      Map.put(state, :voxel_subscription_rebind_pending, %{})
    else
      Map.put(state, :voxel_subscription_rebind_pending, pending)
    end
  end

  defp update_pending_retry(state, key, pending, rebind_reason, failure_reason) do
    next_pending =
      pending
      |> Map.put(:rebind_reason, rebind_reason)
      |> Map.put(:reason, failure_reason)
      |> Map.update(:retry_count, 1, &(&1 + 1))
      |> Map.put(:last_retry_at_ms, System.system_time(:millisecond))

    Map.put(
      state,
      :voxel_subscription_rebind_pending,
      Map.put(Map.get(state, :voxel_subscription_rebind_pending, %{}), key, next_pending)
    )
  end

  defp pending_rebind_count(state) do
    state
    |> Map.get(:voxel_subscription_rebind_pending, %{})
    |> map_size()
  end

  defp skipped_summary(state, logical_scene_id, chunk_coord, reason) do
    %{
      status: :skipped,
      cid: Map.get(state, :cid),
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      region_id: nil,
      reason: reason,
      rebound_count: 0,
      skipped_count: 1,
      error_count: 0
    }
  end

  defp emit(opts, event, payload) do
    observe_fun = Keyword.get(opts, :observe_fun, &GateServer.CliObserve.emit/2)
    observe_fun.(event, payload)
  end

  defp connection_pid(opts), do: Keyword.get(opts, :connection_pid, self())

  defp safe_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
end
