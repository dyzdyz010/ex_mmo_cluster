defmodule AuthServerWeb.GameWebSocket do
  @moduledoc """
  Raw binary WebSocket bridge for the browser game client.

  The socket owns no gameplay truth. It upgrades the browser connection and
  forwards binary frames into a `GateServer.WsConnection`, then pushes encoded
  replies back to the browser as binary frames.
  """

  @behaviour WebSock
  @bulk_opcodes MapSet.new([0x62, 0x63])
  @realtime_opcodes MapSet.new([0x83, 0x8B])
  @default_bulk_bytes_per_second 1_048_576
  @default_bulk_drain_interval_ms 0
  @default_realtime_drain_interval_ms 0
  @default_realtime_max_queue 128
  @default_visual_drain_interval_ms 250

  @impl true
  def init(_args) do
    {:ok, connection_pid} =
      DynamicSupervisor.start_child(
        GateServer.WsConnectionSup,
        {GateServer.WsConnection, self()}
      )

    {:ok, ensure_outbound_state(%{connection_pid: connection_pid})}
  end

  @impl true
  def handle_in({payload, [opcode: :binary]}, state) when is_binary(payload) do
    GenServer.cast(state.connection_pid, {:ws_frame, payload})
    {:ok, state}
  end

  def handle_in({_payload, [opcode: :text]}, state) do
    {:reply, :ok, {:text, "binary_frames_required"}, state}
  end

  @impl true
  def handle_info({:gate_ws_send, payload}, state)
      when is_binary(payload) or is_list(payload) do
    payload = IO.iodata_to_binary(payload)

    cond do
      bulk_payload?(payload) ->
        {:ok, enqueue_bulk_payload(state, payload)}

      realtime_payload?(payload) ->
        {:ok, enqueue_realtime_payload(state, payload)}

      visual_latest_payload?(payload) ->
        {:ok, enqueue_visual_latest_payload(state, payload)}

      true ->
        {:push, {:binary, payload}, state}
    end
  end

  def handle_info(:gate_ws_realtime_drain, state) do
    state =
      state
      |> ensure_outbound_state()
      |> Map.put(:gate_ws_realtime_drain_ref, nil)

    case :queue.out(state.gate_ws_realtime_queue) do
      {{:value, payload}, queue} ->
        state =
          state
          |> Map.put(:gate_ws_realtime_queue, queue)
          |> Map.update!(:gate_ws_realtime_queue_len, &max(&1 - 1, 0))
          |> schedule_realtime_drain()

        {:push, {:binary, payload}, state}

      {:empty, _queue} ->
        {:ok, state}
    end
  end

  def handle_info(:gate_ws_visual_drain, state) do
    state =
      state
      |> ensure_outbound_state()
      |> Map.put(:gate_ws_visual_drain_ref, nil)

    cond do
      realtime_queued?(state) ->
        {:ok, schedule_visual_drain(state)}

      true ->
        drain_visual_latest_payload(state)
    end
  end

  def handle_info(:gate_ws_bulk_drain, state) do
    state =
      state
      |> ensure_outbound_state()
      |> Map.put(:gate_ws_bulk_drain_ref, nil)

    cond do
      latest_queued?(state) ->
        {:ok, schedule_bulk_drain(state, @default_bulk_drain_interval_ms)}

      true ->
        drain_bulk_payload(state)
    end
  end

  def handle_info({:gate_ws_close, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    GenServer.cast(state.connection_pid, {:ws_closed, reason})
    :ok
  end

  defp drain_bulk_payload(state) do
    case :queue.out(state.gate_ws_bulk_queue) do
      {{:value, payload}, queue} ->
        state =
          state
          |> Map.put(:gate_ws_bulk_queue, queue)
          |> Map.update!(:gate_ws_bulk_queue_bytes, &max(&1 - byte_size(payload), 0))
          |> schedule_bulk_drain(byte_size(payload))

        {:push, {:binary, payload}, state}

      {:empty, _queue} ->
        {:ok, state}
    end
  end

  defp drain_visual_latest_payload(state) do
    case state.gate_ws_visual_order do
      [key | rest] ->
        {payload, latest} = Map.pop(state.gate_ws_visual_latest, key)

        state =
          state
          |> Map.put(:gate_ws_visual_order, rest)
          |> Map.put(:gate_ws_visual_latest, latest)
          |> schedule_visual_drain()

        {:push, {:binary, payload}, state}

      [] ->
        {:ok, state}
    end
  end

  defp bulk_payload?(<<opcode, _rest::binary>>), do: MapSet.member?(@bulk_opcodes, opcode)
  defp bulk_payload?(_payload), do: false

  defp realtime_payload?(<<opcode, _rest::binary>>) do
    MapSet.member?(@realtime_opcodes, opcode)
  end

  defp realtime_payload?(_payload), do: false

  defp visual_latest_payload?(<<0x73, _rest::binary>>), do: true
  defp visual_latest_payload?(_payload), do: false

  defp enqueue_bulk_payload(state, payload) do
    state = ensure_outbound_state(state)

    state
    |> Map.update!(:gate_ws_bulk_queue, &:queue.in(payload, &1))
    |> Map.update!(:gate_ws_bulk_queue_bytes, &(&1 + byte_size(payload)))
    |> schedule_bulk_drain(@default_bulk_drain_interval_ms)
  end

  defp enqueue_realtime_payload(state, payload) do
    state = ensure_outbound_state(state)
    max_queue = realtime_max_queue()

    {queue, queue_len} =
      if state.gate_ws_realtime_queue_len >= max_queue do
        {_dropped, queue} = :queue.out(state.gate_ws_realtime_queue)
        {queue, max(state.gate_ws_realtime_queue_len - 1, 0)}
      else
        {state.gate_ws_realtime_queue, state.gate_ws_realtime_queue_len}
      end

    state
    |> Map.put(:gate_ws_realtime_queue, :queue.in(payload, queue))
    |> Map.put(:gate_ws_realtime_queue_len, queue_len + 1)
    |> schedule_realtime_drain()
  end

  defp enqueue_visual_latest_payload(state, payload) do
    state = ensure_outbound_state(state)
    key = visual_latest_payload_key(payload)
    known? = Map.has_key?(state.gate_ws_visual_latest, key)

    state
    |> Map.update!(:gate_ws_visual_latest, &Map.put(&1, key, payload))
    |> maybe_append_visual_key(key, known?)
    |> schedule_visual_drain()
  end

  defp maybe_append_visual_key(state, _key, true), do: state

  defp maybe_append_visual_key(state, key, false) do
    Map.update!(state, :gate_ws_visual_order, &(&1 ++ [key]))
  end

  defp schedule_bulk_drain(state, delay_or_bytes) do
    state = ensure_outbound_state(state)

    cond do
      :queue.is_empty(state.gate_ws_bulk_queue) ->
        state

      not Map.has_key?(state, :connection_pid) ->
        state

      is_reference(state.gate_ws_bulk_drain_ref) ->
        state

      true ->
        delay_ms =
          if delay_or_bytes == @default_bulk_drain_interval_ms do
            bulk_initial_drain_interval_ms()
          else
            bulk_payload_drain_delay_ms(delay_or_bytes)
          end

        ref = Process.send_after(self(), :gate_ws_bulk_drain, delay_ms)
        Map.put(state, :gate_ws_bulk_drain_ref, ref)
    end
  end

  defp schedule_realtime_drain(state) do
    state = ensure_outbound_state(state)

    cond do
      not realtime_queued?(state) ->
        state

      not Map.has_key?(state, :connection_pid) ->
        state

      is_reference(state.gate_ws_realtime_drain_ref) ->
        state

      true ->
        ref =
          Process.send_after(
            self(),
            :gate_ws_realtime_drain,
            realtime_initial_drain_interval_ms()
          )

        Map.put(state, :gate_ws_realtime_drain_ref, ref)
    end
  end

  defp schedule_visual_drain(state) do
    state = ensure_outbound_state(state)

    cond do
      not visual_queued?(state) ->
        state

      not Map.has_key?(state, :connection_pid) ->
        state

      is_reference(state.gate_ws_visual_drain_ref) ->
        state

      true ->
        ref =
          Process.send_after(
            self(),
            :gate_ws_visual_drain,
            visual_initial_drain_interval_ms()
          )

        Map.put(state, :gate_ws_visual_drain_ref, ref)
    end
  end

  defp realtime_queued?(state) do
    state
    |> ensure_outbound_state()
    |> Map.fetch!(:gate_ws_realtime_queue)
    |> :queue.is_empty()
    |> Kernel.not()
  end

  defp visual_queued?(state) do
    state
    |> ensure_outbound_state()
    |> Map.fetch!(:gate_ws_visual_order)
    |> Enum.any?()
  end

  defp latest_queued?(state), do: realtime_queued?(state) or visual_queued?(state)

  defp visual_latest_payload_key(<<0x73, field_region_key::binary-size(28), _rest::binary>>) do
    {:field_region_snapshot, field_region_key}
  end

  defp visual_latest_payload_key(<<opcode, _rest::binary>>), do: {:opcode, opcode}

  defp bulk_payload_drain_delay_ms(bytes) do
    bytes_per_second = bulk_bytes_per_second()

    max(
      div(bytes * 1_000 + bytes_per_second - 1, bytes_per_second),
      bulk_initial_drain_interval_ms()
    )
  end

  defp bulk_bytes_per_second do
    env_positive_integer("AUTH_GAME_WS_BULK_BYTES_PER_SEC", @default_bulk_bytes_per_second)
  end

  defp bulk_initial_drain_interval_ms do
    env_non_negative_integer(
      "AUTH_GAME_WS_BULK_DRAIN_INTERVAL_MS",
      @default_bulk_drain_interval_ms
    )
  end

  defp realtime_initial_drain_interval_ms do
    env_non_negative_integer(
      "AUTH_GAME_WS_REALTIME_DRAIN_INTERVAL_MS",
      @default_realtime_drain_interval_ms
    )
  end

  defp realtime_max_queue do
    env_positive_integer(
      "AUTH_GAME_WS_REALTIME_MAX_QUEUE",
      @default_realtime_max_queue
    )
  end

  defp visual_initial_drain_interval_ms do
    env_non_negative_integer(
      "AUTH_GAME_WS_VISUAL_DRAIN_INTERVAL_MS",
      @default_visual_drain_interval_ms
    )
  end

  defp env_positive_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_positive_integer(value, default)
    end
  end

  defp env_non_negative_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> parse_non_negative_integer(value, default)
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp parse_non_negative_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end

  defp ensure_outbound_state(state) do
    state
    |> Map.put_new(:gate_ws_bulk_queue, :queue.new())
    |> Map.put_new(:gate_ws_bulk_queue_bytes, 0)
    |> Map.put_new(:gate_ws_bulk_drain_ref, nil)
    |> Map.put_new(:gate_ws_realtime_queue, :queue.new())
    |> Map.put_new(:gate_ws_realtime_queue_len, 0)
    |> Map.put_new(:gate_ws_realtime_drain_ref, nil)
    |> Map.put_new(:gate_ws_visual_latest, %{})
    |> Map.put_new(:gate_ws_visual_order, [])
    |> Map.put_new(:gate_ws_visual_drain_ref, nil)
  end
end
