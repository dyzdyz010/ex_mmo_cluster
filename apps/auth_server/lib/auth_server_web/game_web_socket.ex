defmodule AuthServerWeb.GameWebSocket do
  @moduledoc """
  Raw binary WebSocket bridge for the browser game client.

  The socket owns no gameplay truth. It upgrades the browser connection and
  forwards binary frames into a `GateServer.WsConnection`, then pushes encoded
  replies back to the browser as binary frames.
  """

  @behaviour WebSock

  @impl true
  def init(_args) do
    {:ok, connection_pid} =
      DynamicSupervisor.start_child(
        GateServer.WsConnectionSup,
        {GateServer.WsConnection, self()}
      )

    {:ok, %{connection_pid: connection_pid}}
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
    {:push, {:binary, IO.iodata_to_binary(payload)}, state}
  end

  def handle_info(_message, state) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    GenServer.cast(state.connection_pid, {:ws_closed, reason})
    :ok
  end
end
