defmodule SceneServer.Aoi.AoiItem do
  @moduledoc """
  Per-actor AOI fan-out process.

  Each active actor (player or NPC) gets one `AoiItem` that:

  - owns that actor's current octree placement
  - refreshes nearby subscribers on a timer
  - forwards AOI-visible events (enter/leave/move/skill/combat/state)

  `AoiItem` is intentionally not the authority for movement or combat; it is the
  subscription/broadcast adapter layered on top of authoritative actors. MMO chat
  is owned by `ChatServer.Runtime`; legacy AOI chat casts are rejected with
  observe events instead of becoming a second chat truth.
  """

  use GenServer, restart: :temporary

  require Logger

  # alias SceneServer.Native.CoordinateSystem
  alias SceneServer.Aoi.{PartitionInterest, Priority, RemoteMirrorLedger}
  alias SceneServer.Combat.EffectEvent
  alias SceneServer.Movement.RemoteSnapshot
  alias SceneServer.Native.Octree
  alias SceneServer.Voxel.Types, as: VoxelTypes

  @type vector :: {float(), float(), float()}

  @aoi_tick_interval 1000

  @self __MODULE__

  def start_link(params, opts \\ []) do
    GenServer.start_link(__MODULE__, params, opts)
  end

  @doc """
  Replaces the externally supplied partition window for one AOI item.

  The window must come from the server-authoritative partition context.
  `AoiItem` consumes this DTO and derives its local AOI query plan; it does not
  call World or Gate to compute ownership.
  """
  def update_partition_window(aoi_item, partition_window) when is_pid(aoi_item) do
    GenServer.cast(aoi_item, {:partition_window, partition_window})
  end

  @doc """
  Reads the local item's current location.
  """
  def get_location() do
    GenServer.call(@self, :get_location)
  end

  @impl true
  @spec init(
          {integer(), integer(), vector(), pid(), pid(), %{kind: atom(), name: String.t()}}
        ) ::
          {:ok, map(), {:continue, {:load, any}}}
  def init({cid, _client_timestamp, location, connection_pid, player_pid, actor_meta}) do
    # 八叉树句柄从权威存储 SceneServer.Aoi.Index 取(由 IndexStore 持有 / 跨重启 hydrate)。
    # 不再由 AoiManager 在 add 时把句柄塞进来——那样 AoiManager 重启造新树会让这里持有的
    # 旧句柄孤儿化。现在所有 AoiItem 共享同一棵权威八叉树句柄,IndexStore 重启复用同一
    # 句柄,本进程的 system_ref 永不悬空。
    system = SceneServer.Aoi.Index.octree()

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
       partition_interest: nil,
       partition_routes_by_chunk: %{},
       aoi_timer: nil,
       remote_mirror_requests: []
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
        state
      ) do
    emit_legacy_chat_rejected(:chat_message, from_cid, from_name, text)
    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:chat_say, from_cid, from_name, text},
        state
      ) do
    emit_legacy_chat_rejected(:chat_say, from_cid, from_name, text)
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
    # 热路径:位置写入走 Index 的原子并发 ETS 写,不再同步 GenServer.call 到单点管理者。
    # 八叉树 add/remove 直接落本进程持有的共享句柄(进程无关、可并发)。
    SceneServer.Aoi.Index.update_location(cid, snapshot.position)
    broadcast_action_player_move(snapshot, subscribees)

    {:noreply, %{state | item_ref: item_ref, location: snapshot.position}}
  end

  @impl true
  def handle_cast({:partition_window, nil}, %{cid: cid} = state) do
    SceneServer.CliObserve.emit("aoi_partition_interest_preserved", %{
      cid: cid,
      reason: :nil_partition_window,
      had_partition_interest: not is_nil(state.partition_interest)
    })

    {:noreply, state}
  end

  @impl true
  def handle_cast({:partition_window, partition_window}, %{cid: cid} = state) do
    partition_interest =
      PartitionInterest.plan(%{
        cid: cid,
        local_scene_node: node(),
        partition_window: partition_window
      })

    routes_by_chunk = partition_routes_by_chunk(partition_interest)
    remote_mirror_requests = Map.get(partition_interest, :remote_mirror_requests, [])

    remote_mirror_diff =
      remote_mirror_request_diff(state.remote_mirror_requests, remote_mirror_requests)

    ledger_summary = RemoteMirrorLedger.replace_requests(cid, remote_mirror_requests)

    pruned_subscribees =
      refresh_partition_subscribees(state, partition_interest, routes_by_chunk)

    pruned_pids = subscriber_pids(state.subscribees) -- subscriber_pids(pruned_subscribees)

    if pruned_pids != [] do
      broadcast_action_player_leave(cid, pruned_pids)
    end

    SceneServer.CliObserve.emit("aoi_partition_interest_applied", fn ->
      %{
        cid: cid,
        logical_scene_id: Map.get(partition_interest, :logical_scene_id),
        center_chunk: tuple_to_list(Map.get(partition_interest, :center_chunk)),
        near_query_count: Map.get(partition_interest, :near_query_count, 0),
        halo_query_count: Map.get(partition_interest, :halo_query_count, 0),
        skipped_count: Map.get(partition_interest, :skipped_count, 0),
        missing_count: Map.get(partition_interest, :missing_count, 0),
        unleased_count: Map.get(partition_interest, :unleased_count, 0),
        remote_mirror_request_count: length(remote_mirror_requests),
        remote_mirror_requests: remote_mirror_request_summaries(remote_mirror_requests),
        remote_mirror_ledger: ledger_summary_for_log(ledger_summary),
        remote_owner_query_count: remote_owner_query_count(partition_interest),
        pruned_subscriber_count: length(pruned_pids)
      }
    end)

    SceneServer.CliObserve.emit("aoi_remote_mirror_requests_updated", fn ->
      %{
        cid: cid,
        logical_scene_id: Map.get(partition_interest, :logical_scene_id),
        center_chunk: tuple_to_list(Map.get(partition_interest, :center_chunk)),
        remote_mirror_request_count: length(remote_mirror_requests),
        added_count: remote_mirror_diff.added_count,
        removed_count: remote_mirror_diff.removed_count,
        retained_count: remote_mirror_diff.retained_count,
        ledger: ledger_summary_for_log(ledger_summary),
        requests: remote_mirror_request_summaries(remote_mirror_requests)
      }
    end)

    {:noreply,
     %{
       state
       | partition_interest: partition_interest,
         partition_routes_by_chunk: routes_by_chunk,
         remote_mirror_requests: remote_mirror_requests,
         subscribees: pruned_subscribees
     }}
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
          actor_name: actor_name,
          partition_interest: partition_interest,
          partition_routes_by_chunk: partition_routes_by_chunk
        } = state
      ) do
    # aoi_pids = get_aoi_pids(system, item, 50000.0)
    aoi_targets =
      refresh_aoi_players(
        system,
        item,
        cid,
        location,
        interest_radius,
        subscribees,
        actor_kind,
        actor_name,
        partition_interest,
        partition_routes_by_chunk
      )

    # Logger.debug("Coordinate System: #{inspect(CoordinateSystem.get_system_raw(system), pretty: true)}", ansi_color: :yellow)
    # Logger.debug("Coordinate System: #{inspect(cids, pretty: true)}", ansi_color: :yellow)

    {:noreply, %{state | aoi_timer: make_aoi_timer(), subscribees: aoi_targets}}
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

    {:ok, _} = SceneServer.AoiManager.remove_aoi_item(cid)
    Logger.debug("Aoi index removed.")

    if aoi_timer != nil do
      Process.cancel_timer(aoi_timer)
      Logger.debug("Timer canceled.")
    end

    RemoteMirrorLedger.clear_requests(cid)

    log_termination(reason)
  end

  ################ Private Functions #######################################################################

  defp log_termination(reason) when reason in [:normal, :shutdown] do
    Logger.debug(
      "AoiItem process #{inspect(self(), pretty: true)} exited normally. Reason: #{inspect(reason, pretty: true)}"
    )
  end

  defp log_termination(reason) do
    Logger.warning(
      "AoiItem process #{inspect(self(), pretty: true)} exited unexpectedly. Reason: #{inspect(reason, pretty: true)}"
    )
  end

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
          [Priority.target()],
          atom(),
          String.t(),
          map() | nil,
          map()
        ) :: [Priority.target()]
  defp refresh_aoi_players(
         system,
         item,
         cid,
         location,
         interest_radius,
         subscribees,
         actor_kind,
         actor_name,
         partition_interest,
         partition_routes_by_chunk
       ) do
    aoi_targets =
      get_aoi_targets(
        system,
        item,
        location,
        interest_radius,
        partition_interest,
        partition_routes_by_chunk
      )

    old_pids = subscriber_pids(subscribees)
    new_pids = subscriber_pids(aoi_targets)
    leave_pids = old_pids -- new_pids
    enter_pids = new_pids -- old_pids
    partition_counts = partition_target_counts(aoi_targets, partition_interest)

    # Logger.debug("旧玩家列表：#{inspect(subscribees, pretty: true)}，新玩家列表：#{inspect(aoi_pids, pretty: true)}")

    if leave_pids != [] do
      broadcast_action_player_leave(cid, leave_pids)
    end

    if enter_pids != [] do
      broadcast_action_player_enter(cid, location, actor_kind, actor_name, enter_pids)
    end

    SceneServer.CliObserve.emit("aoi_refresh", %{
      cid: cid,
      subscriber_count: length(aoi_targets),
      enter_count: length(enter_pids),
      leave_count: length(leave_pids),
      high_priority: count_band(aoi_targets, :high),
      medium_priority: count_band(aoi_targets, :medium),
      low_priority: count_band(aoi_targets, :low),
      partition_near_count: partition_counts.near,
      partition_halo_count: partition_counts.halo,
      partition_skipped_count: partition_counts.skipped,
      partition_remote_owner_skipped_count: partition_counts.remote_owner_skipped
    })

    aoi_targets
  end

  @spec get_aoi_targets(
          Octree.Types.octree(),
          Octree.Types.octree_item(),
          vector(),
          float(),
          map() | nil,
          map()
        ) :: [Priority.target()]
  defp get_aoi_targets(
         system,
         item,
         location,
         distance,
         partition_interest,
         partition_routes_by_chunk
       ) do
    cids = Octree.get_in_bound_except(system, item, {distance, distance, distance})
    # AOI tick 热读路径:直接走 Index 的 ETS 读,不经任何单点同步 call。
    cids
    |> SceneServer.Aoi.Index.fetch_entries()
    |> Priority.build_targets(location, distance)
    |> apply_partition_interest(partition_interest, partition_routes_by_chunk)
  end

  # defp broadcast_action_movement(movement, pids) do
  # end

  @spec broadcast_action_player_leave(integer(), [pid() | Priority.target()]) :: :ok
  defp broadcast_action_player_leave(cid, subscribers) do
    subscribers
    |> subscriber_pids()
    |> Enum.each(&GenServer.cast(&1, {:player_leave, cid}))
  end

  @spec broadcast_action_player_enter(integer(), vector(), atom(), String.t(), [
          pid() | Priority.target()
        ]) :: :ok
  defp broadcast_action_player_enter(cid, location, actor_kind, actor_name, subscribers) do
    subscribers
    |> subscriber_pids()
    |> Enum.each(fn pid ->
      GenServer.cast(pid, {:player_enter, cid, location})
      GenServer.cast(pid, {:actor_identity, cid, actor_kind, actor_name})
    end)
  end

  @spec broadcast_action_player_move(RemoteSnapshot.t(), [pid() | Priority.target()]) :: :ok
  defp broadcast_action_player_move(%RemoteSnapshot{} = snapshot, subscribers) do
    {sent, skipped, bands, partition_sent} =
      Enum.reduce(subscribers, {0, 0, %{}, %{}}, fn subscriber,
                                                    {sent, skipped, bands, partition_sent} ->
        case priority_delivery(snapshot, subscriber) do
          {:send, pid, decorated, band} ->
            GenServer.cast(pid, {:player_move, decorated})
            partition_tier = Map.get(subscriber, :partition_tier, :none)

            {sent + 1, skipped, Map.update(bands, band, 1, &(&1 + 1)),
             Map.update(partition_sent, partition_tier, 1, &(&1 + 1))}

          :skip ->
            {sent, skipped + 1, bands, partition_sent}
        end
      end)

    if sent > 0 or skipped > 0 do
      SceneServer.CliObserve.emit("aoi_priority_snapshot", %{
        cid: snapshot.cid,
        server_tick: snapshot.server_tick,
        sent: sent,
        skipped: skipped,
        high_priority: Map.get(bands, :high, 0),
        medium_priority: Map.get(bands, :medium, 0),
        low_priority: Map.get(bands, :low, 0),
        partition_near_sent: Map.get(partition_sent, :near, 0),
        partition_halo_sent: Map.get(partition_sent, :halo, 0)
      })
    end

    :ok
  end

  @spec broadcast_action_skill_event(integer(), integer(), vector(), [
          pid() | Priority.target()
        ]) :: any()
  defp broadcast_action_skill_event(cid, skill_id, location, subscribers) do
    subscribers
    |> subscriber_pids()
    |> Task.async_stream(
      fn pid -> GenServer.cast(pid, {:skill_event, cid, skill_id, location}) end,
      timeout: :infinity
    )
    |> Enum.to_list()
  end

  defp emit_legacy_chat_rejected(kind, cid, from_name, text) do
    SceneServer.CliObserve.emit("aoi_chat_legacy_rejected", %{
      kind: kind,
      cid: cid,
      username: from_name,
      text: text,
      reason: :chat_runtime_required
    })
  end

  @spec broadcast_action_player_state(
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          [pid() | Priority.target()]
        ) :: any()
  defp broadcast_action_player_state(cid, hp, max_hp, alive, subscribers) do
    subscribers
    |> subscriber_pids()
    |> Task.async_stream(
      fn pid -> GenServer.cast(pid, {:player_state, cid, hp, max_hp, alive}) end,
      timeout: :infinity
    )
    |> Enum.to_list()
  end

  @spec broadcast_action_combat_hit(
          integer(),
          integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          vector(),
          [pid() | Priority.target()]
        ) :: any()
  defp broadcast_action_combat_hit(
         source_cid,
         target_cid,
         skill_id,
         damage,
         hp_after,
         location,
         subscribers
       ) do
    subscribers
    |> subscriber_pids()
    |> Task.async_stream(
      fn pid ->
        GenServer.cast(
          pid,
          {:combat_hit, source_cid, target_cid, skill_id, damage, hp_after, location}
        )
      end,
      timeout: :infinity
    )
    |> Enum.to_list()
  end

  @spec broadcast_action_effect_event(EffectEvent.t(), [pid() | Priority.target()]) :: any()
  defp broadcast_action_effect_event(%EffectEvent{} = effect_event, subscribers) do
    subscribers
    |> subscriber_pids()
    |> Enum.uniq()
    |> Task.async_stream(fn pid -> GenServer.cast(pid, {:effect_cue, effect_event}) end,
      timeout: :infinity
    )
    |> Enum.to_list()
  end

  defp priority_delivery(%RemoteSnapshot{} = snapshot, %{aoi_pid: pid} = target) do
    if Priority.due?(snapshot, target) do
      {:send, pid, Priority.decorate_snapshot(snapshot, target), target.priority_band}
    else
      :skip
    end
  end

  defp priority_delivery(%RemoteSnapshot{} = snapshot, pid) when is_pid(pid) do
    {:send, pid, snapshot, :legacy}
  end

  defp apply_partition_interest(_targets, nil, _routes_by_chunk), do: []

  defp apply_partition_interest(targets, partition_interest, routes_by_chunk)
       when is_map(partition_interest) and is_map(routes_by_chunk) do
    targets
    |> Enum.flat_map(fn target ->
      chunk_coord = VoxelTypes.chunk_from_world_cm!(target.location)

      case Map.get(routes_by_chunk, chunk_coord) do
        nil -> []
        query -> [merge_partition_query(target, query)]
      end
    end)
  end

  defp refresh_partition_subscribees(
         %{subscribees: subscribees, location: location, interest_radius: interest_radius},
         partition_interest,
         routes_by_chunk
       ) do
    subscribees
    |> Enum.map(&Map.get(&1, :cid))
    |> Enum.reject(&is_nil/1)
    |> SceneServer.Aoi.Index.fetch_entries()
    |> Priority.build_targets(location, interest_radius)
    |> apply_partition_interest(partition_interest, routes_by_chunk)
  end

  defp merge_partition_query(target, query) do
    %{
      target
      | priority_band: query.priority_band,
        delivery_interval: query.delivery_interval
    }
    |> Map.merge(%{
      partition_tier: query.tier,
      partition_region_id: query.region_id,
      partition_lease_id: query.lease_id,
      partition_assigned_scene_node: query.assigned_scene_node,
      partition_query_scope: query.query_scope
    })
  end

  defp partition_target_counts(_targets, nil) do
    %{near: 0, halo: 0, skipped: 0, remote_owner_skipped: 0}
  end

  defp partition_target_counts(targets, partition_interest) do
    %{
      near: Enum.count(targets, &(&1[:partition_tier] == :near)),
      halo: Enum.count(targets, &(&1[:partition_tier] == :halo)),
      skipped: Map.get(partition_interest, :skipped_count, 0),
      remote_owner_skipped: remote_owner_query_count(partition_interest)
    }
  end

  defp partition_routes_by_chunk(partition_interest) do
    partition_interest
    |> Map.get(:query_entries, [])
    |> Enum.filter(&local_owner?/1)
    |> Map.new(fn entry -> {Map.fetch!(entry, :chunk_coord), entry} end)
  end

  defp remote_mirror_request_summaries(remote_mirror_requests) do
    Enum.map(remote_mirror_requests, fn request ->
      %{
        cid: request.cid,
        logical_scene_id: request.logical_scene_id,
        center_chunk: tuple_to_list(request.center_chunk),
        requester_scene_node: request.requester_scene_node,
        owner_scene_node: request.owner_scene_node,
        chunk_coord: tuple_to_list(request.chunk_coord),
        tier: request.tier,
        region_id: request.region_id,
        lease_id: request.lease_id,
        assigned_scene_node: request.assigned_scene_node,
        query_scope: request.query_scope,
        priority_band: request.priority_band,
        delivery_interval: request.delivery_interval,
        request_mode: request.request_mode,
        request_key: request_key_summary(request.request_key),
        status: request.status,
        reason: request.reason
      }
    end)
  end

  defp request_key_summary({owner_scene_node, lease_id, chunk_coord}) do
    %{
      owner_scene_node: owner_scene_node,
      lease_id: lease_id,
      chunk_coord: tuple_to_list(chunk_coord)
    }
  end

  defp ledger_summary_for_log({:error, reason}), do: %{status: :unavailable, reason: reason}

  defp ledger_summary_for_log(summary) when is_map(summary) do
    Map.put(summary, :status, :updated)
  end

  defp remote_mirror_request_diff(previous_requests, next_requests) do
    previous_keys = previous_requests |> Enum.map(& &1.request_key) |> MapSet.new()
    next_keys = next_requests |> Enum.map(& &1.request_key) |> MapSet.new()

    %{
      added_count: MapSet.size(MapSet.difference(next_keys, previous_keys)),
      removed_count: MapSet.size(MapSet.difference(previous_keys, next_keys)),
      retained_count: MapSet.size(MapSet.intersection(previous_keys, next_keys))
    }
  end

  defp remote_owner_query_count(partition_interest) do
    partition_interest
    |> Map.get(:query_entries, [])
    |> Enum.count(&(not local_owner?(&1)))
  end

  defp local_owner?(%{assigned_scene_node: assigned_scene_node}),
    do: assigned_scene_node == node()

  defp local_owner?(_entry), do: false

  defp subscriber_pids(subscribers) do
    subscribers
    |> Enum.map(&subscriber_pid/1)
    |> Enum.reject(&is_nil/1)
  end

  defp subscriber_pid(%{aoi_pid: pid}) when is_pid(pid), do: pid
  defp subscriber_pid(pid) when is_pid(pid), do: pid
  defp subscriber_pid(_subscriber), do: nil

  defp count_band(targets, band) do
    Enum.count(targets, fn
      %{priority_band: ^band} -> true
      _target -> false
    end)
  end

  defp tuple_to_list({x, y, z}), do: [x, y, z]
  defp tuple_to_list(value), do: value
end
