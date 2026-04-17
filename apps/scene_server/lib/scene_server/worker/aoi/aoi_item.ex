defmodule SceneServer.Aoi.AoiItem do
  @moduledoc """
  Per-actor AOI fan-out process.

  Each active actor (player or NPC) gets one `AoiItem` that:

  - owns that actor's current octree placement
  - refreshes nearby subscribers on a timer
  - forwards AOI-visible events (enter/leave/move/chat/skill/combat/state)

  `AoiItem` is intentionally not the authority for movement or combat; it is the
  subscription/broadcast adapter layered on top of authoritative actors.
  """

  use GenServer, restart: :temporary

  require Logger

  # alias SceneServer.Native.CoordinateSystem
  alias SceneServer.Combat.EffectEvent
  alias SceneServer.Movement.RemoteSnapshot
  alias SceneServer.Native.Octree

  @type vector :: {float(), float(), float()}

  @aoi_tick_interval 1000

  @self __MODULE__

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @doc """
  Reads the local item's current location.
  """
  def get_location() do
    GenServer.call(@self, :get_location)
  end

  @impl true
  @spec init(
          {integer(), integer(), vector(), pid(), pid(), %{kind: atom(), name: String.t()},
           Octree.Types.octree()}
        ) ::
          {:ok, map(), {:continue, {:load, any}}}
  def init({cid, _client_timestamp, location, connection_pid, player_pid, actor_meta, system}) do
    {:ok,
     %{
       cid: cid,
       player_pid: player_pid,
       connection_pid: connection_pid,
       actor_kind: Map.get(actor_meta, :kind, :player),
       actor_name: Map.get(actor_meta, :name, "actor-#{cid}"),
       system_ref: system,
       item_ref: nil,
       location: location,
       subscribees: [],
       interest_radius: 500,
       aoi_timer: nil
     }, {:continue, {:load, location}}}
  end

  @impl true
  def handle_continue({:load, location}, %{cid: cid, system_ref: system} = state) do
    Logger.debug("aoi_item continue load")
    {:ok, item_ref} = add_item(cid, location, system)
    Logger.debug("Item added to the system.")

    aoi_timer = make_aoi_timer()
    # coord_timer = make_coord_timer()

    # {:noreply, %{state | item_ref: item_ref, aoi_timer: aoi_timer, coord_timer: coord_timer}}
    {:noreply, %{state | item_ref: item_ref, aoi_timer: aoi_timer}}
  end

  # @impl true
  # def handle_cast(
  #       {:movement, timestamp, location, velocity, acceleration},
  #       state
  #     ) do
  #   # Logger.debug("AOI movement")
  #   new_state = update_movement(timestamp, location, velocity, acceleration, state)

  #   {:noreply, new_state}
  # end

  @impl true
  def handle_cast({:player_enter, cid, location}, %{connection_pid: connection_pid} = state) do
    Logger.debug("player_enter")
    GenServer.cast(connection_pid, {:player_enter, cid, location})

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:actor_identity, cid, actor_kind, actor_name},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:actor_identity, cid, actor_kind, actor_name})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:player_leave, cid}, %{connection_pid: connection_pid} = state) do
    GenServer.cast(connection_pid, {:player_leave, cid})

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:player_move, %RemoteSnapshot{} = snapshot},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:player_move, snapshot})

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:chat_message, from_cid, from_name, text},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:chat_message, from_cid, from_name, text})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:chat_say, from_cid, from_name, text},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:chat_message, from_cid, from_name, text})
    broadcast_action_chat_message(from_cid, from_name, text, state.subscribees)
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:skill_event, from_cid, skill_id, location},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:skill_event, from_cid, skill_id, location})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:effect_event, %EffectEvent{} = effect_event},
        %{connection_pid: connection_pid, subscribees: subscribees} = state
      ) do
    GenServer.cast(connection_pid, {:effect_event, effect_event})
    broadcast_action_effect_event(effect_event, subscribees)
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:effect_cue, %EffectEvent{} = effect_event},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:effect_event, effect_event})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:skill_cast, from_cid, skill_id, location},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:skill_event, from_cid, skill_id, location})
    broadcast_action_skill_event(from_cid, skill_id, location, state.subscribees)
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:player_state, cid, hp, max_hp, alive},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(connection_pid, {:player_state, cid, hp, max_hp, alive})
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:health_update, cid, hp, max_hp, alive},
        %{connection_pid: connection_pid, subscribees: subscribees} = state
      ) do
    GenServer.cast(connection_pid, {:player_state, cid, hp, max_hp, alive})
    broadcast_action_player_state(cid, hp, max_hp, alive, subscribees)
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location},
        %{connection_pid: connection_pid} = state
      ) do
    GenServer.cast(
      connection_pid,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:combat_resolved, source_cid, target_cid, skill_id, damage, hp_after, location},
        %{connection_pid: connection_pid, subscribees: subscribees} = state
      ) do
    GenServer.cast(
      connection_pid,
      {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
    )

    broadcast_action_combat_hit(
      source_cid,
      target_cid,
      skill_id,
      damage,
      hp_after,
      location,
      subscribees
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:self_move, %RemoteSnapshot{} = snapshot},
        %{
          cid: cid,
          system_ref: system,
          item_ref: item,
          subscribees: subscribees
        } = state
      ) do
    {:ok, item_ref} = replace_item(cid, snapshot.position, system, item)
    broadcast_action_player_move(snapshot, subscribees)

    {:noreply, %{state | item_ref: item_ref, location: snapshot.position}}
  end

  # @impl true
  # def handle_call(:get_location, _from, %{movement: movement} = state) do
  #   {:reply, movement.location, state}
  # end

  @impl true
  def handle_call(:exit, _from, state) do
    {:stop, :normal, {:ok, ""}, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({_, :ok}, state) do
    {:noreply, state}
  end

  ############### Tick Functions ##############################################################################

  @impl true
  def handle_info(
        :get_aoi_tick,
        %{
          cid: cid,
          interest_radius: interest_radius,
          location: location,
          system_ref: system,
          item_ref: item,
          subscribees: subscribees,
          actor_kind: actor_kind,
          actor_name: actor_name
        } = state
      ) do
    # aoi_pids = get_aoi_pids(system, item, 50000.0)
    aoi_pids =
      refresh_aoi_players(
        system,
        item,
        cid,
        location,
        interest_radius,
        subscribees,
        actor_kind,
        actor_name
      )

    # Logger.debug("Coordinate System: #{inspect(CoordinateSystem.get_system_raw(system), pretty: true)}", ansi_color: :yellow)
    # Logger.debug("Coordinate System: #{inspect(cids, pretty: true)}", ansi_color: :yellow)

    {:noreply, %{state | aoi_timer: make_aoi_timer(), subscribees: aoi_pids}}
    # {:noreply, state}
  end

  # @impl true
  # def handle_info(
  #       :update_coord_tick,
  #       %{
  #         cid: cid,
  #         system_ref: system,
  #         item_ref: item,
  #         movement: movement,
  #         subscribees: subscribees
  #       } = state
  #     ) do
  #   new_location =
  #     update_location(
  #       system,
  #       item,
  #       movement.server_timestamp,
  #       movement.location,
  #       movement.velocity
  #     )
  #   # Logger.debug("Location update: #{inspect(new_location, pretty: true)}")

  #   if new_location != movement.location and subscribees != [] do
  #     broadcast_action_player_move(cid, new_location, subscribees)
  #   end

  #   {:noreply,
  #    %{
  #      state
  #      | coord_timer: make_coord_timer(),
  #        movement: %{
  #          movement
  #          | location: new_location,
  #            server_timestamp: :os.system_time(:millisecond)
  #        }
  #    }}
  # end

  @impl true
  def terminate(reason, %{
        cid: cid,
        system_ref: system,
        item_ref: item,
        aoi_timer: aoi_timer
      }) do
    # {:ok, _} = CoordinateSystem.remove_item_from_system(system, item)
    case Octree.remove_item(system, item) do
      true -> Logger.debug("AOI system item removed.")
      false -> Logger.debug("AOI system item already absent during terminate.")
    end

    {:ok, _} = GenServer.call(SceneServer.AoiManager, {:remove_aoi_item, cid})
    Logger.debug("Aoi index removed.")

    if aoi_timer != nil do
      Process.cancel_timer(aoi_timer)
      Logger.debug("Timer canceled.")
    end

    Logger.warning(
      "AoiItem process #{inspect(self(), pretty: true)} exited successfully. Reason: #{inspect(reason, pretty: true)}",
      ansi_color: :green
    )
  end

  ################ Private Functions #######################################################################

  defp add_item(cid, location, system) do
    # {:ok, item_ref} = CoordinateSystem.add_item_to_system(system, cid, location)
    item_ref = Octree.new_item(cid, location)
    Octree.add_item(system, item_ref)

    {:ok, item_ref}
  end

  defp replace_item(cid, location, system, item) do
    if item != nil do
      true = Octree.remove_item(system, item)
    end

    add_item(cid, location, system)
  end

  defp make_aoi_timer() do
    Process.send_after(self(), :get_aoi_tick, @aoi_tick_interval)
  end

  # defp make_coord_timer() do
  #   Process.send_after(self(), :update_coord_tick, @coord_tick_interval)
  # end

  # Handle `:movement` casts
  # @spec update_movement(integer(), vector(), vector(), vector(), map()) :: map()
  # defp update_movement(
  #        timestamp,
  #        location,
  #        velocity,
  #        acceleration,
  #        %{system_ref: system, item_ref: item} = state
  #      ) do
  #   {:ok, _} = CoordinateSystem.update_item_from_system(system, item, location)

  #   %{
  #     state
  #     | movement: %{
  #         client_timestamp: timestamp,
  #         server_timestamp: :os.system_time(:millisecond),
  #         location: location,
  #         velocity: velocity,
  #         acceleration: acceleration
  #       }
  #   }
  # end

  # @spec update_location(
  #         CoordinateSystem.Types.coordinate_system(),
  #         CoordinateSystem.Types.item(),
  #         integer(),
  #         vector(),
  #         vector()
  #       ) :: vector()
  # defp update_location(system, item, server_timestamp, location, velocity) do
  #   new_location =
  #     if velocity != {0.0, 0.0, 0.0} do
  #       # Logger.debug("Coord tick.", ansi_color: :yellow)
  #       new_location =
  #         CoordinateSystem.calculate_coordinate(
  #           server_timestamp,
  #           :os.system_time(:millisecond),
  #           location,
  #           velocity
  #         )

  #       CoordinateSystem.update_item_from_system(system, item, new_location)
  #       new_location
  #     else
  #       location
  #     end

  #   new_location
  # end

  @spec refresh_aoi_players(
          Octree.Types.octree(),
          Octree.Types.octree_item(),
          integer(),
          vector(),
          float(),
          [pid()],
          atom(),
          String.t()
        ) :: no_return()
  defp refresh_aoi_players(
         system,
         item,
         cid,
         location,
         interest_radius,
         subscribees,
         actor_kind,
         actor_name
       ) do
    aoi_pids = get_aoi_players(system, item, interest_radius)
    leave_pids = subscribees -- aoi_pids
    enter_pids = aoi_pids -- subscribees

    # Logger.debug("旧玩家列表：#{inspect(subscribees, pretty: true)}，新玩家列表：#{inspect(aoi_pids, pretty: true)}")

    if leave_pids != [] do
      broadcast_action_player_leave(cid, leave_pids)
    end

    if enter_pids != [] do
      broadcast_action_player_enter(cid, location, actor_kind, actor_name, enter_pids)
    end

    aoi_pids
  end

  @spec get_aoi_players(
          Octree.Types.octree(),
          Octree.Types.octree_item(),
          float()
        ) :: [pid()]
  defp get_aoi_players(system, item, distance) do
    cids = Octree.get_in_bound_except(system, item, {distance, distance, distance})
    # {:ok, cids} = CoordinateSystem.get_cids_within_distance_from_system(system, item, distance)
    # data = CoordinateSystem.get_item_raw(item)
    # Logger.debug("#{inspect(data, pretty: true)}")
    aoi_pids = SceneServer.AoiManager.get_items_with_cids(cids)

    aoi_pids
  end

  # defp broadcast_action_movement(movement, pids) do
  # end

  @spec broadcast_action_player_leave(integer(), [pid()]) :: any()
  defp broadcast_action_player_leave(cid, pids) do
    # Logger.debug("待广播离开玩家：#{inspect(pids, pretty: true)}")
    pids
    |> Enum.map(&Task.async(fn -> GenServer.cast(&1, {:player_leave, cid}) end))
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_player_enter(integer(), vector(), atom(), String.t(), [pid()]) :: any()
  defp broadcast_action_player_enter(cid, location, actor_kind, actor_name, pids) do
    # Logger.debug("待广播加入玩家：#{inspect(pids, pretty: true)}")
    pids
    |> Enum.map(
      &Task.async(fn ->
        GenServer.cast(&1, {:player_enter, cid, location})
        GenServer.cast(&1, {:actor_identity, cid, actor_kind, actor_name})
      end)
    )
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_player_move(RemoteSnapshot.t(), [pid()]) :: any()
  defp broadcast_action_player_move(%RemoteSnapshot{} = snapshot, pids) do
    # Logger.debug("待广播移动玩家：#{inspect(pids, pretty: true)}")
    pids
    |> Enum.map(&Task.async(fn -> GenServer.cast(&1, {:player_move, snapshot}) end))
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_chat_message(integer(), binary(), binary(), [pid()]) :: any()
  defp broadcast_action_chat_message(cid, from_name, text, pids) do
    pids
    |> Enum.map(&Task.async(fn -> GenServer.cast(&1, {:chat_message, cid, from_name, text}) end))
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_skill_event(integer(), integer(), vector(), [pid()]) :: any()
  defp broadcast_action_skill_event(cid, skill_id, location, pids) do
    pids
    |> Enum.map(
      &Task.async(fn -> GenServer.cast(&1, {:skill_event, cid, skill_id, location}) end)
    )
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_player_state(
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          [pid()]
        ) :: any()
  defp broadcast_action_player_state(cid, hp, max_hp, alive, pids) do
    pids
    |> Enum.map(
      &Task.async(fn -> GenServer.cast(&1, {:player_state, cid, hp, max_hp, alive}) end)
    )
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_combat_hit(
          integer(),
          integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          vector(),
          [pid()]
        ) :: any()
  defp broadcast_action_combat_hit(
         source_cid,
         target_cid,
         skill_id,
         damage,
         hp_after,
         location,
         pids
       ) do
    pids
    |> Enum.map(
      &Task.async(fn ->
        GenServer.cast(
          &1,
          {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
        )
      end)
    )
    |> Enum.map(&Task.await(&1))
  end

  @spec broadcast_action_effect_event(EffectEvent.t(), [pid()]) :: any()
  defp broadcast_action_effect_event(%EffectEvent{} = effect_event, pids) do
    pids
    |> Enum.uniq()
    |> Enum.map(
      &Task.async(fn ->
        GenServer.cast(&1, {:effect_cue, effect_event})
      end)
    )
    |> Enum.map(&Task.await(&1))
  end
end
