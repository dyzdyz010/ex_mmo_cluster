defmodule GateServer.Message do
  require Logger

  @doc """
  Parse incoming tcp message from protobuf to elixir terms.
  """
  @spec decode(binary) :: {:ok, struct} | {:error, any}
  def decode(data) do
    case Protox.decode(data, Packet) do
      {:ok, packet} ->
        # Logger.debug("Decoded packet: #{inspect(packet, pretty: true)}")
        {:ok, packet}

      err ->
        err
    end
  end

  @doc """
  Encode proto struct to IO data
  """
  @spec encode(struct) :: {:ok, iodata} | {:error, any}
  def encode(packet) do
    # Logger.debug("Packet to encode: #{inspect(packet, pretty: true)}")

    case Protox.encode(packet) do
      {:ok, data} -> {:ok, data}
      err -> err
    end
  end

  ################################### Message to server ##############################################################################################
  @doc """
  Dispatch proto message.
  """
  def dispatch(
        %Packet{
          id: id,
          timestamp: timestamp,
          payload: {:entity_action, %Entity.EntityAction{action: {:movement, movement}}}
        },
        %{scene_ref: spid, cid: cid} = state,
        connection
      ) do
    # auth_server = GenServer.call(GateServer.Interface, :auth_server)
    # case GenServer.call({AuthServer.AuthWorker, auth_server.node}, {:login, authrequest}) do
    #   {:ok, agent} ->
    #     GenServer.cast(connection, {:send, "ok"})
    #     {:ok, %{state | agent: agent}}
    #   {:error, :mismatch} ->
    #     GenServer.cast(connection, {:send, "mismatch"})
    #     {:ok,state}
    #   _ -> GenServer.cast(connection, {:send, "server error"})
    #   {:ok,state}
    # end
    %Types.Movement{
      location: %Types.Vector{x: lx, y: ly, z: lz},
      velocity: %Types.Vector{x: vx, y: vy, z: vz},
      acceleration: %Types.Vector{x: ax, y: ay, z: az}
    } = movement

    # Logger.debug("客户端加速度：#{inspect({vx, vy, vz}, pretty: true)}")

    {:ok, _} =
      GenServer.call(spid, {:movement, timestamp, {lx, ly, lz}, {vx, vy, vz}, {ax, ay, az}})

    # Logger.debug("收到位移：#{inspect(movement, pretty: true)}")

    payload =
      {:result,
       %Reply.Result{
         packet_id: id,
         status_code: :ok,
         payload:
           {:player_move,
            %Reply.PlayerMove{cid: cid, location: %Types.Vector{x: lx, y: ly, z: lz}}}
       }}

    # Process.sleep(70)
    GenServer.cast(connection, {:send_data, payload})

    {:ok, state}
  end

  def dispatch(
        %Packet{
          id: id,
          timestamp: timestamp,
          payload: {:entity_action, %Entity.EntityAction{action: {:enter_scene, enter}}}
        },
        state,
        connection
      ) do
    # Logger.debug("玩家请求进入场景")
    {result, new_state} =
      case GenServer.call(
             {SceneServer.PlayerManager, :"scene1@127.0.0.1"},
             {:add_player, enter.cid, connection, timestamp}
           ) do
        {:ok, ppid} ->
          {x, y, z} = GenServer.call(ppid, :get_location)

          result = %Reply.Result{
            packet_id: id,
            status_code: :ok,
            payload:
              {:enter_scene,
               %Reply.EnterScene{
                 location: %Types.Vector{x: x, y: y, z: z}
               }}
          }

          {result, %{state | scene_ref: ppid, cid: enter.cid}}

        _ ->
          result = %Reply.Result{packet_id: id, status_code: :err, payload: nil}
          {result, state}
      end

    payload = {:result, result}

    GenServer.cast(connection, {:send_data, payload})

    {:ok, new_state}
  end

  def dispatch(
        %Packet{id: _id, payload: {:time_sync, _}},
        %{scene_ref: spid} = state,
        connection
      ) do
    {:ok, new_timestamp} = GenServer.call(spid, :time_sync)

    if new_timestamp != :end do
      payload = {:time_sync, %TimeSync{}}
      GenServer.cast(connection, {:send_data, payload})
    end

    {:ok, state}
  end

  ##################################### Message to client ##################################################################################
  @doc """
  Send `player_enter` message to the client

  Params:

  - `cid` - Character ID
  - `location` - Coordinate of the entering player
  - `connection` - Connection process PID
  """
  @spec send_player_enter(integer(), SceneServer.Aoi.AoiItem.vector(), pid()) :: :ok
  def send_player_enter(cid, {x, y, z} = _location, connection) do
    action = %Broadcast.Player.Action{
      action:
        {:player_enter,
         %Broadcast.Player.PlayerEnter{cid: cid, location: %Types.Vector{x: x, y: y, z: z}}}
    }

    payload = {:broadcast_action, action}
    # Logger.info("玩家进入场景：#{cid}")

    GenServer.cast(connection, {:send_data, payload})
  end

  @spec send_player_leave(integer(), pid()) :: :ok
  def send_player_leave(cid, connection) do
    action = %Broadcast.Player.Action{
      action: {:player_leave, %Broadcast.Player.PlayerLeave{cid: cid}}
    }

    payload = {:broadcast_action, action}
    # Logger.info("玩家离开场景：#{cid}")

    GenServer.cast(connection, {:send_data, payload})
  end

  @spec send_player_move(integer(), SceneServer.Aoi.AoiItem.vector(), pid()) ::
          :ok
  def send_player_move(cid, {x, y, z} = _locaiton, connection) do
    action = %Broadcast.Player.Action{
      action:
        {:player_move,
         %Broadcast.Player.PlayerMove{
           cid: cid,
           movement: %Types.Movement{location: %Types.Vector{x: x, y: y, z: z}}
         }}
    }

    payload = {:broadcast_action, action}
    # Logger.info("玩家移动：#{inspect(cid, pretty: true)}")

    GenServer.cast(connection, {:send_data, payload})
  end
end
