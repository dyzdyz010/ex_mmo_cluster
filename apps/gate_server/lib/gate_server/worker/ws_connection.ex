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

  alias SceneServer.Combat.{EffectEvent, Skill}
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}
  alias SceneServer.Voxel.{NormalBlockData, PrefabRaster, Types}

  @scene_call_timeout 15_000
  @max_voxel_subscribe_radius 4

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

    GateServer.CliObserve.emit("ws_connection_init", %{
      connection_pid: self(),
      owner_pid: owner_pid
    })

    {:ok,
     %{
       owner_pid: owner_pid,
       cid: -1,
       agent: nil,
       auth_claims: nil,
       auth_username: nil,
       auth_session_id: nil,
       scene_ref: nil,
       token: nil,
       status: :waiting_auth,
       voxel_subscriptions: %{}
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
    GateServer.CliObserve.emit("ws_receive", fn ->
      %{connection_pid: self(), bytes: byte_size(data), status: state.status}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, msg} ->
        GateServer.CliObserve.emit("ws_decoded", fn ->
          %{connection_pid: self(), message: observe_message_summary(msg)}
        end)

        {:ok, new_state} = dispatch(msg, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("WS codec decode error: #{inspect(reason)}")
        send_result_error(state, reason, 0)
        {:noreply, state}
    end
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
    {next_state, result} =
      rebind_voxel_subscriptions_in_state(state, logical_scene_id, region_selector, reason)

    GateServer.CliObserve.emit("voxel_subscription_rebind_completed", %{
      connection_pid: self(),
      cid: state.cid,
      logical_scene_id: logical_scene_id,
      region_selector: region_selector,
      reason: reason,
      rebound_count: result.rebound_count,
      skipped_count: result.skipped_count,
      error_count: result.error_count,
      subscription_count: map_size(next_state.voxel_subscriptions)
    })

    {:noreply, next_state}
  end

  def handle_cast({:player_enter, cid, location}, state) do
    send_encoded(state, {:player_enter, cid, location})
    {:noreply, state}
  end

  def handle_cast({:player_leave, cid}, state) do
    send_encoded(state, {:player_leave, cid})
    {:noreply, state}
  end

  def handle_cast({:actor_identity, cid, actor_kind, actor_name}, state) do
    send_encoded(state, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  def handle_cast({:player_move, snapshot}, state) do
    snapshot = normalize_remote_snapshot(snapshot)

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

    send_encoded(state, player_move_message(snapshot))

    {:noreply, state}
  end

  def handle_cast({:movement_ack, ack}, state) do
    send_encoded(
      state,
      {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
       ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms, ack.ground_z}
    )

    {:noreply, state}
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

  @impl true
  def handle_info({:voxel_chunk_snapshot_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_chunk_snapshot_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(state, {:voxel_chunk_snapshot_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_chunk_delta_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_chunk_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(state, {:voxel_chunk_delta_payload, payload})
    {:noreply, state}
  end

  def handle_info({:voxel_chunk_invalidate_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_chunk_invalidate_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(state, {:voxel_chunk_invalidate_payload, payload})
    {:noreply, state}
  end

  # Phase 4-bis (D7):forward 0x6C ObjectStateDelta from ChunkProcess fan-out
  # to the WebSocket frame stream. ObjectRegistry encoded the binary once;
  # ChunkProcess cast it into our mailbox via `send/2`;we just prefix the
  # opcode (Codec) and ship a binary frame.
  def handle_info({:voxel_object_state_delta_payload, payload}, state) when is_binary(payload) do
    GateServer.CliObserve.emit("ws_voxel_object_state_delta_forwarded", %{
      connection_pid: self(),
      cid: state.cid,
      bytes: byte_size(payload),
      subscription_count: map_size(state.voxel_subscriptions)
    })

    send_encoded(state, {:voxel_object_state_delta_payload, payload})
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_voxel_subscriptions(state)
    cleanup_scene(state.scene_ref)
    :ok
  end

  defp dispatch(
         {:movement_input, frame_params},
         %{status: :in_scene, scene_ref: spid} = state
       ) do
    frame = build_input_frame(frame_params)

    case accept_movement_input(spid, frame) do
      {:ok, ack} -> GenServer.cast(self(), {:movement_ack, ack})
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
         {:ok, ppid} <- add_player(scene_node, cid, timestamp, build_character_profile(character)),
         {:ok, {x, y, z}} <- fetch_player_location(ppid),
         {:ok, expected_seq} <- fetch_next_input_seq(ppid) do
      send_encoded(state, {:enter_scene_result, :ok, request_id, {x, y, z}, expected_seq})

      {:ok,
       %{
         state
         | scene_ref: ppid,
           cid: cid,
           status: :in_scene,
           agent: with_active_cid(state.agent, cid)
       }}
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

    case subscribe_voxel_chunks(request, state) do
      {:ok, next_state, result} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_ok", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_count: result.chunk_count,
          subscription_count: map_size(next_state.voxel_subscriptions)
        })

        {:ok, next_state}

      {:error, reason} ->
        GateServer.CliObserve.emit("ws_voxel_chunk_subscribe_error", %{
          connection_pid: self(),
          cid: state.cid,
          request_id: request.request_id,
          reason: reason
        })

        send_encoded(state, voxel_result_error(request, reason))
        {:ok, state}
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

  defp send_encoded(state, message) do
    {:ok, iodata} = GateServer.Codec.encode(message)
    send(state.owner_pid, {:gate_ws_send, IO.iodata_to_binary(iodata)})
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

  defp fetch_scene_node_for_owner(owner_scene_instance_ref) do
    case safe_call(GateServer.Interface, {:scene_server_for_owner, owner_scene_instance_ref}) do
      {:ok, nil} -> {:error, :scene_unavailable}
      {:ok, scene_node} -> {:ok, scene_node}
      {:error, _reason} -> fetch_scene_node()
    end
  end

  defp fetch_world_node do
    case safe_call(GateServer.Interface, :world_server) do
      {:ok, nil} -> {:error, :world_unavailable}
      {:ok, world_node} -> {:ok, world_node}
      {:error, _reason} -> {:error, :world_unavailable}
    end
  end

  defp add_player(scene_node, cid, timestamp, character_profile) do
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
    do: %{name: "unknown", position: {750.0, 750.0, 100.0}}

  # Default spawn over the DevSeed 16×16 stone platform on chunk (0,0,0).
  # Movement world coords use server Z as vertical. The browser maps this spawn
  # to x=750,y=100,z=750, above DevSeed's voxel y=0 platform centered at x/z =
  # 750 in renderer units.
  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 750.0)
    y = map_float(position, ["y", :y], 750.0)
    z = map_float(position, ["z", :z], 100.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {750.0, 750.0, 100.0}

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
    case safe_call(spid, {:movement_input, frame}) do
      {:ok, {:ok, :accepted}} -> :accepted
      {:ok, {:ok, ack}} -> {:ok, ack}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
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

  defp apply_voxel_impact_intent(request, state) do
    with :ok <- authorize_voxel_impact_intent(request, state),
         {:ok, target} <- voxel_impact_target(request),
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

  defp fetch_scene_node_for_route(route) do
    route
    |> Map.fetch!(:lease)
    |> Map.fetch!(:owner_scene_instance_ref)
    |> fetch_scene_node_for_owner()
  end

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
         {:ok, cells} <-
           PrefabRaster.rasterize(
             request.blueprint_id,
             request.blueprint_version,
             request.anchor_world_micro,
             request.rotation
           ) do
      run_prefab_transaction(cells, request, state)
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

  # Phase 3: 0x67 prefab now goes through World's TransactionCoordinator +
  # TransactionExecutor. Cells are grouped by chunk_coord into one batch per
  # chunk; the whole prefab commits atomically (any chunk's prepare or apply
  # failure rolls back every fence) or aborts atomically (no partial writes).
  defp run_prefab_transaction([], _request, _state) do
    {:ok, %{cell_count: 0, chunk_count: 0, max_chunk_version: 0}}
  end

  defp run_prefab_transaction(cells, request, state) do
    total = length(cells)

    with {:ok, plan} <- build_prefab_plan(cells, request, state),
         {:ok, coordinator_ref} <- locate_voxel_transaction_coordinator(),
         {:ok, transaction} <-
           coordinator_begin_transaction(coordinator_ref, plan, request),
         {:ok, executor_result} <-
           executor_execute(coordinator_ref, transaction, plan) do
      finalize_prefab_outcome(executor_result, plan, total)
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  # Phase A4-2:per-chunk routing + multi-participant grouping。每个 chunk
  # 独立 route_voxel_chunk;按 {region_id, lease_id} 分组成 participants;
  # 任一 chunk 路由失败 fail-fast 返回 :no_route_for_chunk(D5)。同 lease
  # 内 scene_node 由 owner_scene_instance_ref 唯一决定,无需一致性校验。
  defp build_prefab_plan(cells, request, state) do
    cells_by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    chunk_coords = Map.keys(cells_by_chunk)

    case chunk_coords do
      [] ->
        {:error, :empty_prefab}

      coords ->
        with {:ok, routes_by_chunk} <- route_all_chunks(request.logical_scene_id, coords),
             {:ok, participants} <-
               build_prefab_participants(routes_by_chunk, cells_by_chunk, request) do
          emit_prefab_routed_observe(request, state, participants, length(cells))

          {:ok,
           %{
             participants: participants,
             chunk_coords: coords
           }}
        end
    end
  end

  defp route_all_chunks(logical_scene_id, chunk_coords) do
    Enum.reduce_while(chunk_coords, {:ok, %{}}, fn coord, {:ok, acc} ->
      case route_voxel_chunk(logical_scene_id, coord) do
        {:ok, route} ->
          {:cont, {:ok, Map.put(acc, coord, route)}}

        {:error, _reason} ->
          {:halt, {:error, :no_route_for_chunk}}
      end
    end)
  end

  defp build_prefab_participants(routes_by_chunk, cells_by_chunk, request) do
    chunks_by_participant_key =
      Enum.group_by(
        routes_by_chunk,
        fn {_coord, route} ->
          lease = Map.fetch!(route, :lease)
          {lease.region_id, lease.lease_id}
        end,
        fn {coord, _route} -> coord end
      )

    Enum.reduce_while(chunks_by_participant_key, {:ok, []}, fn {key, chunks}, {:ok, acc} ->
      first_route = Map.fetch!(routes_by_chunk, List.first(chunks))

      case fetch_scene_node_for_route(first_route) do
        {:ok, scene_node} ->
          lease = Map.fetch!(first_route, :lease)
          chunks_sorted = Enum.sort(chunks)

          intents_by_chunk =
            chunks_sorted
            |> Enum.map(fn chunk_coord ->
              cells_in_chunk = Map.fetch!(cells_by_chunk, chunk_coord)
              {chunk_coord, prefab_intents_for_chunk(cells_in_chunk, request, chunk_coord, lease)}
            end)
            |> Map.new()

          participant = %{
            participant_key: key,
            lease: lease,
            scene_node: scene_node,
            chunk_coords: chunks_sorted,
            intents_by_chunk: intents_by_chunk
          }

          {:cont, {:ok, [participant | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, participants} -> {:ok, Enum.reverse(participants)}
      {:error, _} = err -> err
    end
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
        opts: []
      }
    end)
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
              region_id: p.lease.region_id,
              lease_id: p.lease.lease_id,
              owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
              owner_epoch: p.lease.owner_epoch,
              scene_node: p.scene_node,
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
            region_id: p.lease.region_id,
            lease_id: p.lease.lease_id,
            owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
            owner_epoch: p.lease.owner_epoch,
            affected_chunks: p.chunk_coords
          }
        end)
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

  # Phase A4-2:plan.participants 已经按 {region_id, lease_id} 分组,这里直接
  # 把每个 participant 的 intents_by_chunk + scene_node 摊成 by-participant
  # 两份 map 喂给 executor。同 region 单 participant 是退化情形;跨 region 时
  # 每个 participant 用各自 scene_node 的 ChunkDirectory。
  defp executor_execute(coordinator_ref, transaction, plan) do
    intents_by_participant =
      plan.participants
      |> Enum.map(fn p -> {p.participant_key, p.intents_by_chunk} end)
      |> Map.new()

    scene_opts_by_participant =
      plan.participants
      |> Enum.map(fn p ->
        {p.participant_key, [chunk_directory: {SceneServer.Voxel.ChunkDirectory, p.scene_node}]}
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

  defp emit_voxel_chunk_subscribe_routed(request, state, route) do
    assignment = Map.fetch!(route, :assignment)
    lease = Map.fetch!(route, :lease)

    GateServer.CliObserve.emit("voxel_chunk_subscribe_routed", %{
      connection_pid: self(),
      cid: state.cid,
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      center_chunk: request.center_chunk,
      region_id: assignment.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch
    })
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
    with :ok <- validate_voxel_subscribe_radius(request.radius_l_inf) do
      coords = voxel_subscription_coords(request.center_chunk, request.radius_l_inf)
      known_versions = voxel_known_versions(Map.get(request, :known, []))

      Enum.reduce_while(coords, {:ok, state, []}, fn chunk_coord, {:ok, acc_state, new_keys} ->
        case subscribe_voxel_chunk(request, chunk_coord, known_versions, acc_state) do
          {:ok, next_state, subscription} when is_map(subscription) ->
            {:cont, {:ok, next_state, [subscription | new_keys]}}

          {:ok, next_state, nil} ->
            {:cont, {:ok, next_state, new_keys}}

          {:error, reason} ->
            rollback_voxel_subscriptions(new_keys)
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, next_state, _new_keys} ->
          {:ok, next_state, %{chunk_count: length(coords)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp subscribe_voxel_chunk(request, chunk_coord, known_versions, state) do
    with {:ok, route} <- route_voxel_chunk(request.logical_scene_id, chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      emit_voxel_chunk_subscribe_routed(%{request | center_chunk: chunk_coord}, state, route)
      lease = Map.fetch!(route, :lease)

      attrs = %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        subscriber: self(),
        lease: lease,
        send_snapshot?: request.want_snapshot,
        known_version: Map.get(known_versions, chunk_coord)
      }

      case safe_call(
             {SceneServer.Voxel.ChunkDirectory, scene_node},
             {:subscribe, attrs},
             @scene_call_timeout
           ) do
        {:ok, {:ok, _payload}} ->
          key = voxel_subscription_key(request.logical_scene_id, chunk_coord)
          already_subscribed? = Map.has_key?(state.voxel_subscriptions, key)

          subscription = %{
            logical_scene_id: request.logical_scene_id,
            chunk_coord: chunk_coord,
            request_id: request.request_id,
            scene_node: scene_node,
            region_id: lease.region_id,
            lease_id: lease.lease_id,
            owner_scene_instance_ref: lease.owner_scene_instance_ref,
            owner_epoch: lease.owner_epoch
          }

          next_state = put_in(state.voxel_subscriptions[key], subscription)
          {:ok, next_state, if(already_subscribed?, do: nil, else: subscription)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:ok, _other} ->
          {:error, :scene_unavailable}

        {:error, _reason} ->
          {:error, :scene_unavailable}
      end
    end
  end

  defp rebind_voxel_subscriptions_in_state(state, logical_scene_id, region_selector, reason) do
    GateServer.CliObserve.emit("voxel_subscription_rebind_requested", %{
      connection_pid: self(),
      cid: state.cid,
      logical_scene_id: logical_scene_id,
      region_selector: region_selector,
      reason: reason,
      subscription_count: map_size(state.voxel_subscriptions)
    })

    Enum.reduce(
      state.voxel_subscriptions,
      {state, %{rebound_count: 0, skipped_count: 0, error_count: 0}},
      fn {key, subscription}, {acc_state, acc_result} ->
        if rebind_subscription_selected?(subscription, logical_scene_id, region_selector) do
          case rebind_voxel_subscription(subscription, reason) do
            {:ok, next_subscription, :rebound} ->
              {put_in(acc_state.voxel_subscriptions[key], next_subscription),
               Map.update!(acc_result, :rebound_count, &(&1 + 1))}

            {:ok, _next_subscription, :skipped} ->
              {acc_state, Map.update!(acc_result, :skipped_count, &(&1 + 1))}

            {:error, reason} ->
              GateServer.CliObserve.emit("voxel_subscription_rebind_error", %{
                connection_pid: self(),
                cid: state.cid,
                logical_scene_id: subscription.logical_scene_id,
                chunk_coord: subscription.chunk_coord,
                region_id: Map.get(subscription, :region_id),
                reason: reason
              })

              {acc_state, Map.update!(acc_result, :error_count, &(&1 + 1))}
          end
        else
          {acc_state, acc_result}
        end
      end
    )
  end

  defp rebind_subscription_selected?(subscription, logical_scene_id, region_selector) do
    subscription.logical_scene_id == logical_scene_id and
      (region_selector == :all or Map.get(subscription, :region_id) == region_selector)
  end

  defp rebind_voxel_subscription(subscription, reason) do
    with {:ok, route} <-
           route_voxel_chunk(subscription.logical_scene_id, subscription.chunk_coord),
         {:ok, scene_node} <- fetch_scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_subscription_rebind_routed", %{
        connection_pid: self(),
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
        GateServer.CliObserve.emit("voxel_subscription_rebind_skipped", %{
          connection_pid: self(),
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          lease_id: lease.lease_id,
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          owner_epoch: lease.owner_epoch
        })

        {:ok, subscription, :skipped}
      else
        subscribe_attrs = %{
          request_id: subscription.request_id,
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          subscriber: self(),
          lease: lease,
          send_snapshot?: true,
          known_version: nil
        }

        case safe_call(
               {SceneServer.Voxel.ChunkDirectory, scene_node},
               {:subscribe, subscribe_attrs},
               @scene_call_timeout
             ) do
          {:ok, {:ok, _payload}} ->
            maybe_unsubscribe_rebound_source(subscription, scene_node)

            next_subscription = %{
              subscription
              | scene_node: scene_node,
                region_id: lease.region_id,
                lease_id: lease.lease_id,
                owner_scene_instance_ref: lease.owner_scene_instance_ref,
                owner_epoch: lease.owner_epoch
            }

            GateServer.CliObserve.emit("voxel_subscription_rebind_subscribed_new", %{
              connection_pid: self(),
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
    end
  end

  defp subscription_matches_route?(subscription, scene_node, lease) do
    Map.get(subscription, :scene_node) == scene_node and
      Map.get(subscription, :lease_id) == lease.lease_id and
      Map.get(subscription, :owner_scene_instance_ref) == lease.owner_scene_instance_ref and
      Map.get(subscription, :owner_epoch) == lease.owner_epoch
  end

  defp maybe_unsubscribe_rebound_source(subscription, new_scene_node) do
    if Map.get(subscription, :scene_node) != new_scene_node do
      scene_unsubscribe(subscription)

      GateServer.CliObserve.emit("voxel_subscription_rebind_unsubscribed_old", %{
        connection_pid: self(),
        logical_scene_id: subscription.logical_scene_id,
        chunk_coord: subscription.chunk_coord,
        scene_node: Map.get(subscription, :scene_node),
        lease_id: Map.get(subscription, :lease_id),
        owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
        owner_epoch: Map.get(subscription, :owner_epoch)
      })
    end
  end

  defp unsubscribe_voxel_chunks(request, state) do
    Enum.reduce(request.chunks, {0, state}, fn chunk_coord, {count, acc_state} ->
      case unsubscribe_voxel_chunk(request.logical_scene_id, chunk_coord, acc_state) do
        {:ok, next_state} -> {count + 1, next_state}
        :not_subscribed -> {count, acc_state}
      end
    end)
  end

  defp unsubscribe_voxel_chunk(logical_scene_id, chunk_coord, state) do
    key = voxel_subscription_key(logical_scene_id, chunk_coord)

    case Map.pop(state.voxel_subscriptions, key) do
      {nil, _subscriptions} ->
        :not_subscribed

      {subscription, subscriptions} ->
        scene_unsubscribe(subscription)
        {:ok, %{state | voxel_subscriptions: subscriptions}}
    end
  end

  defp cleanup_voxel_subscriptions(%{voxel_subscriptions: subscriptions}) do
    Enum.each(subscriptions, fn {_key, subscription} -> scene_unsubscribe(subscription) end)
    :ok
  end

  defp rollback_voxel_subscriptions(subscriptions) do
    Enum.each(subscriptions, &scene_unsubscribe/1)
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

  defp voxel_subscription_coords({cx, cy, cz}, radius) do
    for x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius) do
      {x, y, z}
    end
  end

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
        {next_state, result} =
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
    [
      "voxel_sync=server-authoritative",
      "voxel_truth_source=server",
      "connection_status=#{state.status}",
      "cid=#{state.cid}",
      "scene_attached=#{not is_nil(state.scene_ref)}",
      "voxel_subscription_count=#{map_size(state.voxel_subscriptions)}",
      "voxel_subscriptions=#{inspect(state.voxel_subscriptions |> Map.keys() |> Enum.take(16))}",
      "voxel_subscription_routes=#{inspect(voxel_subscription_debug(state.voxel_subscriptions))}",
      "confirmed_chunk_versions={}",
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
         } = snapshot
       ) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode}
  end

  defp player_move_message(%RemoteSnapshot{} = snapshot) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode, snapshot.priority_band,
     snapshot.priority_score, snapshot.observer_distance, snapshot.delivery_interval}
  end
end
