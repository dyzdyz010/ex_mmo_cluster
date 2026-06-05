defmodule GateServer.WsConnection do
  @moduledoc """
  Per-client GenServer for one browser WebSocket session.

  This mirrors the TCP connection state machine (`waiting_auth -> authenticated -> in_scene`)
  but emits encoded payloads back to the WebSocket owner process instead of writing to a TCP socket.
  """

  use GenServer, restart: :temporary
  require Logger

  @topic {:gate, __MODULE__}
  @scope :connection

  alias GateServer.{ChatAdapter, ChatScope}
  alias GateServer.{PartitionRefresh, PartitionRuntime}

  alias GateServer.Voxel.{
    ChunkVersionLedger,
    ClientAckLedger,
    DeliveryEnvelope,
    DeliveryScheduler,
    PrefabLocalTransaction,
    SubscriptionPlanner,
    SubscriptionRebind,
    SubscriptionRuntime
  }

  alias SceneServer.Combat.{EffectEvent, Skill}
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}
  alias SceneServer.Voxel.Field.FieldRuntime
  alias SceneServer.Voxel.{NormalBlockData, PrefabRaster, Types}

  @scene_call_timeout 15_000
  @max_voxel_subscribe_radius 4
  @prefab_owner_part_id 1
  @max_prefab_owner_object_id 0x7FFF_FFFF_FFFF_FFFF
  @partition_bootstrap_retry_delay_ms 500
  @partition_bootstrap_retry_max_attempts 60
  @max_priority_movement_input_drain 16

  @doc "Starts a browser WebSocket-backed gate session."
  def start_link(owner_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, owner_pid, opts)
  end

  @doc "Forward one binary frame received from the browser WebSocket."
  def receive_frame(connection_pid, payload) when is_pid(connection_pid) and is_binary(payload) do
    GenServer.cast(connection_pid, {:ws_frame, payload})
  end

  @doc "Notify the gate session that the browser WebSocket closed."
  def close(connection_pid, reason \\ :normal) when is_pid(connection_pid) do
    GenServer.cast(connection_pid, {:ws_closed, reason})
  end

  @doc "Re-routes existing voxel subscriptions after a World migration cutover."
  def rebind_voxel_subscriptions(
        connection_pid,
        logical_scene_id,
        region_selector \\ :all,
        reason \\ :manual
      )
      when is_pid(connection_pid) do
    GenServer.cast(
      connection_pid,
      {:voxel_rebind_subscriptions, logical_scene_id, region_selector, reason}
    )
  end

  @impl true
  def init(owner_pid) when is_pid(owner_pid) do
    ensure_pg_scope_started()
    :pg.join(@scope, @topic, self())
    outbound_pid = start_ws_outbound_writer(owner_pid, self())
    movement_ack_pid = start_movement_ack_sender(outbound_pid, self())

    GateServer.CliObserve.emit("ws_connection_init", %{
      connection_pid: self(),
      owner_pid: owner_pid,
      outbound_pid: outbound_pid,
      movement_ack_pid: movement_ack_pid
    })

    {:ok,
     %{
       owner_pid: owner_pid,
       outbound_pid: outbound_pid,
       movement_ack_pid: movement_ack_pid,
       cid: -1,
       agent: nil,
       auth_claims: nil,
       auth_username: nil,
       auth_session_id: nil,
       scene_ref: nil,
       scene_monitor_ref: nil,
       token: nil,
       status: :waiting_auth,
       chat_session_joined?: false,
       chat_context: nil,
       partition_context: nil,
       last_partition_refresh: nil,
       voxel_subscriptions: %{},
       forwarded_chunk_versions: ChunkVersionLedger.new(),
       client_ack_versions: ClientAckLedger.new(),
       voxel_subscription_plan: nil,
       voxel_delivery: DeliveryScheduler.new(),
       voxel_delivery_timer_ref: nil,
       partition_refresh_generation: 0,
       partition_refresh_pending: nil
     }}
  end

  defp ensure_pg_scope_started do
    case :pg.start_link(@scope) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  @impl true
  def handle_cast({:ws_frame, data}, state) do
    {:noreply, handle_ws_frame_payload(data, state)}
  end

  def handle_cast({:ws_closed, reason}, state) do
    stop_reason = normalize_close_reason(reason)

    GateServer.CliObserve.emit("ws_closed", %{
      connection_pid: self(),
      cid: state.cid,
      reason: stop_reason
    })

    {:stop, stop_reason, state}
  end

  def handle_cast({:voxel_rebind_subscriptions, logical_scene_id, region_selector, reason}, state) do
    {_status, next_state, result} =
      rebind_voxel_subscriptions_in_state(state, logical_scene_id, region_selector, reason)

    GateServer.CliObserve.emit("voxel_subscription_rebind_aggregate_completed", %{
      connection_pid: self(),
      cid: state.cid,
      logical_scene_id: logical_scene_id,
      region_selector: region_selector,
      reason: reason,
      rebound_count: result.rebound_count,
      skipped_count: result.skipped_count,
      error_count: result.error_count,
      invalidated_subscription_count: Map.get(result, :invalidated_subscription_count, 0),
      pending_rebind_count: Map.get(result, :pending_rebind_count, 0),
      subscription_count: map_size(next_state.voxel_subscriptions)
    })

    {:noreply, next_state}
  end

  def handle_cast({:player_enter, cid, location}, state) do
    GateServer.CliObserve.emit("ws_player_enter_push", %{
      connection_pid: self(),
      observer_cid: state.cid,
      cid: cid,
      location: location
    })

    send_encoded(state, {:player_enter, cid, location})
    {:noreply, state}
  end

  def handle_cast({:player_leave, cid}, state) do
    GateServer.CliObserve.emit("ws_player_leave_push", %{
      connection_pid: self(),
      observer_cid: state.cid,
      cid: cid
    })

    send_encoded(state, {:player_leave, cid})
    {:noreply, state}
  end

  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, state) do
    GateServer.CliObserve.emit("ws_actor_identity_push", %{
      connection_pid: self(),
      observer_cid: state.cid,
      cid: cid,
      actor_kind: actor_kind,
      actor_name: actor_name
    })

    send_encoded(state, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  def handle_cast({:player_move, snapshot}, state) do
    snapshot = normalize_remote_snapshot(snapshot)
    server_send_ms = :os.system_time(:millisecond)

    GateServer.CliObserve.emit("ws_player_move_push", fn ->
      %{
        cid: snapshot.cid,
        server_tick: snapshot.server_tick,
        priority_band: snapshot.priority_band,
        priority_score: snapshot.priority_score,
        observer_distance: snapshot.observer_distance,
        delivery_interval: snapshot.delivery_interval
      }
    end)

    send_encoded(state, player_move_message(snapshot, server_send_ms))

    {:noreply, state}
  end

  def handle_cast({:movement_ack, ack}, state) do
    send_movement_ack_payload(state.outbound_pid, self(), ack, "ws_movement_ack_push", false)

    {:noreply, schedule_partition_refresh_after_movement_ack(state, ack)}
  end

  def handle_cast({:chat_message, cid, username, text}, state) do
    send_encoded(state, {:chat_message, cid, username, text})
    {:noreply, state}
  end

  def handle_cast({:skill_event, cid, skill_id, location}, state) do
    send_encoded(state, {:skill_event, cid, skill_id, location})
    {:noreply, state}
  end

  def handle_cast({:player_state, cid, hp, max_hp, alive}, state) do
    send_encoded(state, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        state
      ) do
    send_encoded(
      state,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    {:noreply, state}
  end

  def handle_cast({:effect_event, %EffectEvent{} = effect_event}, state) do
    send_encoded(
      state,
      {:effect_event, effect_event.source_cid, effect_event.skill_id, effect_event.cue_kind,
       effect_event.origin, effect_event.target_cid, effect_event.target_position,
       effect_event.radius, effect_event.duration_ms}
    )

    {:noreply, state}
  end

  defp handle_ws_frame_payload(data, state) do
    GateServer.CliObserve.emit("ws_receive", fn ->
      %{connection_pid: self(), bytes: byte_size(data), status: state.status}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        GateServer.CliObserve.emit("ws_decoded", fn ->
          %{connection_pid: self(), message: observe_message_summary(msg)}
        end)

        {:ok, new_state} = dispatch(msg, state)
        new_state

      {:error, reason} ->
        Logger.debug("WS codec decode rejected payload: #{inspect(reason)}")
        send_result_error(state, reason, 0)
        state
    end
  end

  defp drain_pending_movement_inputs(state, limit \\ @max_priority_movement_input_drain)
  defp drain_pending_movement_inputs(state, limit) when limit <= 0, do: state

  defp drain_pending_movement_inputs(state, limit) do
    receive do
      {:"$gen_cast", {:ws_frame, <<0x01, _rest::binary>> = data}} ->
        data
        |> handle_ws_frame_payload(state)
        |> drain_pending_movement_inputs(limit - 1)
    after
      0 ->
        state
    end
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, :process, scene_ref, reason},
        %{scene_monitor_ref: monitor_ref, scene_ref: scene_ref} = state
      ) do
    GateServer.CliObserve.emit("ws_scene_ref_down", %{
      connection_pid: self(),
      owner_pid: state.owner_pid,
      cid: state.cid,
      scene_ref: inspect(scene_ref),
      reason: inspect(reason)
    })

    send(state.owner_pid, {:gate_ws_close, :scene_ref_down})

    {:stop, :normal,
     %{
       state
       | scene_ref: nil,
         scene_monitor_ref: nil,
         status: :authenticated,
         partition_context: nil,
         last_partition_refresh: nil,
         voxel_subscriptions: %{},
         voxel_subscription_plan: nil,
         voxel_delivery: DeliveryScheduler.new(),
         voxel_delivery_timer_ref: nil,
         partition_refresh_pending: nil
     }}
  end

  def handle_info({:voxel_chunk_snapshot_payload, payload}, state) when is_binary(payload) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_data(state, :snapshot, payload)}
  end

  def handle_info({:voxel_chunk_delta_payload, payload}, state) when is_binary(payload) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_data(state, :delta, payload)}
  end

  def handle_info({:voxel_chunk_invalidate_payload, payload}, state) when is_binary(payload) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_invalidate(state, payload)}
  end

  def handle_info(:voxel_delivery_window, state) do
    state = drain_pending_movement_inputs(state)

    scheduler =
      state
      |> Map.get(:voxel_delivery)
      |> DeliveryScheduler.ensure()
      |> DeliveryScheduler.reset_window()

    {scheduler, actions} = DeliveryScheduler.drain(scheduler)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> Map.put(:voxel_delivery_timer_ref, nil)
      |> send_live_voxel_actions(actions)
      |> maybe_schedule_voxel_delivery_window()

    {:noreply, state}
  end

  def handle_info({:voxel_object_state_delta_payload, payload}, state) when is_binary(payload) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_data(state, :object_state_delta, payload)}
  end

  def handle_info({:voxel_field_region_snapshot_payload, payload}, state)
      when is_binary(payload) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_data(state, :field_region_snapshot, payload)}
  end

  def handle_info({:voxel_field_region_destroyed_payload, payload}, state)
      when is_binary(payload) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_data(state, :field_region_destroyed, payload)}
  end

  def handle_info({:voxel_delivery_envelope, envelope}, state) when is_map(envelope) do
    state = drain_pending_movement_inputs(state)
    {:noreply, handle_live_voxel_envelope(state, envelope)}
  end

  def handle_info({:partition_refresh_completed, generation, auth_tick, result}, state) do
    case PartitionRefresh.apply_completed(state, generation, auth_tick, result) do
      {:applied, next_state, event} ->
        GateServer.CliObserve.emit("gate_partition_refresh_applied", event)
        {:noreply, next_state}

      {:ignored, next_state, event} ->
        GateServer.CliObserve.emit("gate_partition_refresh_dropped", event)
        {:noreply, next_state}
    end
  end

  def handle_info({:partition_bootstrap_retry, ack, attempt}, %{status: :in_scene} = state) do
    next_state =
      if partition_refresh_resolved?(state) do
        state
      else
        refresh_partition_after_movement_ack(state, ack, attempt)
      end

    {:noreply, next_state}
  end

  def handle_info({:partition_bootstrap_retry, _ack, _attempt}, state), do: {:noreply, state}

  def handle_info({:movement_ack_fast_path_sent, ack}, state) do
    {:noreply, schedule_partition_refresh_after_movement_ack(state, ack)}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_movement_ack_sender(Map.get(state, :movement_ack_pid))
    cleanup_ws_outbound_writer(Map.get(state, :outbound_pid))
    cleanup_scene_monitor(state.scene_monitor_ref)
    cleanup_voxel_subscriptions(state)
    cleanup_chat_session(state)
    cleanup_scene(state.scene_ref)
    :ok
  end

  defp dispatch(
         {:movement_input, frame_params},
         %{status: :in_scene, scene_ref: spid} = state
       ) do
    frame = build_input_frame(frame_params)

    case accept_movement_input(spid, frame) do
      :accepted -> :ok
      {:error, reason} -> send_result_error(state, reason, frame.seq)
    end

    {:ok, state}
  end

  defp dispatch({:movement_input, frame_params}, state) do
    frame = build_input_frame(frame_params)
    send_result_error(state, :invalid_state, frame.seq)
    {:ok, state}
  end

  defp dispatch(
         {:enter_scene, cid, request_id},
         %{status: :authenticated, auth_claims: claims} = state
       ) do
    timestamp = :os.system_time(:millisecond)

    with :ok <- authorize_cid(claims, cid),
         {:ok, character} <- fetch_authorized_character(claims, cid),
         {:ok, scene_node} <- fetch_scene_node(),
         {:ok, ppid} <-
           add_player(
             scene_node,
             cid,
             timestamp,
             build_character_profile(character),
             state.movement_ack_pid
           ),
         {:ok, {x, y, z}} <- fetch_player_location(ppid),
         {:ok, expected_seq} <- fetch_next_input_seq(ppid) do
      send_encoded(state, {:enter_scene_result, :ok, request_id, {x, y, z}, expected_seq})

      bootstrap_context = ChatAdapter.context_from_character(character, {x, y, z})

      chat_context =
        join_chat_session(
          cid,
          state.auth_username || "anonymous",
          bootstrap_context
        )

      next_state =
        %{
          state
          | cid: cid,
            status: :in_scene,
            chat_session_joined?: not is_nil(chat_context),
            chat_context: chat_context,
            partition_context: initial_partition_context(bootstrap_context),
            agent: with_active_cid(state.agent, cid)
        }
        |> attach_scene_ref(ppid)
        |> refresh_partition_after_movement_ack(partition_bootstrap_ack(cid, {x, y, z}))

      {:ok, next_state}
    else
      {:error, reason} ->
        send_enter_scene_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:enter_scene, _cid, request_id}, state) do
    send_enter_scene_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch({:chat_say, text, request_id}, %{status: :in_scene} = state) do
    publish_chat(:world, text, request_id, state)
  end

  defp dispatch({:chat_say_scoped, scope, text, request_id}, %{status: :in_scene} = state) do
    publish_chat(scope, text, request_id, state)
  end

  defp dispatch({:chat_say_scoped, _scope, _text, request_id}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch({:chat_say, _text, request_id}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(
         {:time_sync, request_id, client_send_ts},
         %{status: status} = state
       )
       when status in [:authenticated, :in_scene] do
    server_recv_ts = :os.system_time(:millisecond)
    server_send_ts = :os.system_time(:millisecond)

    send_encoded(
      state,
      {:time_sync_reply, request_id, client_send_ts, server_recv_ts, server_send_ts}
    )

    {:ok, state}
  end

  defp dispatch({:time_sync, request_id, _client_send_ts}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch({:fast_lane_request, request_id}, state) do
    send_encoded(state, {:fast_lane_result, :error, request_id})
    {:ok, state}
  end

  defp dispatch({:heartbeat, _timestamp}, state) do
    send_encoded(state, {:heartbeat_reply, :os.system_time(:millisecond)})
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_subscribe, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk
    })

    state = drain_pending_movement_inputs(state)

    case subscribe_voxel_chunks(request, state) do
      {:ok, next_state, result} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_ok", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_count: result.chunk_count,
          subscribed_chunk_count: result.subscribed_chunk_count,
          subscription_count: map_size(next_state.voxel_subscriptions)
        })

        {:ok, drain_pending_movement_inputs(next_state)}

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
        {:ok, drain_pending_movement_inputs(state)}
    end
  end

  defp dispatch({:voxel_chunk_subscribe, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, %{status: :in_scene} = state) do
    {unsubscribed_count, next_state} = unsubscribe_voxel_chunks(request, state)

    GateServer.CliObserve.emit("ws_voxel_chunk_unsubscribe_ok", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      requested_count: length(request.chunks),
      unsubscribed_count: unsubscribed_count,
      subscription_count: map_size(next_state.voxel_subscriptions)
    })

    send_encoded(state, {:result, :ok, request.request_id})
    {:ok, next_state}
  end

  defp dispatch({:voxel_chunk_unsubscribe, request}, state) do
    send_result_error(state, :invalid_state, request.request_id)
    {:ok, state}
  end

  defp dispatch({:voxel_chunk_ack, request}, %{status: :in_scene} = state) do
    {next_state, summary} = record_client_ack_versions(state, request)

    GateServer.CliObserve.emit("ws_voxel_chunk_ack_recorded", fn ->
      Map.merge(summary, %{
        connection_pid: self(),
        cid: state.cid,
        transport: :websocket,
        request_id: request.request_id
      })
    end)

    if summary.rejected_count == 0 do
      send_encoded(state, {:result, :ok, request.request_id})
    else
      send_result_error(state, :client_ack_rejected, request.request_id)
    end

    {:ok, next_state}
  end

  defp dispatch({:voxel_chunk_ack, request}, state) do
    send_result_error(state, :invalid_state, request.request_id)
    {:ok, state}
  end

  # DEPRECATED for client-side direct edit; protocol §13.6 / §13.6.1.
  # Use VoxelEditIntent (0x70) for typed client edits. This handler stays for
  # the skill/tool-system flow (and existing client-side wiring) until 1c
  # removes it.
  defp dispatch({:voxel_impact_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_impact_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_skill_id: request.source_skill_id,
      target_world_micro: request.target_world_micro,
      impact_kind: request.impact_kind
    })

    case apply_voxel_impact_intent(request, state) do
      {:ok, result} ->
        GateServer.CliObserve.emit("ws_voxel_impact_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro
        })

        send_encoded(state, voxel_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_impact_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_impact_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  # VoxelEditIntent (0x70) — typed client edit channel; protocol §13.6.1.
  # Phase 1c routing: dispatch the typed request to ChunkDirectory.apply_intent
  # via the standard World map-ledger lease path, then reply with the
  # `VoxelIntentResult` (0x68) frame.
  defp dispatch({:voxel_edit_intent, request}, %{status: :in_scene} = state) do
    emit_voxel_edit_intent_received(request, state)

    case apply_voxel_edit_intent(request, state) do
      {:ok, result} ->
        GateServer.CliObserve.emit("ws_voxel_edit_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: result.chunk_coord,
          chunk_version: result.chunk_version,
          macro: result.macro,
          operation: result.operation
        })

        send_encoded(state, voxel_edit_intent_result_ok(request, result))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_edit_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: reason
        })

        send_encoded(state, voxel_edit_intent_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_edit_intent, request}, state) do
    GateServer.CliObserve.emit("ws_voxel_edit_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state, voxel_edit_intent_result_error(request, :invalid_state))

    {:ok, state}
  end

  defp dispatch({:voxel_field_conduct_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      source_world_macro: request.source_world_macro,
      target_world_macro: request.target_world_macro,
      conduction_mode: request.conduction_mode
    })

    case apply_voxel_field_conduct_intent(request, state) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          region_id: Map.get(summary, :region_id),
          field_region_created: Map.get(summary, :field_region_created),
          conduction_mode: Map.get(summary, :conduction_mode, request.conduction_mode)
        })

        send_encoded(state, voxel_field_conduct_result_ok(request, summary))

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          reason: inspect(reason)
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_field_conduct_intent, request}, state) do
    GateServer.CliObserve.emit("ws_voxel_field_conduct_intent_dropped_invalid_state", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      status: state.status
    })

    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_build_reservation_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_build_reservation_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        parcel_id: request.parcel_id,
        ttl_ms: request.ttl_ms
      }
    end)

    send_encoded(state, voxel_intent_stub_accepted(request))
    {:ok, state}
  end

  defp dispatch({:voxel_build_reservation_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  # Real `0x67 PrefabPlaceIntent` dispatch.
  #
  # The handler resolves `blueprint_id` + anchor through
  # `SceneServer.Voxel.PrefabRaster`, then loops the produced macro-cell list
  # cell-by-cell through `WorldServer.Voxel.MapLedger.route_chunk_with_lease/3`
  # and `SceneServer.Voxel.ChunkDirectory.apply_intent/2`, the exact same path
  # as `0x64 VoxelImpactIntent`. Each successful apply already pushes a
  # `ChunkDelta` to existing subscribers via `ChunkProcess`, so the
  # block-by-block reveal happens automatically.
  #
  # v1 deliberately does not provide cross-chunk atomicity: if the first cell
  # is accepted and a later cell is rejected (lease lost mid-prefab, world
  # routing flaps, etc.) the partial writes already persisted are NOT rolled
  # back. The dispatch records the partial-write summary in observe events
  # and returns `:rejected` to the client. v2 will replace this with a
  # `BuildTransactionApplier`-style two-phase commit.
  defp dispatch({:voxel_prefab_place_intent, request}, %{status: :in_scene} = state) do
    GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_received", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        client_intent_seq: request.client_intent_seq,
        logical_scene_id: request.logical_scene_id,
        parcel_id: request.parcel_id,
        blueprint_id: request.blueprint_id,
        blueprint_version: request.blueprint_version,
        rotation: request.rotation
      }
    end)

    case apply_voxel_prefab_place_intent(request, state) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_applied", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          cell_count: summary.cell_count,
          chunk_count: summary.chunk_count,
          max_chunk_version: summary.max_chunk_version
        })

        send_encoded(state, voxel_prefab_result_ok(request, summary))

      {:error, %{reason: reason} = failure} ->
        GateServer.CliObserve.emit("ws_voxel_prefab_place_intent_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          reason: reason,
          applied_cell_count: failure.applied_cell_count,
          total_cell_count: failure.total_cell_count
        })

        send_encoded(state, voxel_result_error(request, reason))
    end

    {:ok, state}
  end

  defp dispatch({:voxel_prefab_place_intent, request}, state) do
    send_encoded(state, voxel_result_error(request, :invalid_state))
    {:ok, state}
  end

  defp dispatch({:voxel_debug_probe, %{request_id: request_id, command: command}}, state) do
    GateServer.CliObserve.emit("ws_voxel_debug_probe_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request_id,
      command: command,
      status: state.status
    })

    {result, next_state} = handle_voxel_debug_command(command, state)

    send_encoded(state, {:voxel_debug_probe, %{request_id: request_id, result: result}})

    {:ok, next_state}
  end

  defp dispatch(
         {:auth_request, username, code, request_id},
         %{status: :waiting_auth} = state
       ) do
    with {:ok, claims} <- verify_token(code),
         :ok <- validate_username_claim(claims, username) do
      auth_context = build_auth_context(username, code, claims)
      send_encoded(state, {:result, :ok, request_id})

      {:ok,
       %{
         state
         | agent: auth_context,
           auth_claims: claims,
           auth_username: username,
           auth_session_id: Map.get(auth_context, "session_id"),
           token: code,
           status: :authenticated
       }}
    else
      {:error, reason} ->
        send_result_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp dispatch({:auth_request, _username, _code, request_id}, state) do
    send_result_error(state, :invalid_state, request_id)
    {:ok, state}
  end

  defp dispatch(_msg, state) do
    send_result_error(state, :unknown_message, 0)
    {:ok, state}
  end

  defp publish_chat(scope, text, request_id, state) do
    case ChatScope.derive(scope, state) do
      {:ok, chat_target} ->
        publish_chat_to_target(chat_target, text, request_id, state)

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_chat_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id,
          scope: scope,
          reason: reason
        })

        send_result_error(state, reason, request_id)
        {:ok, state}
    end
  end

  defp publish_chat_to_target(chat_target, text, request_id, state) do
    GateServer.CliObserve.emit("ws_chat_received", %{
      connection_pid: self(),
      cid: state.cid,
      username: state.auth_username,
      request_id: request_id,
      scope: chat_target.scope,
      channel: inspect(chat_target.channel),
      text: text
    })

    case ChatAdapter.publish(%{
           cid: state.cid,
           username: state.auth_username,
           logical_scene_id: chat_target.logical_scene_id,
           channel: chat_target.channel,
           text: text
         }) do
      {:ok, summary} ->
        GateServer.CliObserve.emit("ws_chat_forwarded", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id,
          message_id: summary.message_id,
          scope: chat_target.scope,
          channel: inspect(summary.channel),
          recipient_count: summary.recipient_count
        })

        send_encoded(state, {:result, :ok, request_id})

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_chat_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request_id,
          reason: reason
        })

        send_result_error(state, reason, request_id)
    end

    {:ok, state}
  end

  defp send_encoded(state, message) do
    {:ok, iodata} = GateServer.Codec.encode(message)
    # This GenServer's concrete transport boundary is the WebSocket owner
    # handoff; lower-level network write acks are outside this process today.
    send_ws_payload(state, iodata)
  end

  defp send_ws_payload(%{outbound_pid: outbound_pid}, payload) when is_pid(outbound_pid) do
    send(outbound_pid, {:gate_ws_send, IO.iodata_to_binary(payload)})
    :ok
  end

  defp send_ws_payload(%{owner_pid: owner_pid}, payload) when is_pid(owner_pid) do
    send(owner_pid, {:gate_ws_send, IO.iodata_to_binary(payload)})
    :ok
  end

  defp verify_token(token) do
    case fetch_auth_node() do
      {:error, _reason} = error ->
        error

      {:ok, auth_node} ->
        case :rpc.call(auth_node, AuthServer.AuthWorker, :verify_token, [token]) do
          {:ok, claims} when is_map(claims) -> {:ok, claims}
          {:error, :mismatch} -> {:error, :mismatch}
          {:badrpc, _reason} -> {:error, :auth_unavailable}
          _ -> {:error, :server_error}
        end
    end
  end

  defp fetch_auth_node do
    case safe_call(GateServer.Interface, :auth_server) do
      {:ok, nil} -> {:error, :auth_unavailable}
      {:ok, auth_node} -> {:ok, auth_node}
      {:error, _reason} -> {:error, :auth_unavailable}
    end
  end

  defp fetch_scene_node do
    case safe_call(GateServer.Interface, :scene_server) do
      {:ok, nil} -> {:error, :scene_unavailable}
      {:ok, scene_node} -> {:ok, scene_node}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_world_node do
    case safe_call(GateServer.Interface, :world_server) do
      {:ok, nil} -> {:error, :world_unavailable}
      {:ok, world_node} -> {:ok, world_node}
      {:error, _reason} -> {:error, :world_unavailable}
    end
  end

  defp join_chat_session(cid, username, context) do
    case ChatAdapter.join(%{
           cid: cid,
           username: username,
           connection_pid: self(),
           logical_scene_id: context.logical_scene_id,
           region_id: context.region_id,
           chunk_coord: context.chunk_coord,
           location: context.location
         }) do
      {:ok, session} ->
        GateServer.CliObserve.emit("ws_chat_session_joined", %{
          connection_pid: self(),
          cid: cid,
          logical_scene_id: session.logical_scene_id,
          region_id: session.region_id,
          chunk_coord: session.chunk_coord
        })

        Map.take(session, [:logical_scene_id, :region_id, :chunk_coord])

      {:error, reason} ->
        emit_chat_session_join_failed(cid, reason)
        nil
    end
  end

  defp initial_partition_context(context) do
    Map.take(context, [:logical_scene_id, :region_id, :chunk_coord])
  end

  defp partition_bootstrap_ack(cid, location) do
    %{
      cid: cid,
      ack_seq: 0,
      auth_tick: 0,
      position: location
    }
  end

  defp emit_chat_session_join_failed(cid, reason) do
    GateServer.CliObserve.emit("ws_chat_session_join_failed", %{
      connection_pid: self(),
      cid: cid,
      reason: reason
    })
  end

  defp add_player(scene_node, cid, timestamp, character_profile, movement_ack_pid) do
    character_profile = Map.put(character_profile, :movement_ack_pid, movement_ack_pid)

    case safe_call(
           {SceneServer.PlayerManager, scene_node},
           {:add_player, cid, self(), timestamp, character_profile},
           @scene_call_timeout
         ) do
      {:ok, {:ok, ppid}} -> {:ok, ppid}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp fetch_player_location(player_pid) do
    case safe_call(player_pid, :get_location, @scene_call_timeout) do
      {:ok, {:ok, location}} -> {:ok, location}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  # See tcp_connection.fetch_next_input_seq for the audit B-S1 / B-SRV1
  # rationale.
  defp fetch_next_input_seq(player_pid) do
    case safe_call(player_pid, :get_next_input_seq, @scene_call_timeout) do
      {:ok, {:ok, seq}} -> {:ok, seq}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  defp cleanup_scene(nil), do: :ok
  defp cleanup_scene(scene_ref), do: safe_call(scene_ref, :exit)

  defp cleanup_scene_monitor(nil), do: :ok

  defp cleanup_scene_monitor(monitor_ref) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
  end

  defp attach_scene_ref(state, scene_ref) when is_pid(scene_ref) do
    cleanup_scene_monitor(Map.get(state, :scene_monitor_ref))

    %{
      state
      | scene_ref: scene_ref,
        scene_monitor_ref: Process.monitor(scene_ref)
    }
  end

  defp cleanup_chat_session(%{chat_session_joined?: true, cid: cid})
       when is_integer(cid) and cid >= 0 do
    ChatAdapter.leave(cid)
  end

  defp cleanup_chat_session(_state), do: :ok

  defp authorize_cid(nil, _cid), do: {:error, :invalid_state}

  defp authorize_cid(claims, cid) do
    case apply(AuthServer.AuthWorker, :validate_cid, [claims, cid]) do
      :ok -> :ok
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
      {:error, _reason} -> {:error, :server_error}
    end
  end

  defp fetch_authorized_character(claims, cid) do
    with {:ok, auth_node} <- fetch_auth_node() do
      case :rpc.call(auth_node, AuthServer.AuthWorker, :fetch_authorized_character, [claims, cid]) do
        {:ok, character} when is_map(character) -> {:ok, character}
        {:error, :account_not_found} -> {:error, :cid_mismatch}
        {:error, :cid_mismatch} -> {:error, :cid_mismatch}
        {:error, :data_service_unavailable} -> {:error, :auth_unavailable}
        {:badrpc, _reason} -> {:error, :auth_unavailable}
        _ -> {:error, :server_error}
      end
    end
  end

  defp build_character_profile(character) when is_map(character) do
    %{
      cid: Map.get(character, :id) || Map.get(character, "id"),
      name:
        Map.get(character, :name) || Map.get(character, "name") ||
          "character-#{Map.get(character, :id) || Map.get(character, "id")}",
      position:
        normalize_position(Map.get(character, :position) || Map.get(character, "position"))
    }
  end

  defp build_character_profile(_character),
    do: %{name: "unknown", position: {750.0, 750.0, 185.0}}

  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  # Movement world coords use server Z as vertical. The browser maps this spawn
  # to x=750,y=100,z=750, above DevSeed's voxel y=0 platform centered at x/z =
  # 750 in renderer units.
  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 750.0)
    y = map_float(position, ["y", :y], 750.0)
    z = map_float(position, ["z", :z], 185.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {750.0, 750.0, 185.0}

  defp map_float(map, keys, default) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) end)
    |> case do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp validate_username_claim(claims, username) do
    apply(AuthServer.AuthWorker, :validate_username, [claims, username])
  end

  defp safe_call(server, message, timeout \\ @scene_call_timeout)
  defp safe_call(nil, _message, _timeout), do: {:error, :unavailable}

  defp safe_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp send_result_error(state, _reason, request_id) do
    send_encoded(state, {:result, :error, request_id})
  end

  defp send_enter_scene_error(state, _reason, request_id) do
    send_encoded(state, {:enter_scene_result, :error, request_id})
  end

  defp build_auth_context(username, token, claims) do
    %{
      "username" => username,
      "token" => token,
      "session_id" => Map.get(claims, "session_id") || Map.get(claims, :session_id),
      "source" => Map.get(claims, "source") || Map.get(claims, :source),
      "claims" => claims
    }
  end

  defp with_active_cid(auth_context, cid) when is_map(auth_context) do
    Map.put(auth_context, "active_cid", cid)
  end

  defp with_active_cid(auth_context, _cid), do: auth_context

  defp accept_movement_input(spid, frame) do
    try do
      # Browser movement input must not block this connection's downlink path or
      # flood the player actor mailbox. The scene actor drains this buffer on
      # its authoritative fixed tick and sends movement_ack from that tick.
      SceneServer.PlayerCharacter.submit_movement_input(spid, frame)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp route_voxel_chunk(logical_scene_id, chunk_coord) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_chunk_with_lease, logical_scene_id, chunk_coord},
             @scene_call_timeout
           ) do
        {:ok, {:ok, route}} -> {:ok, route}
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp route_voxel_chunks(logical_scene_id, chunk_coords) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_chunks_with_leases, logical_scene_id, chunk_coords},
             @scene_call_timeout
           ) do
        {:ok, {:ok, routes}} -> {:ok, routes}
        {:ok, {:error, _reason}} -> {:error, :no_route_for_chunk}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp route_voxel_partition_window(logical_scene_id, center_chunk, radius) do
    with {:ok, world_node} <- fetch_world_node() do
      case safe_call(
             {WorldServer.Voxel.MapLedger, world_node},
             {:route_window_with_leases, logical_scene_id, center_chunk,
              [near_radius: 0, halo_radius: radius]},
             @scene_call_timeout
           ) do
        {:ok, %{route_entries: _route_entries} = window} -> {:ok, window}
        {:ok, _other} -> {:error, :world_unavailable}
        {:error, _reason} -> {:error, :world_unavailable}
      end
    end
  end

  defp apply_voxel_impact_intent(request, state) do
    with :ok <- authorize_voxel_impact_intent(request, state),
         {:ok, target} <- voxel_impact_target(request),
         :ok <- authorize_voxel_target(state, request.logical_scene_id, target.chunk_coord),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_impact_intent_routed", %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: target.chunk_coord,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs =
        %{
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: target.chunk_coord,
          lease: lease,
          macro: target.local_macro
        }
        |> Map.merge(voxel_impact_op_attrs(request))

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:apply_intent, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, reply}} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro})}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp fetch_scene_node_for_route(%{assignment: %{assigned_scene_node: scene_node}})
       when not is_nil(scene_node),
       do: {:ok, scene_node}

  defp fetch_scene_node_for_route(_route), do: {:error, :scene_node_unassigned}

  defp authorize_voxel_impact_intent(request, state) do
    cond do
      not is_integer(state.cid) or state.cid <= 0 ->
        {:error, :cid_mismatch}

      true ->
        case Skill.fetch(request.source_skill_id) do
          {:ok, _skill} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp voxel_impact_target(%{target_world_micro: {wx, wy, wz}}) do
    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(wx, micro_resolution),
      Types.floor_div(wy, micro_resolution),
      Types.floor_div(wz, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, %{chunk_coord: chunk_coord, local_macro: local_macro}}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp voxel_impact_block(request) do
    NormalBlockData.new(request.impact_kind,
      health: 100,
      state_flags: request.source_skill_id
    )
  end

  # Wire convention: `impact_kind == 0` is the break sentinel — the cell
  # gets cleared back to empty mode (delta_kind 0 CellEmpty on the wire).
  # Any non-zero `impact_kind` is treated as a `material_id` for a put-solid
  # write (delta_kind 1 CellSolid).
  defp voxel_impact_op_attrs(%{impact_kind: 0}), do: %{operation: :break_block}

  defp voxel_impact_op_attrs(request) do
    %{operation: :put_solid_block, block: voxel_impact_block(request)}
  end

  defp emit_voxel_edit_intent_received(request, state) do
    GateServer.CliObserve.emit("ws_voxel_edit_intent_received", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      action: request.action,
      target_granularity: request.target_granularity,
      target_world_micro: request.target_world_micro,
      face_normal: request.face_normal,
      material_id: request.material_id,
      blueprint_ref: request.blueprint_ref,
      object_ref: request.object_ref,
      part_ref: request.part_ref,
      attribute_patch_ref: request.attribute_patch_ref,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash,
      client_hint_hash: request.client_hint_hash
    })
  end

  defp apply_voxel_edit_intent(request, state) do
    with :ok <- authorize_voxel_edit_intent(state),
         {:ok, op} <- voxel_edit_intent_op(request),
         {:ok, target} <- voxel_edit_intent_target(request, op),
         :ok <- authorize_voxel_target(state, request.logical_scene_id, target.chunk_coord),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_edit_intent_routed", %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        action: request.action,
        target_granularity: request.target_granularity,
        operation: op.operation,
        chunk_coord: target.chunk_coord,
        local_macro: target.local_macro,
        adjusted_world_micro: target.adjusted_world_micro,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs = build_voxel_edit_intent_attrs(request, op, target, lease)

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:apply_intent, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, reply}} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro, operation: op.operation})}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp authorize_voxel_edit_intent(state) do
    if is_integer(state.cid) and state.cid > 0 do
      :ok
    else
      {:error, :cid_mismatch}
    end
  end

  defp apply_voxel_field_conduct_intent(request, state) do
    with :ok <- authorize_voxel_edit_intent(state),
         {:ok, source_chunk_coord} <- field_conduct_source_chunk(request),
         {:ok, target_chunk_coord} <- field_conduct_target_chunk(request),
         :ok <-
           authorize_voxel_chunks(state, request.logical_scene_id, [
             source_chunk_coord,
             target_chunk_coord
           ]),
         {:ok, route} <- route_voxel_chunk(request.logical_scene_id, source_chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      attrs =
        request
        |> Map.take([
          :logical_scene_id,
          :source_world_macro,
          :target_world_macro,
          :source_potential,
          :max_ticks,
          :conduction_mode,
          :output_mode,
          :voltage,
          :current_limit_amps,
          :frequency_hz,
          :load_current_amps,
          :energy_budget_joules
        ])
        |> Map.put(:owner_ref, {:ws_field_conduct, state.cid, request.client_intent_seq})

      case :rpc.call(
             scene_node,
             FieldRuntime,
             :ensure_conduction_path,
             [attrs],
             @scene_call_timeout
           ) do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
        {:badrpc, reason} -> {:error, {:scene_unavailable, reason}}
        other -> {:error, {:unexpected_field_conduct_result, other}}
      end
    end
  end

  defp field_conduct_source_chunk(%{source_world_macro: world_macro}) do
    {chunk_coord, _local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, chunk_coord}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_source_world_macro}
  end

  defp field_conduct_target_chunk(%{target_world_macro: world_macro}) do
    {chunk_coord, _local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, chunk_coord}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_macro}
  end

  # Decision 3 / Phase 1c: action × target_granularity → Scene operation.
  # ObjectPart granularity is rejected for the supported actions; Damage /
  # Replace / AttributePatch are rejected wholesale until the Phase 5 attribute
  # catalog work lands.
  defp voxel_edit_intent_op(%{action: action}) when action in [2, 3, 4] do
    {:error, :action_not_implemented}
  end

  defp voxel_edit_intent_op(%{action: action, target_granularity: 2}) when action in [0, 1] do
    {:error, :granularity_object_part_not_implemented}
  end

  defp voxel_edit_intent_op(%{action: 0, target_granularity: 0} = request) do
    {:ok, %{operation: :put_solid_block, block: voxel_edit_intent_block(request)}}
  end

  defp voxel_edit_intent_op(%{action: 0, target_granularity: 1} = request) do
    case voxel_edit_intent_micro_layer(request) do
      {:ok, micro_layer} ->
        {:ok, %{operation: :put_micro_block, micro_layer: micro_layer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp voxel_edit_intent_op(%{action: 1, target_granularity: 0}) do
    {:ok, %{operation: :break_block}}
  end

  defp voxel_edit_intent_op(%{action: 1, target_granularity: 1}) do
    {:ok, %{operation: :clear_micro_block}}
  end

  defp voxel_edit_intent_op(_request), do: {:error, :invalid_voxel_edit_intent}

  defp voxel_edit_intent_block(request) do
    NormalBlockData.new(request.material_id,
      attribute_set_ref: request.attribute_patch_ref
    )
  end

  defp voxel_edit_intent_micro_layer(request) do
    with {:ok, owner_object_id} <- voxel_edit_owner_object_id(request.object_ref) do
      {:ok,
       %{
         material_id: request.material_id,
         attribute_set_ref: request.attribute_patch_ref,
         owner_object_id: owner_object_id,
         owner_part_id: request.part_ref
       }}
    end
  end

  # owner_object_id is a u63 (`MicroLayer.@type`); the wire field is u64. The
  # high bit is reserved for future use, so reject values that don't fit.
  defp voxel_edit_owner_object_id(value)
       when is_integer(value) and value >= 0 and value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: {:ok, value}

  defp voxel_edit_owner_object_id(_value), do: {:error, :invalid_object_ref}

  # Decision 6 / Phase 1c: Place actions consume `face_normal` here at the Gate
  # by offsetting `target_world_micro` by one micro slot in the direction of
  # the hit face. Break actions ignore `face_normal` — the resolved cell is
  # the one the client clicked.
  defp voxel_edit_intent_target(request, %{operation: operation}) do
    {wx, wy, wz} = request.target_world_micro
    {fnx, fny, fnz} = request.face_normal

    {ax, ay, az} =
      case operation do
        :put_solid_block -> {wx + fnx, wy + fny, wz + fnz}
        :put_micro_block -> {wx + fnx, wy + fny, wz + fnz}
        _other -> {wx, wy, wz}
      end

    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(ax, micro_resolution),
      Types.floor_div(ay, micro_resolution),
      Types.floor_div(az, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    local_micro = {
      Types.floor_mod(ax, micro_resolution),
      Types.floor_mod(ay, micro_resolution),
      Types.floor_mod(az, micro_resolution)
    }

    {:ok,
     %{
       chunk_coord: chunk_coord,
       local_macro: local_macro,
       local_micro: local_micro,
       adjusted_world_micro: {ax, ay, az}
     }}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp build_voxel_edit_intent_attrs(request, op, target, lease) do
    base = %{
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      chunk_coord: target.chunk_coord,
      lease: lease,
      operation: op.operation,
      macro: target.local_macro,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash
    }

    base
    |> maybe_put(:block, Map.get(op, :block))
    |> maybe_put(:micro_layer, Map.get(op, :micro_layer))
    |> maybe_put_micro_slot(op, target)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_micro_slot(map, %{operation: op}, target)
       when op in [:put_micro_block, :clear_micro_block] do
    Map.put(map, :micro_slot, Types.micro_index!(target.local_micro))
  end

  defp maybe_put_micro_slot(map, _op, _target), do: map

  # `:stale_chunk_version` and `:stale_cell_hash` come back from
  # `ChunkProcess.validate_intent_preconditions/2` and map to the protocol
  # `Stale` (3) `VoxelIntentResult` code. Everything else is a generic
  # `Rejected` (2). Successful applies use `:accepted` (0).
  defp voxel_edit_intent_result_code(:stale_chunk_version), do: :stale
  defp voxel_edit_intent_result_code(:stale_cell_hash), do: :stale
  defp voxel_edit_intent_result_code(_reason), do: :rejected

  defp voxel_edit_intent_result_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: voxel_edit_intent_result_code(reason),
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp voxel_edit_intent_result_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  defp apply_voxel_prefab_place_intent(request, state) do
    with :ok <- authorize_voxel_prefab_place_intent(state),
         {:ok, owner_object_id} <- allocate_prefab_owner_object_id(),
         {:ok, cells} <-
           PrefabRaster.rasterize(
             request.blueprint_id,
             request.blueprint_version,
             request.anchor_world_micro,
             request.rotation,
             owner_object_id: owner_object_id,
             owner_part_id: @prefab_owner_part_id
           ) do
      run_prefab_transaction(cells, request, state, owner_object_id)
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp authorize_voxel_prefab_place_intent(state) do
    if is_integer(state.cid) and state.cid > 0 do
      :ok
    else
      {:error, :cid_mismatch}
    end
  end

  defp allocate_prefab_owner_object_id do
    case DataService.Voxel.SceneObjectStore.next_object_id() do
      {:ok, object_id}
      when is_integer(object_id) and object_id > 0 and object_id <= @max_prefab_owner_object_id ->
        {:ok, object_id}

      {:ok, _object_id} ->
        {:error, :invalid_allocated_object_id}

      {:error, _reason} ->
        {:error, :object_id_unavailable}
    end
  rescue
    _exception -> {:error, :object_id_unavailable}
  catch
    :exit, _reason -> {:error, :object_id_unavailable}
  end

  # Single-chunk prefabs stay on the Scene hot path and call
  # ChunkDirectory.apply_intents/2 directly. Multi-chunk prefabs that still
  # resolve to one concrete Scene chunk-directory owner use a local
  # prepare/commit/abort runner. Split-owner prefabs still go through World's
  # TransactionCoordinator + TransactionExecutor so the whole prefab commits
  # atomically across every participant.
  defp run_prefab_transaction([], _request, _state, _owner_object_id) do
    {:ok, %{cell_count: 0, chunk_count: 0, max_chunk_version: 0}}
  end

  defp run_prefab_transaction(cells, request, state, owner_object_id) do
    total = length(cells)

    with {:ok, plan} <- build_prefab_plan(cells, request, state, owner_object_id) do
      case single_chunk_prefab_plan(plan) do
        {:ok, participant, chunk_coord, intents} ->
          apply_single_chunk_prefab_fast_path(
            participant,
            plan,
            chunk_coord,
            intents,
            request,
            state,
            total
          )

        :error ->
          case same_owner_prefab_plan(plan) do
            {:ok, participants} ->
              apply_same_owner_prefab_fast_path(participants, plan, request, state, total)

            :error ->
              with {:ok, coordinator_ref} <- locate_voxel_transaction_coordinator(),
                   {:ok, transaction} <-
                     coordinator_begin_transaction(coordinator_ref, plan, request),
                   {:ok, executor_result} <-
                     executor_execute(coordinator_ref, transaction, plan) do
                finalize_prefab_outcome(executor_result, plan, total)
              end
          end
      end
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  # Bulk route chunks through World, then group by concrete Scene owner
  # `{chunk_directory, assigned_scene_node}`. Each participant still carries
  # `chunk_owners` so the real `{region_id, lease_id}` owner of every chunk is
  # preserved for object-owner metadata.
  defp build_prefab_plan(cells, request, state, owner_object_id) do
    cells_by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    chunk_coords = Map.keys(cells_by_chunk)

    case chunk_coords do
      [] ->
        {:error, :empty_prefab}

      coords ->
        with :ok <- authorize_voxel_chunks(state, request.logical_scene_id, coords),
             {:ok, routes_by_chunk} <- route_all_chunks(request.logical_scene_id, coords),
             {:ok, participants} <-
               build_prefab_participants(routes_by_chunk, cells_by_chunk, request),
             {:ok, scene_object} <-
               build_prefab_scene_object(
                 request,
                 state,
                 owner_object_id,
                 coords,
                 cells,
                 participants
               ) do
          emit_prefab_routed_observe(request, state, participants, length(cells))

          {:ok,
           %{
             participants: participants,
             chunk_coords: Enum.sort(coords),
             scene_object: scene_object,
             scene_objects: [scene_object]
           }}
        end
    end
  end

  defp build_prefab_scene_object(
         request,
         state,
         owner_object_id,
         chunk_coords,
         cells,
         participants
       ) do
    covered_chunks = Enum.sort(chunk_coords)

    with {:ok, owner} <- prefab_scene_object_owner(covered_chunks, participants),
         {:ok, covered_by_region} <- prefab_covered_chunks_by_region(covered_chunks, participants) do
      {:ok,
       %{
         object_id: owner_object_id,
         logical_scene_id: request.logical_scene_id,
         parcel_id: Map.get(request, :parcel_id, 0),
         blueprint_id: request.blueprint_id,
         blueprint_version: request.blueprint_version,
         anchor_world_micro: request.anchor_world_micro,
         rotation: request.rotation,
         owner_actor_id: state.cid,
         state_flags: 0,
         object_attribute_ref: 0,
         object_tag_set_ref: 0,
         covered_chunks: covered_chunks,
         covered_chunks_by_region: covered_by_region,
         part_states: [
           %{part_id: @prefab_owner_part_id, health: length(cells), state_flags: 0}
         ],
         object_version: 1,
         owner_region_id: owner.region_id,
         owner_lease_id: owner.lease_id
       }}
    end
  end

  defp prefab_scene_object_owner([], _participants), do: {:error, :invalid_covered_chunks}

  defp prefab_scene_object_owner(covered_chunks, participants) do
    first_chunk = covered_chunks |> Enum.sort() |> List.first()

    case Enum.find(participants, fn participant -> first_chunk in participant.chunk_coords end) do
      nil ->
        {:error, :scene_object_owner_undeterminable}

      participant ->
        case Map.fetch(participant.chunk_owners, first_chunk) do
          {:ok, {region_id, lease_id}} -> {:ok, %{region_id: region_id, lease_id: lease_id}}
          :error -> {:error, {:missing_chunk_owner, first_chunk}}
        end
    end
  end

  defp prefab_covered_chunks_by_region(covered_chunks, participants) do
    chunk_to_owner =
      participants
      |> Enum.flat_map(fn participant ->
        Enum.map(participant.chunk_coords, fn coord ->
          {coord, Map.fetch!(participant.chunk_owners, coord)}
        end)
      end)
      |> Map.new()

    covered_chunks
    |> Enum.reduce_while({:ok, []}, fn coord, {:ok, acc} ->
      case Map.fetch(chunk_to_owner, coord) do
        {:ok, owner} -> {:cont, {:ok, [{coord, owner} | acc]}}
        :error -> {:halt, {:error, {:missing_chunk_owner, coord}}}
      end
    end)
    |> case do
      {:ok, pairs} ->
        {:ok,
         pairs
         |> Enum.reverse()
         |> Enum.group_by(fn {_coord, owner} -> owner end, fn {coord, _owner} -> coord end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_all_chunks(logical_scene_id, chunk_coords) do
    route_voxel_chunks(logical_scene_id, chunk_coords)
  end

  defp build_prefab_participants(routes_by_chunk, cells_by_chunk, request) do
    routed_chunks =
      Enum.reduce_while(routes_by_chunk, {:ok, []}, fn {coord, route}, {:ok, acc} ->
        case fetch_scene_node_for_route(route) do
          {:ok, scene_node} ->
            lease = Map.fetch!(route, :lease)
            directory = voxel_chunk_directory_module_for({lease.region_id, lease.lease_id})
            {:cont, {:ok, [{coord, route, scene_node, directory} | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, routed_chunks} <- routed_chunks do
      chunks_by_owner =
        Enum.group_by(
          routed_chunks,
          fn {_coord, _route, scene_node, directory} -> {directory, scene_node} end,
          fn {coord, route, _scene_node, _directory} -> {coord, route} end
        )

      chunks_by_owner
      |> Enum.reduce_while({:ok, []}, fn {{directory, scene_node}, entries}, {:ok, acc} ->
        chunks = entries |> Enum.map(fn {coord, _route} -> coord end) |> Enum.sort()

        first_route =
          entries
          |> Enum.sort_by(fn {coord, _route} -> coord end)
          |> List.first()
          |> elem(1)

        case build_prefab_participant(
               {directory, scene_node},
               chunks,
               first_route,
               routes_by_chunk,
               cells_by_chunk,
               request
             ) do
          {:ok, participant} -> {:cont, {:ok, [participant | acc]}}
        end
      end)
      |> case do
        {:ok, participants} -> {:ok, Enum.reverse(participants)}
        {:error, _} = err -> err
      end
    end
  end

  defp build_prefab_participant(
         {directory, scene_node},
         chunks,
         first_route,
         routes_by_chunk,
         cells_by_chunk,
         request
       ) do
    lease = Map.fetch!(first_route, :lease)
    chunks_sorted = Enum.sort(chunks)

    chunk_owners =
      Map.new(chunks_sorted, fn chunk_coord ->
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)
        {chunk_coord, {chunk_lease.region_id, chunk_lease.lease_id}}
      end)

    intents_by_chunk =
      chunks_sorted
      |> Enum.map(fn chunk_coord ->
        cells_in_chunk = Map.fetch!(cells_by_chunk, chunk_coord)
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)

        {chunk_coord, prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, chunk_lease)}
      end)
      |> Map.new()

    participant = %{
      participant_key: {:scene_owner, directory, scene_node},
      lease: lease,
      scene_node: scene_node,
      assigned_scene_node: scene_node,
      chunk_directory_module: directory,
      chunk_coords: chunks_sorted,
      chunk_owners: chunk_owners,
      intents_by_chunk: intents_by_chunk
    }

    {:ok, participant}
  end

  defp prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, lease) do
    Enum.map(cells_in_chunk, fn cell ->
      %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        lease: lease,
        operation: :put_micro_block,
        macro: cell.local_macro,
        micro_slot: cell.micro_slot,
        micro_layer: cell.layer_attrs,
        opts: [reject_occupied: true, return_snapshot_payload: false]
      }
    end)
  end

  defp single_chunk_prefab_plan(%{participants: [participant], chunk_coords: [chunk_coord]}) do
    case Map.fetch(participant.intents_by_chunk, chunk_coord) do
      {:ok, intents} -> {:ok, participant, chunk_coord, intents}
      :error -> :error
    end
  end

  defp single_chunk_prefab_plan(_plan), do: :error

  defp same_owner_prefab_plan(%{participants: [_ | _] = participants, chunk_coords: chunk_coords})
       when length(chunk_coords) > 1 do
    case participants |> Enum.map(&prefab_chunk_directory_ref/1) |> Enum.uniq() do
      [_single_owner] -> {:ok, participants}
      _multiple_owners -> :error
    end
  end

  defp same_owner_prefab_plan(_plan), do: :error

  defp apply_single_chunk_prefab_fast_path(
         participant,
         plan,
         chunk_coord,
         intents,
         request,
         state,
         total
       ) do
    started_at = System.monotonic_time(:millisecond)
    chunk_directory = single_chunk_prefab_directory(participant)

    GateServer.CliObserve.emit("ws_voxel_prefab_single_chunk_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_coord: chunk_coord,
        cell_count: total,
        region_id: participant.lease.region_id,
        lease_id: participant.lease.lease_id,
        scene_node: participant.scene_node
      }
    end)

    case SceneServer.Voxel.ChunkDirectory.apply_intents(chunk_directory, intents) do
      {:ok, summary} ->
        register_prefab_scene_object(plan, participant)

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        GateServer.CliObserve.emit("ws_voxel_prefab_single_chunk_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            changed_count: Map.get(summary, :changed_count, 0),
            skipped_count: Map.get(summary, :skipped_count, 0),
            chunk_version: Map.get(summary, :chunk_version, 0),
            persist_result: Map.get(summary, :persist_result),
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: 1,
           max_chunk_version: Map.get(summary, :chunk_version, 0)
         }}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        GateServer.CliObserve.emit("ws_voxel_prefab_single_chunk_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  defp single_chunk_prefab_directory(participant) do
    prefab_chunk_directory_ref(participant)
  end

  defp apply_same_owner_prefab_fast_path(participants, plan, request, state, total) do
    started_at = System.monotonic_time(:millisecond)
    transaction_id = unique_prefab_transaction_id(request)
    chunk_directory = prefab_chunk_directory_ref(List.first(participants))

    GateServer.CliObserve.emit("ws_voxel_prefab_same_owner_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: length(plan.chunk_coords),
        participant_count: length(participants),
        cell_count: total,
        chunk_directory: inspect(chunk_directory)
      }
    end)

    case PrefabLocalTransaction.execute(
           participants,
           transaction_id,
           request.logical_scene_id,
           &prefab_chunk_directory_ref/1
         ) do
      {:ok, %{participant_results: participant_results}} ->
        register_prefab_scene_object(plan, List.first(participants))

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        max_version = max_chunk_version_from_results(participant_results)

        GateServer.CliObserve.emit("ws_voxel_prefab_same_owner_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            max_chunk_version: max_version,
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      {:error, %{reason: raw_reason} = error} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        reason = unwrap_prepare_reason(raw_reason)

        GateServer.CliObserve.emit("ws_voxel_prefab_same_owner_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: state.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error,
         %{
           reason: reason || Map.get(error, :reason, :prefab_same_owner_fast_path_failed),
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp register_prefab_scene_object(%{scene_object: scene_object}, %{scene_node: scene_node}) do
    case :rpc.call(
           scene_node,
           SceneServer.Voxel.BuildTransactionApplier,
           :register_scene_objects,
           [[scene_object], []],
           5_000
         ) do
      :ok ->
        :ok

      other ->
        GateServer.CliObserve.emit("ws_voxel_prefab_scene_object_register_failed", fn ->
          %{
            object_id: Map.get(scene_object, :object_id),
            logical_scene_id: Map.get(scene_object, :logical_scene_id),
            reason: inspect(other)
          }
        end)

        :ok
    end
  end

  defp register_prefab_scene_object(_plan, _participant), do: :ok

  defp prefab_chunk_directory_ref(%{chunk_directory_module: module, scene_node: scene_node}) do
    {module, scene_node}
  end

  defp prefab_chunk_directory_ref(%{participant_key: participant_key, scene_node: scene_node}) do
    module = voxel_chunk_directory_module_for(participant_key)
    {module, scene_node}
  end

  defp emit_prefab_routed_observe(request, state, participants, cell_count) do
    GateServer.CliObserve.emit("ws_voxel_prefab_routed", fn ->
      %{
        connection_pid: self(),
        cid: state.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: Enum.reduce(participants, 0, fn p, acc -> acc + length(p.chunk_coords) end),
        cell_count: cell_count,
        participant_count: length(participants),
        participants:
          Enum.map(participants, fn p ->
            %{
              participant_key: inspect(p.participant_key),
              region_id: p.lease.region_id,
              lease_id: p.lease.lease_id,
              owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
              owner_epoch: p.lease.owner_epoch,
              scene_node: p.scene_node,
              chunk_owner_count: map_size(p.chunk_owners),
              chunk_count: length(p.chunk_coords)
            }
          end)
      }
    end)
  end

  # Phase 3 D5 calls for `BeaconServer.Client.lookup(:voxel_transaction_coordinator)`
  # directly, but Gate's existing service discovery already routes through
  # `GateServer.Interface` (whose internals are BeaconServer-backed), and the
  # gate test fixtures intercept that entry point via `FakeInterface`. Going
  # through `fetch_world_node/0` keeps the test mock surface stable while
  # preserving the same lookup semantics (single coordinator per world node,
  # 1:1 with `:world_server` resource). Recorded as a deliberate refinement
  # in the Phase 3 progress log.
  defp locate_voxel_transaction_coordinator do
    case fetch_world_node() do
      {:ok, world_node} ->
        {:ok, {WorldServer.Voxel.TransactionCoordinator, world_node}}

      {:error, _reason} ->
        {:error, :voxel_transaction_coordinator_unavailable}
    end
  end

  defp coordinator_begin_transaction(coordinator_ref, plan, request) do
    transaction_id = unique_prefab_transaction_id(request)

    attrs = %{
      logical_scene_id: request.logical_scene_id,
      parcel_id: Map.get(request, :parcel_id, 0),
      reservation_id: prefab_reservation_id(request),
      decision_version: 1,
      participants:
        Enum.map(plan.participants, fn p ->
          %{
            participant_key: p.participant_key,
            region_id: p.lease.region_id,
            lease_id: p.lease.lease_id,
            owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
            owner_epoch: p.lease.owner_epoch,
            assigned_scene_node: p.assigned_scene_node,
            chunk_owners: p.chunk_owners,
            affected_chunks: p.chunk_coords
          }
        end),
      scene_objects: Map.get(plan, :scene_objects, [])
    }

    try do
      case WorldServer.Voxel.TransactionCoordinator.begin_transaction(
             coordinator_ref,
             transaction_id,
             attrs
           ) do
        {:ok, transaction} -> {:ok, transaction}
        {:error, reason} -> {:error, {:coordinator_begin_failed, reason}}
      end
    catch
      :exit, _reason -> {:error, :coordinator_unavailable}
    end
  end

  # plan.participants 已经按 Scene owner 分组,这里直接把每个 participant 的
  # intents_by_chunk + scene_node 摊成 by-participant 两份 map 喂给 executor。
  # 单 Scene-owner participant 可以包含多个 region/lease;chunk_owners 保留
  # 真实 owner。
  defp executor_execute(coordinator_ref, transaction, plan) do
    intents_by_participant =
      plan.participants
      |> Enum.map(fn p -> {p.participant_key, p.intents_by_chunk} end)
      |> Map.new()

    scene_opts_by_participant =
      plan.participants
      |> Enum.map(fn p ->
        {p.participant_key, [chunk_directory: prefab_chunk_directory_ref(p)]}
      end)
      |> Map.new()

    try do
      WorldServer.Voxel.TransactionExecutor.execute(
        coordinator_ref,
        transaction,
        intents_by_participant,
        scene_opts_by_participant: scene_opts_by_participant
      )
    catch
      :exit, _reason -> {:error, :executor_crashed}
    end
  end

  # Phase A4-5:per-participant chunk_directory module 解析。生产 default
  # `SceneServer.Voxel.ChunkDirectory`(单 module 跨所有 region);test 注入
  # `:voxel_chunk_directory_resolver` env fn 让不同 participant 路由到不同
  # named instance(`ChunkDirectory.RegionA` / `ChunkDirectory.RegionB`),
  # 在单 BEAM 内模拟多 scene_node 部署。A4-bis-cluster 落地后 default 改为
  # 走 `RegionRouting.resolve_chunk_directory/1`。
  defp voxel_chunk_directory_module_for(participant_key) do
    case Application.get_env(:gate_server, :voxel_chunk_directory_resolver) do
      nil -> SceneServer.Voxel.ChunkDirectory
      fun when is_function(fun, 1) -> fun.(participant_key)
    end
  end

  defp finalize_prefab_outcome(executor_result, plan, total) do
    case executor_result do
      %{decision: :commit, participant_results: results} ->
        max_version = max_chunk_version_from_results(results)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      %{decision: :abort, prepare_results: prepare_results} ->
        reason = first_prepare_failure_reason(prepare_results) || :prefab_transaction_aborted

        {:error,
         %{
           reason: reason,
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp max_chunk_version_from_results(results) do
    Enum.reduce(results, 0, fn
      {_participant, {:ok, summary}}, acc ->
        committed = Map.get(summary, :committed_chunks, [])

        Enum.reduce(committed, acc, fn {_chunk, chunk_summary}, inner ->
          max(inner, Map.get(chunk_summary, :chunk_version, 0))
        end)

      _, acc ->
        acc
    end)
  end

  defp first_prepare_failure_reason(prepare_results) do
    prepare_results
    |> Enum.find_value(fn
      {_participant, {:error, reason}} -> reason
      _ -> nil
    end)
    |> unwrap_prepare_reason()
  end

  # Phase A1-2:`BuildTransactionApplier.prepare_chunks` 把 chunk 级 prepare
  # 失败 wrap 成 `{:prepare_failed, chunk_coord, inner_reason}`。Gate wire
  # 透传给 client 时,wrapped tuple 在 :reason 字段会变成
  # `"{:prepare_failed, {0, 0, 0}, :micro_slot_already_occupied}"` 这种串,
  # client UI 难以识别业务级 reject。这里 unwrap 成 inner atom 让 wire reason
  # 跟 single-intent path(0x70 voxel_edit_intent → :stale_chunk_version 之类)
  # 风格一致。其他 wrap 形式(:commit_failed 等)保持原样。
  defp unwrap_prepare_reason({:prepare_failed, _chunk_coord, inner_reason}), do: inner_reason
  defp unwrap_prepare_reason(other), do: other

  defp unique_prefab_transaction_id(request) do
    unique = System.unique_integer([:positive, :monotonic])
    "prefab-#{request.request_id}-#{unique}"
  end

  defp prefab_reservation_id(request) do
    "prefab-reservation-#{request.request_id}"
  end

  defp emit_voxel_subscription_window_planned(plan, state) do
    GateServer.CliObserve.emit("voxel_subscription_window_planned", fn ->
      Map.merge(plan.summary, %{
        connection_pid: self(),
        cid: state.cid,
        subscribe_entries:
          Enum.map(plan.subscribe_entries, fn entry ->
            Map.take(entry, [:chunk_coord, :tier, :priority, :region_id, :lease_id])
          end),
        skipped_entries:
          Enum.map(plan.skipped_entries, fn entry ->
            Map.take(entry, [:chunk_coord, :tier, :status, :reason, :region_id, :lease_id])
          end)
      })
    end)
  end

  defp voxel_result_error(request, reason) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :rejected,
       result_ref: 0,
       authoritative: [],
       reason: inspect(reason)
     }}
  end

  defp voxel_result_ok(request, result) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: result.chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  defp voxel_field_conduct_result_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: Map.get(summary, :region_id) || 0,
       authoritative: [],
       reason: "field_conduct_ok"
     }}
  end

  defp voxel_prefab_result_ok(request, summary) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: request.client_intent_seq,
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: summary.max_chunk_version,
       authoritative: [],
       reason: "ok"
     }}
  end

  # Stub accept used by build-reservation / prefab-place intents until the
  # real reservation and rasterisation pipeline lands. The wire shape matches
  # the eventual spec so clients can round-trip the result frame today.
  defp voxel_intent_stub_accepted(request) do
    {:voxel_intent_result,
     %{
       request_id: request.request_id,
       client_intent_seq: Map.get(request, :client_intent_seq, 0),
       logical_scene_id: request.logical_scene_id,
       result_code: :accepted,
       result_ref: 0,
       authoritative: [],
       reason: ""
     }}
  end

  defp subscribe_voxel_chunks(request, state) do
    with :ok <- validate_voxel_subscribe_radius(request.radius_l_inf),
         :ok <-
           authorize_voxel_subscribe_window(
             state,
             request.logical_scene_id,
             request.center_chunk,
             request.radius_l_inf
           ),
         {:ok, window} <-
           route_voxel_partition_window(
             request.logical_scene_id,
             request.center_chunk,
             request.radius_l_inf
           ),
         {:ok, plan_state, plan} <- build_voxel_subscription_plan(request, state, window) do
      emit_voxel_subscription_window_planned(plan, plan_state)

      with :ok <- validate_subscription_plan_has_center(plan, request.center_chunk) do
        case SubscriptionRuntime.apply_plan(plan_state, plan,
               subscriber: self(),
               send_snapshot?: request.want_snapshot,
               diff_mode: :additive,
               reason: :client_chunk_subscribe
             ) do
          {:ok, next_state, summary} ->
            {:ok, next_state,
             %{
               chunk_count: plan.summary.requested_chunk_count,
               subscribed_chunk_count: summary.subscribe_count
             }}

          {:error, _next_state, summary} ->
            {:error, Map.get(summary, :reason, :voxel_subscription_failed)}
        end
      end
    end
  end

  defp authorize_voxel_subscribe_window(state, logical_scene_id, center_chunk, radius_l_inf) do
    case authoritative_voxel_context(state) do
      %{logical_scene_id: ^logical_scene_id, chunk_coord: authority_chunk} ->
        if chunk_linf_distance(authority_chunk, center_chunk) + radius_l_inf <=
             @max_voxel_subscribe_radius do
          :ok
        else
          {:error, :unauthorized_voxel_target}
        end

      %{logical_scene_id: _other_scene_id} ->
        {:error, :unauthorized_voxel_target}

      nil ->
        authorize_legacy_voxel_target_without_partition_context()
    end
  end

  defp authorize_voxel_target(state, logical_scene_id, chunk_coord) do
    authorize_voxel_chunks(state, logical_scene_id, [chunk_coord])
  end

  defp authorize_voxel_chunks(state, logical_scene_id, chunk_coords) do
    case authoritative_voxel_context(state) do
      %{logical_scene_id: ^logical_scene_id, chunk_coord: authority_chunk} ->
        if Enum.all?(
             chunk_coords,
             &authorized_voxel_chunk?(state, logical_scene_id, authority_chunk, &1)
           ) do
          :ok
        else
          {:error, :unauthorized_voxel_target}
        end

      %{logical_scene_id: _other_scene_id} ->
        {:error, :unauthorized_voxel_target}

      nil ->
        authorize_legacy_voxel_target_without_partition_context()
    end
  end

  defp authoritative_voxel_context(%{
         partition_context: %{
           logical_scene_id: logical_scene_id,
           chunk_coord: {_, _, _} = chunk_coord
         }
       })
       when is_integer(logical_scene_id) do
    %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}
  end

  defp authoritative_voxel_context(%{
         chat_context: %{logical_scene_id: logical_scene_id, chunk_coord: {_, _, _} = chunk_coord}
       })
       when is_integer(logical_scene_id) do
    %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}
  end

  defp authoritative_voxel_context(_state), do: nil

  defp authorized_voxel_chunk?(state, logical_scene_id, authority_chunk, chunk_coord) do
    subscribed_voxel_chunk?(state, logical_scene_id, chunk_coord) or
      chunk_linf_distance(authority_chunk, chunk_coord) <= @max_voxel_subscribe_radius
  end

  defp subscribed_voxel_chunk?(state, logical_scene_id, chunk_coord) do
    state
    |> Map.get(:voxel_subscriptions, %{})
    |> Map.has_key?({logical_scene_id, chunk_coord})
  end

  defp chunk_linf_distance({ax, ay, az}, {bx, by, bz}) do
    Enum.max([abs(ax - bx), abs(ay - by), abs(az - bz)])
  end

  defp authorize_legacy_voxel_target_without_partition_context do
    if Application.get_env(
         :gate_server,
         :allow_legacy_voxel_target_without_partition_context,
         false
       ) do
      :ok
    else
      {:error, :unauthorized_voxel_target}
    end
  end

  defp build_voxel_subscription_plan(request, state, window) do
    {state, _summary} = record_client_known_versions(state, request)
    known_versions = client_ack_known_versions_for_subscription(state, request.logical_scene_id)

    {:ok, state,
     SubscriptionPlanner.plan(%{
       cid: state.cid,
       request_id: request.request_id,
       partition_window: window,
       known_versions: known_versions
     })}
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_subscription_window}
  end

  defp validate_subscription_plan_has_center(plan, center_chunk) do
    if Enum.any?(plan.subscribe_entries, &(&1.chunk_coord == center_chunk)) do
      :ok
    else
      plan.skipped_entries
      |> Enum.find(&(&1.chunk_coord == center_chunk))
      |> case do
        %{reason: :missing_lease} -> {:error, :region_without_lease}
        %{reason: :missing_route} -> {:error, :unassigned_chunk}
        _other -> {:error, :unassigned_chunk}
      end
    end
  end

  defp record_client_known_versions(state, request) do
    known = Map.get(request, :known, [])

    if known == [] do
      {state, empty_client_ack_summary(request.logical_scene_id)}
    else
      {next_state, summary} =
        record_client_ack_versions(state, Map.put(request, :acks, voxel_known_versions(known)))

      GateServer.CliObserve.emit("ws_voxel_client_known_versions_recorded", fn ->
        Map.merge(summary, %{
          connection_pid: self(),
          cid: state.cid,
          transport: :websocket,
          request_id: request.request_id
        })
      end)

      {next_state, summary}
    end
  end

  defp record_client_ack_versions(state, request) do
    ledger = Map.get(state, :client_ack_versions, ClientAckLedger.new())
    forwarded = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    {next_ledger, summary} =
      ClientAckLedger.record_known_versions(
        ledger,
        forwarded,
        request.logical_scene_id,
        Map.get(request, :acks, [])
      )

    {Map.put(state, :client_ack_versions, next_ledger), summary}
  end

  defp client_ack_known_versions_for_subscription(state, logical_scene_id) do
    state
    |> Map.get(:client_ack_versions, ClientAckLedger.new())
    |> ClientAckLedger.known_versions(logical_scene_id)
    |> Map.drop(
      DeliveryScheduler.resync_required_chunks(Map.get(state, :voxel_delivery), logical_scene_id)
    )
  end

  defp empty_client_ack_summary(logical_scene_id) do
    %{
      status: :empty,
      logical_scene_id: logical_scene_id,
      accepted_count: 0,
      ignored_count: 0,
      rejected_count: 0,
      ack_count: 0,
      events: []
    }
  end

  defp rebind_voxel_subscriptions_in_state(state, logical_scene_id, region_selector, reason) do
    GateServer.CliObserve.emit("voxel_subscription_rebind_aggregate_requested", %{
      connection_pid: self(),
      cid: state.cid,
      logical_scene_id: logical_scene_id,
      region_selector: region_selector,
      reason: reason,
      subscription_count: map_size(state.voxel_subscriptions),
      pending_rebind_count: map_size(Map.get(state, :voxel_subscription_rebind_pending, %{}))
    })

    SubscriptionRebind.rebind_selected_subscriptions(
      state,
      logical_scene_id,
      region_selector,
      reason,
      route_fun: &route_voxel_chunk/2,
      subscriber: self(),
      connection_pid: self()
    )
  end

  defp unsubscribe_voxel_chunks(request, state) do
    Enum.reduce(request.chunks, {0, state}, fn chunk_coord, {count, acc_state} ->
      case unsubscribe_voxel_chunk(request.logical_scene_id, chunk_coord, acc_state) do
        {:ok, next_state} -> {count + 1, next_state}
        {:purged, next_state} -> {count, next_state}
      end
    end)
  end

  defp unsubscribe_voxel_chunk(logical_scene_id, chunk_coord, state) do
    key = voxel_subscription_key(logical_scene_id, chunk_coord)

    case Map.pop(state.voxel_subscriptions, key) do
      {nil, _subscriptions} ->
        {:purged,
         state
         |> clear_queued_voxel_delivery(logical_scene_id, chunk_coord)
         |> clear_forwarded_chunk_version(logical_scene_id, chunk_coord)}

      {subscription, subscriptions} ->
        scene_unsubscribe(subscription)

        {:ok,
         state
         |> Map.put(:voxel_subscriptions, subscriptions)
         |> clear_queued_voxel_delivery(logical_scene_id, chunk_coord)
         |> clear_forwarded_chunk_version(logical_scene_id, chunk_coord)}
    end
  end

  defp cleanup_voxel_subscriptions(%{voxel_subscriptions: subscriptions}) do
    Enum.each(subscriptions, fn {_key, subscription} -> scene_unsubscribe(subscription) end)
    :ok
  end

  defp scene_unsubscribe(%{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         scene_node: scene_node
       }) do
    _ =
      safe_call(
        {SceneServer.Voxel.ChunkDirectory, scene_node},
        {:unsubscribe,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord, subscriber: self()}},
        @scene_call_timeout
      )

    :ok
  end

  defp validate_voxel_subscribe_radius(radius)
       when is_integer(radius) and radius >= 0 and radius <= @max_voxel_subscribe_radius,
       do: :ok

  defp validate_voxel_subscribe_radius(_radius), do: {:error, :voxel_subscribe_radius_too_large}

  defp voxel_known_versions(known) do
    Map.new(known, fn %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
      {chunk_coord, chunk_version}
    end)
  end

  defp voxel_subscription_key(logical_scene_id, chunk_coord), do: {logical_scene_id, chunk_coord}

  defp observe_message_summary({:auth_request, username, _token, request_id}) do
    %{type: :auth_request, username: username, request_id: request_id, token_redacted?: true}
  end

  defp observe_message_summary({:movement_input, frame}) do
    %{type: :movement_input, seq: frame.seq, client_tick: frame.client_tick}
  end

  defp observe_message_summary({:voxel_debug_probe, %{request_id: request_id, command: command}}) do
    %{type: :voxel_debug_probe, request_id: request_id, command: command}
  end

  defp observe_message_summary({:voxel_impact_intent, request}) do
    %{
      type: :voxel_impact_intent,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      impact_kind: request.impact_kind
    }
  end

  defp observe_message_summary(message), do: message

  defp handle_voxel_debug_command("voxel_rebind" <> _rest = command, state) do
    case parse_voxel_rebind_command(command) do
      {:ok, logical_scene_id, region_selector} ->
        {_status, next_state, result} =
          rebind_voxel_subscriptions_in_state(
            state,
            logical_scene_id,
            region_selector,
            :debug_probe
          )

        text =
          [
            "voxel_rebind=ok",
            "logical_scene_id=#{logical_scene_id}",
            "region_selector=#{region_selector}",
            "rebound_count=#{result.rebound_count}",
            "skipped_count=#{result.skipped_count}",
            "error_count=#{result.error_count}",
            "invalidated_subscription_count=#{Map.get(result, :invalidated_subscription_count, 0)}",
            "pending_rebind_count=#{Map.get(result, :pending_rebind_count, 0)}",
            voxel_debug_result("voxel_transport", next_state)
          ]
          |> Enum.join("\n")

        {text, next_state}

      {:error, reason} ->
        {"voxel_rebind=error\nreason=#{reason}", state}
    end
  end

  defp handle_voxel_debug_command(command, state), do: {voxel_debug_result(command, state), state}

  defp parse_voxel_rebind_command(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      ["voxel_rebind", logical_scene_id] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id) do
          {:ok, logical_scene_id, :all}
        end

      ["voxel_rebind", logical_scene_id, "all"] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id) do
          {:ok, logical_scene_id, :all}
        end

      ["voxel_rebind", logical_scene_id, region_id] ->
        with {:ok, logical_scene_id} <- parse_non_negative_integer(logical_scene_id),
             {:ok, region_id} <- parse_non_negative_integer(region_id) do
          {:ok, logical_scene_id, region_id}
        end

      _other ->
        {:error, :usage_voxel_rebind_logical_scene_id_region_id_or_all}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> {:error, :invalid_integer}
    end
  end

  defp voxel_debug_result("voxel_transport", state) do
    plan = state.voxel_subscription_plan || %{}
    partition_context = Map.get(state, :partition_context) || %{}
    chat_context = Map.get(state, :chat_context) || %{}
    last_partition_refresh = Map.get(state, :last_partition_refresh) || %{}

    [
      "voxel_sync=server-authoritative",
      "voxel_truth_source=server",
      "connection_status=#{state.status}",
      "cid=#{state.cid}",
      "scene_attached=#{not is_nil(state.scene_ref)}",
      "partition_context_region_id=#{Map.get(partition_context, :region_id, :none)}",
      "partition_context_chunk_coord=#{inspect(Map.get(partition_context, :chunk_coord))}",
      "chat_context_region_id=#{Map.get(chat_context, :region_id, :none)}",
      "chat_context_chunk_coord=#{inspect(Map.get(chat_context, :chunk_coord))}",
      "last_partition_refresh_status=#{Map.get(last_partition_refresh, :status, :none)}",
      "last_partition_refresh_boundary=#{Map.get(last_partition_refresh, :boundary_kind, :none)}",
      "last_partition_refresh_reason=#{inspect(Map.get(last_partition_refresh, :reason))}",
      "last_partition_refresh_auth_tick=#{Map.get(last_partition_refresh, :auth_tick, :none)}",
      "partition_refresh_generation=#{Map.get(state, :partition_refresh_generation, 0)}",
      "partition_refresh_pending_status=#{Map.get(Map.get(state, :partition_refresh_pending) || %{}, :status, :none)}",
      "partition_refresh_pending_generation=#{Map.get(Map.get(state, :partition_refresh_pending) || %{}, :generation, :none)}",
      "partition_refresh_pending_auth_tick=#{Map.get(Map.get(state, :partition_refresh_pending) || %{}, :auth_tick, :none)}",
      "voxel_subscription_count=#{map_size(state.voxel_subscriptions)}",
      "voxel_subscriptions=#{inspect(state.voxel_subscriptions |> Map.keys() |> Enum.take(16))}",
      "voxel_subscription_routes=#{inspect(voxel_subscription_debug(state.voxel_subscriptions))}",
      "voxel_subscription_plan_pressure=#{Map.get(plan, :pressure, :none)}",
      "voxel_subscription_plan_center_chunk=#{inspect(Map.get(plan, :center_chunk))}",
      "voxel_subscription_plan_near_radius=#{Map.get(plan, :near_radius, :none)}",
      "voxel_subscription_plan_halo_radius=#{Map.get(plan, :halo_radius, :none)}",
      "voxel_subscription_plan_near_vertical_radius=#{Map.get(plan, :near_vertical_radius, :none)}",
      "voxel_subscription_plan_halo_vertical_radius=#{Map.get(plan, :halo_vertical_radius, :none)}",
      "voxel_subscription_plan_subscribe_count=#{Map.get(plan, :subscribe_count, 0)}",
      "voxel_subscription_plan_skipped_count=#{Map.get(plan, :skipped_count, 0)}",
      "voxel_subscription_plan_missing_count=#{Map.get(plan, :missing_chunk_count, 0)}",
      "voxel_subscription_plan_unleased_count=#{Map.get(plan, :unleased_chunk_count, 0)}",
      "forwarded_chunk_versions=#{ChunkVersionLedger.format_debug(Map.get(state, :forwarded_chunk_versions))}",
      "client_ack_versions=#{ClientAckLedger.format_debug(Map.get(state, :client_ack_versions))}",
      voxel_delivery_debug(Map.get(state, :voxel_delivery)),
      "inflight_intent_count=0",
      "voxel_codec_endian=big",
      "micro_resolution=8"
    ]
    |> Enum.join("\n")
  end

  defp voxel_debug_result(command, state) do
    [
      "command=#{command}",
      "connection_status=#{state.status}",
      "voxel_debug=unknown_command"
    ]
    |> Enum.join("\n")
  end

  defp refresh_partition_after_movement_ack(state, ack, retry_attempt \\ 0) do
    case PartitionRuntime.refresh_after_movement_ack(state, ack) do
      {:ok, next_state, _outcome} ->
        next_state

      {:error, next_state, outcome} ->
        maybe_schedule_partition_bootstrap_retry(next_state, ack, outcome, retry_attempt)
    end
  end

  defp maybe_schedule_partition_bootstrap_retry(state, ack, outcome, retry_attempt) do
    if partition_bootstrap_retryable?(outcome) and
         retry_attempt < @partition_bootstrap_retry_max_attempts do
      next_attempt = retry_attempt + 1

      Process.send_after(
        self(),
        {:partition_bootstrap_retry, ack, next_attempt},
        @partition_bootstrap_retry_delay_ms
      )

      GateServer.CliObserve.emit("gate_partition_bootstrap_retry_scheduled", %{
        cid: Map.get(ack, :cid),
        ack_seq: Map.get(ack, :ack_seq),
        auth_tick: Map.get(ack, :auth_tick),
        attempt: next_attempt,
        delay_ms: @partition_bootstrap_retry_delay_ms,
        reason: Map.get(outcome, :reason)
      })
    end

    state
  end

  defp partition_bootstrap_retryable?(%{reason: reason})
       when reason in [:unroutable_center, :world_unavailable, :no_route_for_chunk],
       do: true

  defp partition_bootstrap_retryable?(_outcome), do: false

  defp partition_refresh_resolved?(%{last_partition_refresh: %{status: :updated}}), do: true

  defp partition_refresh_resolved?(%{partition_context: %{region_id: region_id}}),
    do: not is_nil(region_id)

  defp partition_refresh_resolved?(_state), do: false

  defp schedule_partition_refresh_after_movement_ack(state, ack) do
    {:ok, next_state, event} = PartitionRefresh.schedule(state, ack, owner: self())
    GateServer.CliObserve.emit("gate_partition_refresh_scheduled", event)
    next_state
  end

  defp voxel_subscription_debug(subscriptions) do
    subscriptions
    |> Map.values()
    |> Enum.take(16)
    |> Enum.map(fn subscription ->
      Map.take(subscription, [
        :logical_scene_id,
        :chunk_coord,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch,
        :scene_node
      ])
    end)
  end

  defp build_input_frame(%{} = frame) do
    if Map.get(frame, :__struct__) == InputFrame do
      frame
    else
      struct(InputFrame, %{
        seq: Map.fetch!(frame, :seq),
        client_tick: Map.fetch!(frame, :client_tick),
        dt_ms: Map.fetch!(frame, :dt_ms),
        input_dir: Map.fetch!(frame, :input_dir),
        speed_scale: Map.fetch!(frame, :speed_scale),
        movement_flags: Map.fetch!(frame, :movement_flags)
      })
    end
  end

  defp normalize_remote_snapshot(%{} = snapshot) do
    if Map.get(snapshot, :__struct__) == RemoteSnapshot do
      snapshot
    else
      raise ArgumentError, "expected remote snapshot map, got: #{inspect(snapshot)}"
    end
  end

  defp normalize_close_reason({:error, :closed}), do: :normal
  defp normalize_close_reason(reason), do: reason

  defp player_move_message(
         %RemoteSnapshot{
           priority_band: nil,
           priority_score: nil,
           observer_distance: nil,
           delivery_interval: nil
         } = snapshot,
         server_send_ms
       ) do
    {:player_move, snapshot.cid, snapshot.server_tick, movement_state_ms(snapshot),
     server_send_ms, snapshot.position, snapshot.velocity, snapshot.acceleration,
     snapshot.movement_mode}
  end

  defp player_move_message(%RemoteSnapshot{} = snapshot, server_send_ms) do
    {:player_move, snapshot.cid, snapshot.server_tick, movement_state_ms(snapshot),
     server_send_ms, snapshot.position, snapshot.velocity, snapshot.acceleration,
     snapshot.movement_mode, snapshot.priority_band, snapshot.priority_score,
     snapshot.observer_distance, snapshot.delivery_interval}
  end

  defp movement_state_ms(%{} = movement_payload) do
    case Map.get(movement_payload, :server_state_ms, 0) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp start_ws_outbound_writer(owner_pid, connection_pid) do
    spawn_link(fn -> ws_outbound_writer_loop(owner_pid, connection_pid) end)
  end

  defp ws_outbound_writer_loop(owner_pid, connection_pid) do
    receive do
      {:gate_ws_send, payload} ->
        send(owner_pid, {:gate_ws_send, payload})
        ws_outbound_writer_loop(owner_pid, connection_pid)

      {:shutdown, from_pid} when from_pid == connection_pid ->
        :ok

      _other ->
        ws_outbound_writer_loop(owner_pid, connection_pid)
    end
  end

  defp cleanup_ws_outbound_writer(pid) when is_pid(pid), do: send(pid, {:shutdown, self()})
  defp cleanup_ws_outbound_writer(_pid), do: :ok

  defp start_movement_ack_sender(outbound_pid, connection_pid) do
    spawn_link(fn -> movement_ack_sender_loop(outbound_pid, connection_pid) end)
  end

  defp movement_ack_sender_loop(outbound_pid, connection_pid) do
    receive do
      {:"$gen_cast", {:movement_ack, ack}} ->
        send_movement_ack_payload(
          outbound_pid,
          connection_pid,
          ack,
          "ws_movement_ack_fast_push",
          true
        )

        send(connection_pid, {:movement_ack_fast_path_sent, ack})
        movement_ack_sender_loop(outbound_pid, connection_pid)

      {:shutdown, from_pid} when from_pid == connection_pid ->
        :ok

      _other ->
        movement_ack_sender_loop(outbound_pid, connection_pid)
    end
  end

  defp cleanup_movement_ack_sender(pid) when is_pid(pid), do: send(pid, {:shutdown, self()})
  defp cleanup_movement_ack_sender(_pid), do: :ok

  defp send_movement_ack_payload(outbound_pid, connection_pid, ack, event_name, fast_path) do
    server_send_ms = :os.system_time(:millisecond)
    server_state_ms = movement_state_ms(ack)
    diagnostics = movement_ack_diagnostics(ack, server_send_ms)

    GateServer.CliObserve.emit(event_name, fn ->
      Map.merge(diagnostics, %{
        connection_pid: connection_pid,
        sender_pid: self(),
        fast_path: fast_path,
        ack_seq: ack.ack_seq,
        auth_tick: ack.auth_tick,
        server_state_ms: server_state_ms,
        server_send_ms: server_send_ms
      })
    end)

    {:ok, iodata} =
      GateServer.Codec.encode(
        {:movement_ack, ack.ack_seq, ack.auth_tick, server_state_ms, server_send_ms, ack.cid,
         ack.position, ack.velocity, ack.acceleration, ack.movement_mode, ack.correction_flags,
         ack.fixed_dt_ms, ack.ground_z, diagnostics}
      )

    send(outbound_pid, {:gate_ws_send, IO.iodata_to_binary(iodata)})
    :ok
  end

  defp movement_ack_diagnostics(%{} = ack, server_send_ms) do
    scene_ack_ms = diagnostic_integer(ack, :scene_ack_ms)

    %{
      scene_ack_ms: scene_ack_ms,
      scene_input_age_ms: diagnostic_integer(ack, :scene_input_age_ms),
      scene_queue_len: diagnostic_integer(ack, :scene_queue_len),
      scene_replay_count: diagnostic_integer(ack, :scene_replay_count),
      scene_dropped_input_count: diagnostic_integer(ack, :scene_dropped_input_count),
      scene_mailbox_len: diagnostic_integer(ack, :scene_mailbox_len),
      scene_tick_drift_ms: diagnostic_integer(ack, :scene_tick_drift_ms),
      gate_send_delay_ms: gate_send_delay_ms(server_send_ms, scene_ack_ms)
    }
  end

  defp gate_send_delay_ms(server_send_ms, scene_ack_ms)
       when is_integer(server_send_ms) and is_integer(scene_ack_ms) and scene_ack_ms > 0 do
    max(server_send_ms - scene_ack_ms, 0)
  end

  defp gate_send_delay_ms(_server_send_ms, _scene_ack_ms), do: 0

  defp diagnostic_integer(map, key) do
    case Map.get(map, key, 0) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      _ -> 0
    end
  end

  defp voxel_delivery_debug(scheduler) do
    summary = DeliveryScheduler.summary(scheduler)

    [
      "voxel_delivery_window_bytes_used=#{summary.window_bytes_used}",
      "voxel_delivery_window_items_used=#{summary.window_items_used}",
      "voxel_delivery_max_window_bytes=#{summary.max_window_bytes}",
      "voxel_delivery_max_window_items=#{summary.max_window_items}",
      "voxel_delivery_queue_count=#{summary.queued_count}",
      "voxel_delivery_queued_bytes=#{summary.queued_bytes}",
      "voxel_delivery_deferred_count=#{summary.deferred_count}",
      "voxel_delivery_sent_count=#{summary.sent_count}",
      "voxel_delivery_control_sent_count=#{summary.control_sent_count}",
      "voxel_delivery_event_sent_count=#{summary.event_sent_count}",
      "voxel_delivery_dropped_count=#{summary.dropped_count}",
      "voxel_delivery_pruned_count=#{summary.pruned_count}",
      "voxel_delivery_resync_required_count=#{summary.resync_required_count}"
    ]
    |> Enum.join("\n")
  end

  defp handle_live_voxel_data(state, frame_kind, payload) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
    {scheduler, action} = DeliveryScheduler.offer(scheduler, frame_kind, payload)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> emit_voxel_delivery_scheduled(action)

    case action.action do
      :send_now ->
        state
        |> send_live_voxel_action(action)
        |> maybe_schedule_voxel_delivery_window()

      _queued_or_dropped ->
        maybe_schedule_voxel_delivery_window(state)
    end
  end

  defp handle_live_voxel_envelope(state, envelope) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))

    {scheduler, action} =
      offer_live_voxel_envelope_with_connection_guard(state, scheduler, envelope)

    state =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> emit_voxel_delivery_scheduled(action)

    case action.action do
      :send_now ->
        state
        |> send_live_voxel_action(action)
        |> maybe_schedule_voxel_delivery_window()

      _queued_or_dropped ->
        maybe_schedule_voxel_delivery_window(state)
    end
  end

  defp offer_live_voxel_envelope_with_connection_guard(state, scheduler, envelope) do
    case DeliveryEnvelope.normalize(envelope) do
      {:ok, frame} ->
        case validate_live_voxel_envelope_for_connection(state, frame) do
          :ok ->
            DeliveryScheduler.offer_frame(scheduler, frame)

          {:error, reason, attrs} ->
            DeliveryScheduler.reject_envelope(
              scheduler,
              frame
              |> Map.put(:reason, reason)
              |> Map.merge(attrs)
            )
        end

      {:error, frame} ->
        DeliveryScheduler.reject_envelope(scheduler, frame)
    end
  end

  defp validate_live_voxel_envelope_for_connection(
         state,
         %{frame_kind: :object_state_delta} = frame
       ) do
    active_subscriptions =
      frame.affected_chunks
      |> Enum.map(fn chunk_coord ->
        subscription_for_envelope_chunk(state, frame.logical_scene_id, chunk_coord)
      end)
      |> Enum.reject(&is_nil/1)

    case active_subscriptions do
      [] ->
        {:error, :subscription_not_found, %{affected_chunks: frame.affected_chunks}}

      subscriptions ->
        validate_envelope_subscription_set(frame, subscriptions)
    end
  end

  defp validate_live_voxel_envelope_for_connection(state, frame) do
    subscription =
      subscription_for_envelope_chunk(state, frame.logical_scene_id, frame.chunk_coord)

    if is_nil(subscription) do
      {:error, :subscription_not_found, %{}}
    else
      validate_envelope_subscription(frame, subscription)
    end
  end

  defp validate_envelope_subscription_set(frame, subscriptions) do
    Enum.reduce_while(subscriptions, :ok, fn subscription, :ok ->
      case validate_envelope_subscription(frame, subscription) do
        :ok -> {:cont, :ok}
        {:error, reason, attrs} -> {:halt, {:error, reason, attrs}}
      end
    end)
  end

  defp validate_envelope_subscription(frame, subscription) do
    cond do
      Map.get(subscription, :lease_id) != frame.lease_id ->
        {:error, :lease_id_mismatch,
         %{expected_lease_id: Map.get(subscription, :lease_id), envelope_lease_id: frame.lease_id}}

      Map.get(subscription, :owner_epoch) != frame.owner_epoch ->
        {:error, :owner_epoch_mismatch,
         %{
           expected_owner_epoch: Map.get(subscription, :owner_epoch),
           envelope_owner_epoch: frame.owner_epoch
         }}

      Map.has_key?(frame, :region_id) and not envelope_region_matches?(subscription, frame) ->
        {:error, :region_id_mismatch,
         %{
           expected_region_id: Map.get(subscription, :region_id),
           envelope_region_id: frame.region_id
         }}

      envelope_requires_tier_match?(frame) and not envelope_tier_matches?(subscription, frame) ->
        {:error, :tier_mismatch,
         %{expected_tier: Map.get(subscription, :tier), envelope_tier: frame.tier}}

      true ->
        :ok
    end
  end

  defp subscription_for_envelope_chunk(state, logical_scene_id, chunk_coord) do
    state
    |> Map.get(:voxel_subscriptions, %{})
    |> Map.get({logical_scene_id, chunk_coord})
  end

  defp envelope_region_matches?(subscription, frame) do
    region_id = Map.get(subscription, :region_id)
    is_nil(region_id) or region_id == frame.region_id
  end

  defp envelope_requires_tier_match?(%{frame_kind: frame_kind})
       when frame_kind in [:invalidate, :field_region_destroyed],
       do: false

  defp envelope_requires_tier_match?(_frame), do: true

  defp envelope_tier_matches?(subscription, frame) do
    tier = Map.get(subscription, :tier)
    is_nil(tier) or tier == frame.tier
  end

  defp handle_live_voxel_invalidate(state, payload) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
    {scheduler, action} = DeliveryScheduler.offer(scheduler, :invalidate, payload)

    {state, invalidate_event} =
      state
      |> Map.put(:voxel_delivery, scheduler)
      |> emit_voxel_delivery_scheduled(action)
      |> clear_forwarded_chunk_version(payload)

    {state, ack_event} = clear_client_ack_version(state, payload)
    state = clear_delivered_invalidate_resync(state, action)

    GateServer.CliObserve.emit(
      "ws_voxel_chunk_invalidate_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions),
          pruned_delivery_count: Map.get(action, :pruned_count, 0)
        },
        chunk_version_observe(invalidate_event)
      )
    )

    GateServer.CliObserve.emit(
      "ws_voxel_client_ack_invalidate_cleared",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          transport: :websocket
        },
        client_ack_observe(ack_event)
      )
    )

    send_encoded(state, {:voxel_chunk_invalidate_payload, payload})

    state
    |> maybe_rebind_cutover_invalidate(invalidate_event)
    |> maybe_schedule_voxel_delivery_window()
  end

  defp clear_delivered_invalidate_resync(
         state,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}
       ) do
    scheduler =
      state
      |> Map.get(:voxel_delivery)
      |> DeliveryScheduler.ensure()
      |> DeliveryScheduler.clear_resync_required(logical_scene_id, chunk_coord)

    Map.put(state, :voxel_delivery, scheduler)
  end

  defp clear_delivered_invalidate_resync(state, _action), do: state

  defp maybe_rebind_cutover_invalidate(state, invalidate_event) do
    case SubscriptionRebind.apply_cutover_invalidation(state, invalidate_event,
           route_fun: &route_voxel_chunk/2,
           subscriber: self(),
           connection_pid: self()
         ) do
      {:ok, next_state, _summary} -> next_state
      {:error, next_state, _summary} -> next_state
    end
  end

  defp send_live_voxel_actions(state, actions) do
    Enum.reduce(actions, state, fn action, acc_state ->
      acc_state
      |> emit_voxel_delivery_scheduled(action)
      |> send_live_voxel_action(action)
    end)
  end

  defp send_live_voxel_action(state, %{frame_kind: :invalidate, payload: payload} = action) do
    send_encoded(state, {:voxel_chunk_invalidate_payload, payload})
    {state, invalidate_event} = clear_forwarded_chunk_version_from_action(state, action)
    {state, ack_event} = clear_client_ack_version_from_action(state, action)
    state = clear_delivered_invalidate_resync(state, action)

    GateServer.CliObserve.emit(
      "ws_voxel_chunk_invalidate_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions),
          pruned_delivery_count: Map.get(action, :pruned_count, 0)
        },
        chunk_version_observe(invalidate_event)
      )
    )

    GateServer.CliObserve.emit(
      "ws_voxel_client_ack_invalidate_cleared",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          transport: :websocket
        },
        client_ack_observe(ack_event)
      )
    )

    maybe_rebind_cutover_invalidate(state, invalidate_event)
  end

  defp send_live_voxel_action(state, %{frame_kind: :snapshot, payload: payload}) do
    send_encoded(state, {:voxel_chunk_snapshot_payload, payload})
    {state, version_event} = record_forwarded_chunk_version(state, :snapshot, payload)

    GateServer.CliObserve.emit(
      "ws_voxel_chunk_snapshot_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions)
        },
        chunk_version_observe(version_event)
      )
    )

    state
  end

  defp send_live_voxel_action(state, %{frame_kind: :delta, payload: payload}) do
    send_encoded(state, {:voxel_chunk_delta_payload, payload})
    {state, version_event} = record_forwarded_chunk_version(state, :delta, payload)

    GateServer.CliObserve.emit(
      "ws_voxel_chunk_delta_forwarded",
      Map.merge(
        %{
          connection_pid: self(),
          cid: state.cid,
          bytes: byte_size(payload),
          subscription_count: map_size(state.voxel_subscriptions)
        },
        chunk_version_observe(version_event)
      )
    )

    state
  end

  defp send_live_voxel_action(state, %{frame_kind: :object_state_delta, payload: payload}) do
    send_encoded(state, {:voxel_object_state_delta_payload, payload})

    GateServer.CliObserve.emit("ws_voxel_object_state_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    state
  end

  defp send_live_voxel_action(state, %{frame_kind: :field_region_snapshot, payload: payload}) do
    send_ws_payload(state, payload)

    GateServer.CliObserve.emit("ws_voxel_field_region_snapshot_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    state
  end

  defp send_live_voxel_action(
         state,
         %{frame_kind: :field_region_destroyed, payload: payload} = action
       ) do
    send_ws_payload(state, payload)

    GateServer.CliObserve.emit("ws_voxel_field_region_destroyed_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions),
      pruned_delivery_count: Map.get(action, :pruned_count, 0)
    })

    state
  end

  defp send_live_voxel_action(state, _action), do: state

  defp maybe_schedule_voxel_delivery_window(state) do
    scheduler = DeliveryScheduler.ensure(Map.get(state, :voxel_delivery))
    state = Map.put(state, :voxel_delivery, scheduler)

    if DeliveryScheduler.queued?(scheduler) and is_nil(Map.get(state, :voxel_delivery_timer_ref)) do
      ref =
        Process.send_after(
          self(),
          :voxel_delivery_window,
          DeliveryScheduler.window_interval_ms(scheduler)
        )

      Map.put(state, :voxel_delivery_timer_ref, ref)
    else
      state
    end
  end

  defp clear_queued_voxel_delivery(state, logical_scene_id, chunk_coord) do
    scheduler =
      state
      |> Map.get(:voxel_delivery)
      |> DeliveryScheduler.ensure()
      |> DeliveryScheduler.prune_chunks(logical_scene_id, [chunk_coord])

    Map.put(state, :voxel_delivery, scheduler)
  end

  defp emit_voxel_delivery_scheduled(state, action) do
    GateServer.CliObserve.emit("voxel_live_delivery_scheduled", fn ->
      action
      |> voxel_delivery_action_observe()
      |> Map.merge(%{
        connection_pid: self(),
        cid: state.cid,
        transport: :websocket,
        subscription_count: map_size(state.voxel_subscriptions),
        delivery_summary: DeliveryScheduler.summary(Map.get(state, :voxel_delivery))
      })
    end)

    state
  end

  defp voxel_delivery_action_observe(action) do
    Map.take(action, [
      :action,
      :status,
      :frame_kind,
      :logical_scene_id,
      :chunk_coord,
      :object_id,
      :object_version,
      :affected_chunks,
      :region_id,
      :tick_count,
      :destroy_reason,
      :base_chunk_version,
      :chunk_version,
      :tier,
      :stream_class,
      :byte_size,
      :server_version,
      :lease_id,
      :owner_epoch,
      :metadata_source,
      :payload_decode_used,
      :bytes,
      :reason,
      :reason_name,
      :expected_byte_size,
      :actual_byte_size,
      :dropped_count,
      :pruned_count
    ])
  end

  defp record_forwarded_chunk_version(state, frame_kind, payload) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    case ChunkVersionLedger.record_payload(ledger, frame_kind, payload) do
      {:ok, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}

      {:error, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}
    end
  end

  defp clear_forwarded_chunk_version(state, payload) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    case ChunkVersionLedger.clear_invalidate_payload(ledger, payload) do
      {:ok, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}

      {:error, next_ledger, event} ->
        {Map.put(state, :forwarded_chunk_versions, next_ledger), event}
    end
  end

  defp clear_forwarded_chunk_version(state, logical_scene_id, chunk_coord) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    Map.put(
      state,
      :forwarded_chunk_versions,
      ChunkVersionLedger.clear_chunk(ledger, logical_scene_id, chunk_coord)
    )
  end

  defp clear_forwarded_chunk_version_from_action(
         state,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord} = action
       ) do
    ledger = Map.get(state, :forwarded_chunk_versions, ChunkVersionLedger.new())

    previous_version =
      Map.get(ChunkVersionLedger.known_versions(ledger, logical_scene_id), chunk_coord)

    event = %{
      status: if(is_nil(previous_version), do: :not_cached, else: :cleared),
      frame_kind: :invalidate,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      previous_version: previous_version,
      reason: Map.get(action, :reason),
      reason_name: Map.get(action, :reason_name)
    }

    {Map.put(
       state,
       :forwarded_chunk_versions,
       ChunkVersionLedger.clear_chunk(ledger, logical_scene_id, chunk_coord)
     ), event}
  end

  defp clear_client_ack_version(state, payload) do
    ledger = Map.get(state, :client_ack_versions, ClientAckLedger.new())

    case ClientAckLedger.clear_invalidate_payload(ledger, payload) do
      {:ok, next_ledger, event} ->
        {Map.put(state, :client_ack_versions, next_ledger), event}

      {:error, next_ledger, event} ->
        {Map.put(state, :client_ack_versions, next_ledger), event}
    end
  end

  defp clear_client_ack_version_from_action(
         state,
         %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord} = action
       ) do
    ledger = Map.get(state, :client_ack_versions, ClientAckLedger.new())

    previous_ack_version =
      Map.get(ClientAckLedger.known_versions(ledger, logical_scene_id), chunk_coord)

    event = %{
      status: if(is_nil(previous_ack_version), do: :not_acked, else: :cleared),
      frame_kind: :invalidate,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      previous_ack_version: previous_ack_version,
      reason: Map.get(action, :reason),
      reason_name: Map.get(action, :reason_name)
    }

    {Map.put(
       state,
       :client_ack_versions,
       ClientAckLedger.clear_chunk(ledger, logical_scene_id, chunk_coord)
     ), event}
  end

  defp client_ack_observe(%{status: :decode_failed} = event) do
    Map.take(event, [:status, :frame_kind, :reason])
  end

  defp client_ack_observe(event) when is_map(event) do
    Map.take(event, [
      :status,
      :frame_kind,
      :logical_scene_id,
      :chunk_coord,
      :previous_ack_version,
      :reason,
      :reason_name
    ])
  end

  defp chunk_version_observe(%{status: :decode_failed} = event) do
    Map.take(event, [:status, :frame_kind, :reason])
  end

  defp chunk_version_observe(event) when is_map(event) do
    Map.take(event, [
      :status,
      :frame_kind,
      :logical_scene_id,
      :chunk_coord,
      :previous_version,
      :base_chunk_version,
      :chunk_version,
      :reason,
      :reason_name
    ])
  end
end
