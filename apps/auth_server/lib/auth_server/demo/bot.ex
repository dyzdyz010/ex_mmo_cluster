defmodule Demo.Bot do
  @moduledoc """
  Scripted protocol bot used by `mix demo.run`.

  The bot intentionally traverses the real auth/gate/scene path instead of
  bypassing runtime boundaries with scene-local placeholder actors. It can
  attach the UDP fast lane, move around a small waypoint loop, and periodically
  emit chat and skill traffic so a human Bevy client can immediately observe
  AOI fan-out and the control/data-plane split.
  """

  use GenServer

  require Logger

  alias Demo.Protocol

  @connect_retry_ms 1_000
  @tcp_control_transport :tcp
  @udp_transport :udp

  @doc """
  Starts one scripted demo bot against the real gate/auth/scene pipeline.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      actor: Keyword.fetch!(opts, :actor),
      gate_addr: Keyword.fetch!(opts, :gate_addr),
      notify: Keyword.get(opts, :notify),
      tcp: nil,
      udp: nil,
      gate_host: nil,
      gate_port: nil,
      gate_udp_port: nil,
      gate_ip: nil,
      next_request_id: 1,
      generation: 0,
      auth_request_id: nil,
      enter_scene_request_id: nil,
      fast_lane_request_id: nil,
      fast_lane_attach_request_id: nil,
      attached_udp?: false,
      position: nil,
      movement_index: 0,
      next_input_seq: 1,
      next_client_tick: 1,
      chat_index: 0,
      last_move_transport: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect_tcp(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[demo.bot #{state.actor.username}] connect failed: #{inspect(reason)}")
        Process.send_after(self(), :connect, @connect_retry_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:scheduled, generation, :movement_tick}, %{generation: generation} = state) do
    state =
      if state.position do
        send_demo_movement(state)
      else
        state
      end

    schedule(:movement_tick, state.actor.movement_interval_ms, generation)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled, generation, :chat_tick}, %{generation: generation} = state) do
    state = send_demo_chat(state)
    schedule(:chat_tick, state.actor.chat_interval_ms, generation)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled, generation, :skill_tick}, %{generation: generation} = state) do
    state = send_demo_skill(state)
    schedule(:skill_tick, state.actor.skill_interval_ms, generation)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled, generation, :heartbeat_tick}, %{generation: generation} = state) do
    state = send_tcp_payload(state, Protocol.encode_heartbeat(now_ms()))
    schedule(:heartbeat_tick, state.actor.heartbeat_interval_ms, generation)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled, generation, :time_sync_tick}, %{generation: generation} = state) do
    {request_id, state} = next_request_id(state)
    state = send_tcp_payload(state, Protocol.encode_time_sync(request_id, now_ms()))
    schedule(:time_sync_tick, state.actor.time_sync_interval_ms, generation)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduled, _generation, _message}, state), do: {:noreply, state}

  @impl true
  def handle_info({:tcp, socket, payload}, %{tcp: socket} = state) do
    {:noreply, handle_tcp_payload(payload, state)}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, payload}, %{udp: socket} = state) do
    {:noreply, handle_udp_payload(payload, state)}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("[demo.bot #{state.actor.username}] tcp closed, retrying")
    notify(state, {:disconnected, :tcp_closed})
    Process.send_after(self(), :connect, @connect_retry_ms)
    {:noreply, reset_runtime(state)}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("[demo.bot #{state.actor.username}] tcp error: #{inspect(reason)}")
    notify(state, {:disconnected, reason})
    Process.send_after(self(), :connect, @connect_retry_ms)
    {:noreply, reset_runtime(state)}
  end

  @impl true
  def terminate(_reason, state) do
    close_udp(state.udp)
    close_tcp(state.tcp)
    :ok
  end

  defp connect_tcp(state) do
    with {:ok, {host, port}} <- Protocol.parse_gate_addr(state.gate_addr),
         {:ok, gate_ip} <- resolve_host(host),
         {:ok, tcp} <-
           :gen_tcp.connect(
             gate_ip,
             port,
             [:binary, packet: 4, active: true, nodelay: true]
           ) do
      {request_id, state} =
        next_request_id(%{state | tcp: tcp, gate_host: host, gate_port: port, gate_ip: gate_ip})

      :ok =
        :gen_tcp.send(
          tcp,
          Protocol.encode_auth_request(state.actor.username, state.actor.token, request_id)
        )

      notify(state, :connected)

      {:ok, %{state | auth_request_id: request_id}}
    end
  end

  defp handle_tcp_payload(payload, state) do
    case Protocol.decode_server(payload) do
      {:ok, {:result, :ok, request_id}} when request_id == state.auth_request_id ->
        {enter_request_id, state} = next_request_id(state)

        :ok =
          :gen_tcp.send(state.tcp, Protocol.encode_enter_scene(state.actor.cid, enter_request_id))

        %{state | enter_scene_request_id: enter_request_id}

      {:ok, {:enter_scene_result, :ok, request_id, location}}
      when request_id == state.enter_scene_request_id ->
        notify(state, {:entered_scene, location})

        {fast_lane_request_id, state} = next_request_id(state)
        :ok = :gen_tcp.send(state.tcp, Protocol.encode_fast_lane_request(fast_lane_request_id))

        schedule_demo_ticks(state)

        %{state | position: location, fast_lane_request_id: fast_lane_request_id}

      {:ok, {:fast_lane_result, :ok, request_id, udp_port, ticket}}
      when request_id == state.fast_lane_request_id and is_integer(udp_port) and is_binary(ticket) ->
        case open_udp_socket(state, udp_port) do
          {:ok, udp_socket} ->
            {attach_request_id, state} = next_request_id(%{state | udp: udp_socket})

            :ok =
              :gen_udp.send(
                udp_socket,
                state.gate_ip,
                udp_port,
                Protocol.encode_fast_lane_attach(attach_request_id, ticket)
              )

            %{state | fast_lane_attach_request_id: attach_request_id, gate_udp_port: udp_port}

          {:error, reason} ->
            Logger.warning(
              "[demo.bot #{state.actor.username}] udp fast lane unavailable: #{inspect(reason)}"
            )

            notify(state, {:fast_lane_failed, reason})
            state
        end

      {:ok,
       {:movement_ack, _ack_seq, _auth_tick, _cid, location, _velocity, _acceleration,
        _movement_mode, _correction_flags}} ->
        notify(state, {:movement_ack, state.last_move_transport || @tcp_control_transport})
        %{state | position: location}

      {:ok, {:chat_message, cid, username, text}} ->
        notify(state, {:chat_message, cid, username, text})
        state

      {:ok, {:skill_event, cid, skill_id, location}} ->
        notify(state, {:skill_event, cid, skill_id, location})
        state

      {:ok, {:player_state, cid, hp, max_hp, alive}} ->
        notify(state, {:player_state, cid, hp, max_hp, alive})
        state

      {:ok, {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}} ->
        notify(
          state,
          {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
        )

        state

      {:ok, {:player_enter, cid, location}} ->
        notify(state, {:player_enter, cid, location})
        state

      {:ok, {:player_move, cid, _server_tick, location, _velocity, _acceleration, _movement_mode}} ->
        notify(state, {:player_move, cid, location, @tcp_control_transport})
        state

      {:ok, {:player_leave, cid}} ->
        notify(state, {:player_leave, cid})
        state

      {:ok, {:actor_identity, cid, actor_kind, name}} ->
        notify(state, {:actor_identity, cid, actor_kind, name})
        state

      {:ok, other} ->
        notify(state, {:tcp_message, other})
        state

      {:error, reason} ->
        Logger.warning("[demo.bot #{state.actor.username}] tcp decode error: #{inspect(reason)}")
        state
    end
  end

  defp handle_udp_payload(payload, state) do
    case Protocol.decode_server(payload) do
      {:ok, {:fast_lane_attached, :ok, request_id}}
      when request_id == state.fast_lane_attach_request_id ->
        notify(state, :fast_lane_attached)
        %{state | attached_udp?: true}

      {:ok,
       {:movement_ack, _ack_seq, _auth_tick, _cid, location, _velocity, _acceleration,
        _movement_mode, _correction_flags}} ->
        notify(state, {:movement_ack, @udp_transport})
        %{state | position: location}

      {:ok, {:player_move, cid, _server_tick, location, _velocity, _acceleration, _movement_mode}} ->
        notify(state, {:player_move, cid, location, @udp_transport})
        state

      {:ok, {:fast_lane_attached, :error, request_id}}
      when request_id == state.fast_lane_attach_request_id ->
        notify(state, {:fast_lane_failed, :attach_rejected})
        %{state | attached_udp?: false}

      {:ok, other} ->
        notify(state, {:udp_message, other})
        state

      {:error, reason} ->
        Logger.warning("[demo.bot #{state.actor.username}] udp decode error: #{inspect(reason)}")
        state
    end
  end

  defp send_demo_movement(state) do
    target = Enum.at(state.actor.movement_points, state.movement_index)
    direction = movement_direction(state.position || target, target)
    movement_flags = movement_flags(direction)

    payload =
      Protocol.encode_movement_input(
        state.next_input_seq,
        state.next_client_tick,
        direction,
        state.actor.movement_interval_ms,
        1.0,
        movement_flags
      )

    next_index =
      if reached_waypoint?(state.position, target) do
        next_index(state.movement_index, state.actor.movement_points)
      else
        state.movement_index
      end

    state =
      if state.attached_udp? and state.udp do
        :ok = :gen_udp.send(state.udp, state.gate_ip, state.gate_udp_port, payload)

        %{
          state
          | movement_index: next_index,
            next_input_seq: state.next_input_seq + 1,
            next_client_tick: state.next_client_tick + 1,
            last_move_transport: @udp_transport
        }
      else
        :ok = :gen_tcp.send(state.tcp, payload)

        %{
          state
          | movement_index: next_index,
            next_input_seq: state.next_input_seq + 1,
            next_client_tick: state.next_client_tick + 1,
            last_move_transport: @tcp_control_transport
        }
      end

    notify(
      state,
      {:movement_sent, state.last_move_transport || @tcp_control_transport, target, direction}
    )

    state
  end

  defp send_demo_chat(state) do
    line = Enum.at(state.actor.chat_lines, state.chat_index)

    if is_binary(line) and line != "" do
      {request_id, state} = next_request_id(state)
      :ok = :gen_tcp.send(state.tcp, Protocol.encode_chat_say(line, request_id))
      notify(state, {:chat_sent, line})
      %{state | chat_index: next_index(state.chat_index, state.actor.chat_lines)}
    else
      state
    end
  end

  defp send_demo_skill(state) do
    {request_id, state} = next_request_id(state)
    :ok = :gen_tcp.send(state.tcp, Protocol.encode_skill_cast(state.actor.skill_id, request_id))
    notify(state, {:skill_sent, state.actor.skill_id})
    state
  end

  defp open_udp_socket(state, udp_port) do
    with {:ok, udp_socket} <- :gen_udp.open(0, [:binary, active: true]) do
      notify(state, {:fast_lane_bootstrap, udp_port})
      {:ok, udp_socket}
    end
  end

  defp schedule_demo_ticks(state) do
    schedule(:movement_tick, state.actor.movement_interval_ms, state.generation)
    schedule(:chat_tick, state.actor.chat_interval_ms, state.generation)
    schedule(:skill_tick, state.actor.skill_interval_ms, state.generation)
    schedule(:heartbeat_tick, state.actor.heartbeat_interval_ms, state.generation)
    schedule(:time_sync_tick, state.actor.time_sync_interval_ms, state.generation)
  end

  defp schedule(message, delay_ms, generation) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), {:scheduled, generation, message}, delay_ms)
  end

  defp next_request_id(state) do
    {state.next_request_id, %{state | next_request_id: state.next_request_id + 1}}
  end

  defp reset_runtime(state) do
    close_udp(state.udp)
    close_tcp(state.tcp)

    %{
      state
      | tcp: nil,
        udp: nil,
        gate_udp_port: nil,
        generation: state.generation + 1,
        auth_request_id: nil,
        enter_scene_request_id: nil,
        fast_lane_request_id: nil,
        fast_lane_attach_request_id: nil,
        attached_udp?: false,
        position: nil,
        movement_index: 0,
        next_input_seq: 1,
        next_client_tick: 1,
        last_move_transport: nil
    }
  end

  defp movement_direction({x, y, _z}, {tx, ty, _tz}) do
    dx = tx - x
    dy = ty - y
    magnitude = :math.sqrt(dx * dx + dy * dy)

    if magnitude <= 1.0e-6 do
      {0.0, 0.0}
    else
      {dx / magnitude, dy / magnitude}
    end
  end

  defp movement_flags({x, y}) when abs(x) <= 1.0e-6 and abs(y) <= 1.0e-6, do: 0b10
  defp movement_flags(_direction), do: 0

  defp reached_waypoint?(nil, _target), do: false

  defp reached_waypoint?({x, y, _z}, {tx, ty, _tz}) do
    dx = tx - x
    dy = ty - y
    :math.sqrt(dx * dx + dy * dy) <= 24.0
  end

  defp resolve_host(host) when is_binary(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_tcp(nil), do: :ok
  defp close_tcp(socket) when is_port(socket), do: :gen_tcp.close(socket)
  defp close_tcp(_socket), do: :ok

  defp close_udp(nil), do: :ok
  defp close_udp(socket) when is_port(socket), do: :gen_udp.close(socket)
  defp close_udp(_socket), do: :ok

  defp next_index(index, values) when is_list(values) and values != [] do
    rem(index + 1, length(values))
  end

  defp notify(state, event) do
    if is_pid(state.notify) do
      send(state.notify, {:demo_bot_event, state.actor.username, event})
    end
  end

  defp send_tcp_payload(%{tcp: nil} = state, _payload), do: state

  defp send_tcp_payload(state, payload) do
    :ok = :gen_tcp.send(state.tcp, payload)
    state
  end

  defp now_ms, do: System.system_time(:millisecond)
end
