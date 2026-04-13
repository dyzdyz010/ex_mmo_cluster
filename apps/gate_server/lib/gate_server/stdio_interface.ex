defmodule GateServer.StdioInterface do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :start_reader}}
  end

  @impl true
  def handle_continue(:start_reader, state) do
    owner = self()

    {:ok, _reader_pid} =
      Task.start_link(fn ->
        emit("ready", %{
          commands: [
            "help",
            "snapshot",
            "connections",
            "sessions",
            "fastlane",
            "players",
            "player <cid>",
            "player_state <cid>",
            "npcs",
            "npc <cid>",
            "npc_state <cid>"
          ]
        })

        IO.stream(:stdio, :line)
        |> Enum.each(fn line ->
          send(owner, {:stdio_line, String.trim(line)})
        end)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:stdio_line, ""}, state), do: {:noreply, state}

  def handle_info({:stdio_line, "help"}, state) do
    emit("help", %{
      commands: [
        "help",
        "snapshot",
        "connections",
        "sessions",
        "fastlane",
        "players",
        "player <cid>",
        "player_state <cid>",
        "npcs",
        "npc <cid>",
        "npc_state <cid>"
      ]
    })

    {:noreply, state}
  end

  def handle_info({:stdio_line, "snapshot"}, state) do
    emit("snapshot", snapshot())
    {:noreply, state}
  end

  def handle_info({:stdio_line, "connections"}, state) do
    emit("connections", %{connections: connection_snapshots()})
    {:noreply, state}
  end

  def handle_info({:stdio_line, "sessions"}, state) do
    emit("sessions", GateServer.FastLaneRegistry.snapshot())
    {:noreply, state}
  end

  def handle_info({:stdio_line, "fastlane"}, state) do
    emit("fastlane", GateServer.FastLaneRegistry.snapshot())
    {:noreply, state}
  end

  def handle_info({:stdio_line, "players"}, state) do
    emit("players", %{players: players_snapshot()})
    {:noreply, state}
  end

  def handle_info({:stdio_line, "npcs"}, state) do
    emit("npcs", %{npcs: npc_snapshots()})
    {:noreply, state}
  end

  def handle_info({:stdio_line, "player " <> cid_text}, state) do
    emit_player(cid_text)
    {:noreply, state}
  end

  def handle_info({:stdio_line, "player_state " <> cid_text}, state) do
    emit_player_state(cid_text)
    {:noreply, state}
  end

  def handle_info({:stdio_line, "npc " <> cid_text}, state) do
    emit_npc(cid_text)
    {:noreply, state}
  end

  def handle_info({:stdio_line, "npc_state " <> cid_text}, state) do
    emit_npc_state(cid_text)
    {:noreply, state}
  end

  def handle_info({:stdio_line, other}, state) do
    emit("error", %{reason: "unknown command", command: other})
    {:noreply, state}
  end

  defp emit_player(cid_text) do
    case Integer.parse(cid_text) do
      {cid, ""} ->
        emit("player", %{player: player_snapshot(cid)})

      _ ->
        emit("error", %{reason: "invalid cid"})
    end
  end

  defp emit_player_state(cid_text) do
    case Integer.parse(cid_text) do
      {cid, ""} ->
        emit("player_state", %{player_state: player_state_snapshot(cid)})

      _ ->
        emit("error", %{reason: "invalid cid"})
    end
  end

  defp emit_npc(cid_text) do
    case Integer.parse(cid_text) do
      {cid, ""} ->
        emit("npc", %{npc: npc_snapshot(cid)})

      _ ->
        emit("error", %{reason: "invalid cid"})
    end
  end

  defp emit_npc_state(cid_text) do
    case Integer.parse(cid_text) do
      {cid, ""} ->
        emit("npc_state", %{npc_state: npc_state_snapshot(cid)})

      _ ->
        emit("error", %{reason: "invalid cid"})
    end
  end

  defp snapshot do
    interface_state =
      if Process.whereis(GateServer.Interface) do
        :sys.get_state(GateServer.Interface)
      else
        nil
      end

    %{
      gate_interface: interface_state,
      connections: connection_snapshots(),
      fast_lane: GateServer.FastLaneRegistry.snapshot(),
      players: players_snapshot(),
      npcs: npc_snapshots()
    }
  end

  defp connection_snapshots do
    try do
      DynamicSupervisor.which_children(GateServer.TcpConnectionSup)
      |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
      |> Enum.map(fn pid ->
        state = :sys.get_state(pid)

        %{
          pid: inspect(pid),
          status: Map.get(state, :status),
          cid: Map.get(state, :cid),
          auth_username: Map.get(state, :auth_username),
          scene_ref: inspect(Map.get(state, :scene_ref)),
          udp_attached?: not is_nil(Map.get(state, :udp_peer))
        }
      end)
    catch
      :exit, _reason -> []
    end
  end

  defp players_snapshot do
    with {:ok, scene_node} <- safe_call(GateServer.Interface, :scene_server),
         {:ok, {:ok, players}} <-
           safe_call({SceneServer.PlayerManager, scene_node}, :get_all_players) do
      Enum.map(players, fn {cid, pid} ->
        location =
          case safe_call(pid, :get_location) do
            {:ok, {:ok, value}} -> value
            _ -> nil
          end

        %{cid: cid, pid: inspect(pid), location: location}
      end)
    else
      _ -> []
    end
  end

  defp player_snapshot(cid) when is_integer(cid) do
    with {:ok, scene_node} <- safe_call(GateServer.Interface, :scene_server),
         {:ok, {:ok, players}} <-
           safe_call({SceneServer.PlayerManager, scene_node}, :get_all_players),
         pid when is_pid(pid) <- Map.get(players, cid) do
      location =
        case safe_call(pid, :get_location) do
          {:ok, {:ok, value}} -> value
          _ -> nil
        end

      %{cid: cid, pid: inspect(pid), location: location}
    else
      _ -> nil
    end
  end

  defp player_state_snapshot(cid) when is_integer(cid) do
    with {:ok, scene_node} <- safe_call(GateServer.Interface, :scene_server),
         {:ok, {:ok, players}} <-
           safe_call({SceneServer.PlayerManager, scene_node}, :get_all_players),
         pid when is_pid(pid) <- Map.get(players, cid),
         {:ok, {:ok, summary}} <- safe_call(pid, :get_state_summary) do
      summary
    else
      _ -> nil
    end
  end

  defp npc_snapshots do
    with {:ok, scene_node} <- safe_call(GateServer.Interface, :scene_server),
         {:ok, {:ok, summaries}} <-
           safe_call({SceneServer.NpcManager, scene_node}, :get_all_npc_summaries) do
      summaries
      |> Enum.map(fn {cid, summary} ->
        %{
          cid: cid,
          name: Map.get(summary, :name),
          position: Map.get(summary, :position),
          hp: Map.get(summary, :hp),
          max_hp: Map.get(summary, :max_hp),
          alive: Map.get(summary, :alive),
          intent: Map.get(summary, :intent)
        }
      end)
      |> Enum.sort_by(& &1.cid)
    else
      _ -> []
    end
  end

  defp npc_snapshot(cid) when is_integer(cid) do
    with {:ok, scene_node} <- safe_call(GateServer.Interface, :scene_server),
         {:ok, {:ok, pid}} <- safe_call({SceneServer.NpcManager, scene_node}, {:get_npc, cid}),
         pid when is_pid(pid) <- pid,
         {:ok, {:ok, summary}} <- safe_call(pid, :get_state_summary) do
      summary
    else
      _ -> nil
    end
  end

  defp npc_state_snapshot(cid) when is_integer(cid) do
    npc_snapshot(cid)
  end

  defp safe_call(server, message) do
    try do
      {:ok, GenServer.call(server, message)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp emit(event, payload) do
    IO.puts("server_stdio event=#{inspect(event)} payload=#{inspect(payload, limit: :infinity)}")
  end
end
