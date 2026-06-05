defmodule SceneServer.AoiItemTest do
  use ExUnit.Case, async: false

  alias SceneServer.AoiManager
  alias SceneServer.CliObserve
  alias SceneServer.Movement.RemoteSnapshot

  setup do
    ensure_started(
      SceneServer.Aoi.RemoteMirrorLedger,
      {SceneServer.Aoi.RemoteMirrorLedger, name: SceneServer.Aoi.RemoteMirrorLedger}
    )

    SceneServer.Aoi.RemoteMirrorLedger.reset()
    SceneServer.TestAoiRuntime.ensure_started!()
    :ok
  end

  test "players outside the interest radius are not included in AOI" do
    cid = unique_cid()
    other_cid = unique_cid()

    observer = add_aoi_item(cid, {0.0, 0.0, 0.0}, self())
    other = add_aoi_item(other_cid, {800.0, 0.0, 0.0}, spawn_connection())

    on_exit(fn ->
      exit_aoi_item(observer)
      exit_aoi_item(other)
    end)

    apply_partition_window(other, [local_route({0, 0, 0})])
    send(other, :get_aoi_tick)

    refute_receive {:"$gen_cast", {:player_enter, ^other_cid, _location}}, 150
  end

  test "AOI tick before an authoritative partition window does not fan out local actors" do
    mover_cid = unique_cid()
    observer_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    observer = add_aoi_item(observer_cid, {100.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(observer)
    end)

    send(mover, :get_aoi_tick)

    refute_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 150
    assert :sys.get_state(mover).subscribees == []
  end

  test "self_move updates octree placement and AOI visibility" do
    cid = unique_cid()
    other_cid = unique_cid()

    observer = add_aoi_item(cid, {0.0, 0.0, 0.0}, self())
    mover = add_aoi_item(other_cid, {800.0, 0.0, 0.0}, spawn_connection())

    on_exit(fn ->
      exit_aoi_item(observer)
      exit_aoi_item(mover)
    end)

    apply_partition_window(mover, [local_route({0, 0, 0})])
    send(mover, :get_aoi_tick)
    refute_receive {:"$gen_cast", {:player_enter, ^other_cid, _location}}, 150

    initial_item_ref = :sys.get_state(mover).item_ref

    GenServer.cast(
      mover,
      {:self_move,
       %RemoteSnapshot{
         cid: other_cid,
         server_tick: 1,
         position: {100.0, 0.0, 0.0},
         velocity: {0.0, 0.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.location == {100.0, 0.0, 0.0} and state.item_ref != initial_item_ref
    end)

    send(mover, :get_aoi_tick)

    assert_receive {:"$gen_cast", {:player_enter, ^other_cid, enter_location}}, 300
    assert enter_location == {100.0, 0.0, 0.0}
    assert_receive {:"$gen_cast", {:actor_identity, ^other_cid, :player, _name}}, 300

    GenServer.cast(
      mover,
      {:self_move,
       %RemoteSnapshot{
         cid: other_cid,
         server_tick: 2,
         position: {900.0, 0.0, 0.0},
         velocity: {0.0, 0.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.location == {900.0, 0.0, 0.0}
    end)

    send(mover, :get_aoi_tick)
    assert_receive {:"$gen_cast", {:player_leave, ^other_cid}}, 300
  end

  test "movement snapshots are decorated and throttled by AOI priority" do
    mover_cid = unique_cid()
    high_cid = unique_cid()
    low_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    high_observer = add_aoi_item(high_cid, {50.0, 0.0, 0.0}, self())
    low_observer = add_aoi_item(low_cid, {1_650.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(high_observer)
      exit_aoi_item(low_observer)
    end)

    :sys.replace_state(mover, fn state -> %{state | interest_radius: 3_500} end)

    apply_partition_window(mover, [
      local_route({0, 0, 0}),
      local_route({1, 0, 0}, tier: :halo, region_id: 20, lease_id: 200)
    ])

    send(mover, :get_aoi_tick)
    assert_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 300
    assert_receive {:"$gen_cast", {:actor_identity, ^mover_cid, :player, _name}}, 300
    assert_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 300
    assert_receive {:"$gen_cast", {:actor_identity, ^mover_cid, :player, _name}}, 300

    GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 1)})

    assert_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{} = high_snapshot}}, 300
    assert high_snapshot.priority_band == :high
    assert high_snapshot.delivery_interval == 1
    refute_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{priority_band: :low}}}, 150

    GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 5)})

    delivered =
      2
      |> collect_player_moves(300)
      |> Enum.map(& &1.priority_band)
      |> Enum.sort()

    assert delivered == [:high, :low]
  end

  test "legacy AOI chat path is rejected and does not fan out to subscribers" do
    observe_log = Path.join(System.tmp_dir!(), "aoi-chat-legacy-#{unique_cid()}.log")
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.put_env(:scene_server, :cli_observe_log, observe_log)
    File.rm(observe_log)

    mover_cid = unique_cid()
    observer_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    observer = add_aoi_item(observer_cid, {100.0, 0.0, 0.0}, self())

    try do
      apply_partition_window(mover, [local_route({0, 0, 0})])
      send(mover, :get_aoi_tick)

      wait_until(fn ->
        targets = :sys.get_state(mover).subscribees
        Enum.map(targets, & &1.cid) == [observer_cid]
      end)

      GenServer.cast(mover, {:chat_say, mover_cid, "mover", "legacy aoi chat"})
      refute_receive {:"$gen_cast", {:chat_message, ^mover_cid, "mover", "legacy aoi chat"}}, 150

      GenServer.cast(mover, {:chat_message, mover_cid, "mover", "legacy direct chat"})

      refute_receive {:"$gen_cast", {:chat_message, ^mover_cid, "mover", "legacy direct chat"}},
                     150

      CliObserve.flush()
      log = File.read!(observe_log)
      assert log =~ ~s(event="aoi_chat_legacy_rejected")
      assert log =~ "chat_runtime_required"
    after
      exit_aoi_item(mover)
      exit_aoi_item(observer)
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end

  test "partition interest plan constrains live AOI targets and exposes partition logs" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "aoi-item-partition-interest-#{System.unique_integer([:positive])}.log"
      )

    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.put_env(:scene_server, :cli_observe_log, observe_log)
    File.rm(observe_log)

    mover_cid = unique_cid()
    near_cid = unique_cid()
    halo_cid = unique_cid()
    outside_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    near_observer = add_aoi_item(near_cid, {100.0, 0.0, 0.0}, self())
    halo_observer = add_aoi_item(halo_cid, {1_650.0, 0.0, 0.0}, self())
    outside_observer = add_aoi_item(outside_cid, {3_200.0, 0.0, 0.0}, self())

    try do
      :sys.replace_state(mover, fn state -> %{state | interest_radius: 3_500} end)

      partition_window = %{
        logical_scene_id: 7,
        center_chunk: {0, 0, 0},
        near_radius: 0,
        halo_radius: 1,
        route_entries: [
          %{
            chunk_coord: {0, 0, 0},
            tier: :near,
            status: :assigned,
            region_id: 10,
            lease_id: 100,
            assigned_scene_node: node()
          },
          %{
            chunk_coord: {1, 0, 0},
            tier: :halo,
            status: :assigned,
            region_id: 20,
            lease_id: 200,
            assigned_scene_node: node()
          }
        ]
      }

      SceneServer.Aoi.AoiItem.update_partition_window(mover, partition_window)
      send(mover, :get_aoi_tick)

      expected_partition_cids = Enum.sort([halo_cid, near_cid])

      wait_until(fn ->
        targets = :sys.get_state(mover).subscribees
        Enum.map(targets, & &1.cid) |> Enum.sort() == expected_partition_cids
      end)

      targets = :sys.get_state(mover).subscribees
      near_target = Enum.find(targets, &(&1.cid == near_cid))
      halo_target = Enum.find(targets, &(&1.cid == halo_cid))

      assert near_target.partition_tier == :near
      assert near_target.partition_query_scope == :authoritative
      assert near_target.priority_band == :high
      assert near_target.delivery_interval == 1

      assert halo_target.partition_tier == :halo
      assert halo_target.partition_query_scope == :halo_ghost
      assert halo_target.priority_band == :low
      assert halo_target.delivery_interval == 5

      GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 1)})

      assert_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{} = near_snapshot}}, 300
      assert near_snapshot.priority_band == :high
      refute_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{priority_band: :low}}}, 150

      GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 5)})

      delivered =
        2
        |> collect_player_moves(300)
        |> Enum.map(& &1.priority_band)
        |> Enum.sort()

      assert delivered == [:high, :low]

      CliObserve.flush()
      log = File.read!(observe_log)
      assert log =~ ~s(event="aoi_partition_interest_applied")
      assert log =~ ~s(event="aoi_refresh")
      assert log =~ "partition_near_count: 1"
      assert log =~ "partition_halo_count: 1"
      assert log =~ "partition_skipped_count: 0"
    after
      exit_aoi_item(mover)
      exit_aoi_item(near_observer)
      exit_aoi_item(halo_observer)
      exit_aoi_item(outside_observer)
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end

  test "remote-owned partition routes do not use local octree actors as ghost data" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "aoi-remote-ghost-mirror-#{System.unique_integer([:positive])}.log"
      )

    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.put_env(:scene_server, :cli_observe_log, observe_log)
    File.rm(observe_log)

    mover_cid = unique_cid()
    remote_owned_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    remote_owned_observer = add_aoi_item(remote_owned_cid, {1_650.0, 0.0, 0.0}, self())

    try do
      :sys.replace_state(mover, fn state -> %{state | interest_radius: 3_500} end)

      SceneServer.Aoi.AoiItem.update_partition_window(mover, %{
        logical_scene_id: 7,
        center_chunk: {0, 0, 0},
        near_radius: 0,
        halo_radius: 1,
        route_entries: [
          %{
            chunk_coord: {1, 0, 0},
            tier: :halo,
            status: :assigned,
            region_id: 10,
            lease_id: 100,
            assigned_scene_node: :"remote-scene@local"
          }
        ]
      })

      send(mover, :get_aoi_tick)

      wait_until(fn ->
        :sys.get_state(mover).partition_interest != nil
      end)

      partition_interest = :sys.get_state(mover).partition_interest
      assert partition_interest.remote_mirror_request_count == 1

      assert [%{reason: :remote_halo_route, chunk_coord: {1, 0, 0}, request_mode: :ghost}] =
               partition_interest.remote_mirror_requests

      assert :sys.get_state(mover).remote_mirror_requests ==
               partition_interest.remote_mirror_requests

      assert %{
               total_request_count: 1,
               group_count: 1,
               request_groups: [%{request_cids: [^mover_cid], cid_count: 1}],
               requests: [%{cid: ^mover_cid, request_mode: :ghost, reason: :remote_halo_route}]
             } = SceneServer.Aoi.RemoteMirrorLedger.snapshot()

      assert :sys.get_state(mover).subscribees == []
      refute_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 150

      CliObserve.flush()
      log = File.read!(observe_log)
      assert log =~ ~s(event="aoi_partition_interest_applied")
      assert log =~ ~s(event="aoi_remote_mirror_requests_updated")
      assert log =~ "remote_mirror_request_count: 1"
      assert log =~ "request_mode: :ghost"
      assert log =~ "status: :planned"
      assert log =~ "remote_halo_route"
    after
      exit_aoi_item(mover)
      exit_aoi_item(remote_owned_observer)
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end
  end

  test "remote mirror ledger withdraws requests when an AOI item exits" do
    mover_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())

    apply_partition_window(mover, [
      route({1, 0, 0}, :"remote-scene@local", tier: :halo, region_id: 20, lease_id: 200)
    ])

    wait_until(fn ->
      SceneServer.Aoi.RemoteMirrorLedger.snapshot().total_request_count == 1
    end)

    exit_aoi_item(mover)

    wait_until(fn ->
      SceneServer.Aoi.RemoteMirrorLedger.snapshot().total_request_count == 0
    end)
  end

  test "remote mirror ledger keeps shared remote groups until the last requester exits" do
    mover_cid = unique_cid()
    second_mover_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    second_mover = add_aoi_item(second_mover_cid, {50.0, 0.0, 0.0}, spawn_connection())

    try do
      remote_route =
        route({1, 0, 0}, :"remote-scene@local", tier: :halo, region_id: 20, lease_id: 200)

      apply_partition_window(mover, [remote_route])
      apply_partition_window(second_mover, [remote_route])

      wait_until(fn ->
        case SceneServer.Aoi.RemoteMirrorLedger.snapshot() do
          %{
            total_request_count: 2,
            group_count: 1,
            request_groups: [%{request_cids: request_cids}]
          } ->
            Enum.sort(request_cids) == Enum.sort([mover_cid, second_mover_cid])

          _other ->
            false
        end
      end)

      exit_aoi_item(mover)

      wait_until(fn ->
        case SceneServer.Aoi.RemoteMirrorLedger.snapshot() do
          %{
            total_request_count: 1,
            group_count: 1,
            request_groups: [%{request_cids: [^second_mover_cid]}]
          } ->
            true

          _other ->
            false
        end
      end)

      exit_aoi_item(second_mover)

      wait_until(fn ->
        match?(
          %{total_request_count: 0, group_count: 0},
          SceneServer.Aoi.RemoteMirrorLedger.snapshot()
        )
      end)
    after
      exit_aoi_item(mover)
      exit_aoi_item(second_mover)
    end
  end

  test "remote mirror requests are withdrawn when ownership returns local" do
    mover_cid = unique_cid()
    observer_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    observer = add_aoi_item(observer_cid, {1_650.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(observer)
    end)

    :sys.replace_state(mover, fn state -> %{state | interest_radius: 3_500} end)

    remote_window = %{
      logical_scene_id: 7,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 1,
      route_entries: [
        %{
          chunk_coord: {1, 0, 0},
          tier: :halo,
          status: :assigned,
          region_id: 20,
          lease_id: 200,
          assigned_scene_node: :"remote-scene@local"
        }
      ]
    }

    SceneServer.Aoi.AoiItem.update_partition_window(mover, remote_window)

    wait_until(fn ->
      :sys.get_state(mover).remote_mirror_requests != []
    end)

    assert [%{request_key: {:"remote-scene@local", 200, {1, 0, 0}}}] =
             :sys.get_state(mover).remote_mirror_requests

    assert :sys.get_state(mover).subscribees == []

    local_window = %{
      remote_window
      | route_entries: [
          %{
            chunk_coord: {1, 0, 0},
            tier: :halo,
            status: :assigned,
            region_id: 20,
            lease_id: 201,
            assigned_scene_node: node()
          }
        ]
    }

    SceneServer.Aoi.AoiItem.update_partition_window(mover, local_window)

    wait_until(fn ->
      state = :sys.get_state(mover)

      state.remote_mirror_requests == [] and
        state.partition_interest.remote_mirror_request_count == 0
    end)

    send(mover, :get_aoi_tick)

    wait_until(fn ->
      targets = :sys.get_state(mover).subscribees
      Enum.map(targets, & &1.cid) == [observer_cid]
    end)

    assert_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 300
    assert_receive {:"$gen_cast", {:actor_identity, ^mover_cid, :player, _name}}, 300
  end

  test "partition update prunes subscribers using fresh manager locations" do
    mover_cid = unique_cid()
    observer_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    observer = add_aoi_item(observer_cid, {100.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(observer)
    end)

    :sys.replace_state(mover, fn state -> %{state | interest_radius: 3_500} end)
    apply_partition_window(mover, [local_route({0, 0, 0})])
    send(mover, :get_aoi_tick)

    wait_until(fn ->
      targets = :sys.get_state(mover).subscribees
      Enum.map(targets, & &1.cid) == [observer_cid]
    end)

    cancel_aoi_timer(mover)

    GenServer.cast(
      observer,
      {:self_move,
       %RemoteSnapshot{
         cid: observer_cid,
         server_tick: 1,
         position: {1_700.0, 0.0, 0.0},
         velocity: {0.0, 0.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    wait_until(fn ->
      state = :sys.get_state(observer)
      state.location == {1_700.0, 0.0, 0.0}
    end)

    assert manager_entry_location(observer_cid) == {1_700.0, 0.0, 0.0}

    apply_partition_window(mover, [local_route({0, 0, 0}, lease_id: 101)])

    wait_until(fn ->
      state = :sys.get_state(mover)

      match?([%{lease_id: 101}], state.partition_interest.query_entries) and
        state.subscribees == []
    end)

    assert_receive {:"$gen_cast", {:player_leave, ^mover_cid}}, 300

    GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 2)})
    refute_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{}}}, 150
  end

  test "remote ownership update immediately prunes existing local subscribers" do
    mover_cid = unique_cid()
    observer_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    observer = add_aoi_item(observer_cid, {100.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(observer)
    end)

    local_window = %{
      logical_scene_id: 7,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 0,
      route_entries: [
        %{
          chunk_coord: {0, 0, 0},
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: node()
        }
      ]
    }

    SceneServer.Aoi.AoiItem.update_partition_window(mover, local_window)
    send(mover, :get_aoi_tick)

    wait_until(fn ->
      targets = :sys.get_state(mover).subscribees
      Enum.map(targets, & &1.cid) == [observer_cid]
    end)

    assert_receive {:"$gen_cast", {:player_enter, ^mover_cid, _location}}, 300
    assert_receive {:"$gen_cast", {:actor_identity, ^mover_cid, :player, _name}}, 300

    remote_window = %{
      local_window
      | route_entries: [
          %{
            chunk_coord: {0, 0, 0},
            tier: :near,
            status: :assigned,
            region_id: 10,
            lease_id: 101,
            assigned_scene_node: :"remote-scene@local"
          }
        ]
    }

    SceneServer.Aoi.AoiItem.update_partition_window(mover, remote_window)

    wait_until(fn ->
      state = :sys.get_state(mover)

      state.partition_interest != nil and
        match?([%{lease_id: 101}], state.partition_interest.query_entries)
    end)

    assert :sys.get_state(mover).subscribees == []
    assert_receive {:"$gen_cast", {:player_leave, ^mover_cid}}, 300

    GenServer.cast(mover, {:self_move, moving_snapshot(mover_cid, 1)})
    refute_receive {:"$gen_cast", {:player_move, %RemoteSnapshot{}}}, 150
  end

  test "nil partition window preserves the last authoritative AOI plan" do
    mover_cid = unique_cid()
    near_cid = unique_cid()
    outside_cid = unique_cid()

    mover = add_aoi_item(mover_cid, {0.0, 0.0, 0.0}, spawn_connection())
    near_observer = add_aoi_item(near_cid, {100.0, 0.0, 0.0}, self())
    outside_observer = add_aoi_item(outside_cid, {3_200.0, 0.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(mover)
      exit_aoi_item(near_observer)
      exit_aoi_item(outside_observer)
    end)

    :sys.replace_state(mover, fn state -> %{state | interest_radius: 3_500} end)

    partition_window = %{
      logical_scene_id: 7,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 0,
      route_entries: [
        %{
          chunk_coord: {0, 0, 0},
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: node()
        }
      ]
    }

    SceneServer.Aoi.AoiItem.update_partition_window(mover, partition_window)
    send(mover, :get_aoi_tick)

    wait_until(fn ->
      targets = :sys.get_state(mover).subscribees
      Enum.map(targets, & &1.cid) == [near_cid]
    end)

    SceneServer.Aoi.AoiItem.update_partition_window(mover, nil)
    send(mover, :get_aoi_tick)

    wait_until(fn ->
      state = :sys.get_state(mover)
      state.partition_interest.logical_scene_id == 7
    end)

    targets = :sys.get_state(mover).subscribees
    assert Enum.map(targets, & &1.cid) == [near_cid]
    refute Enum.any?(targets, &(&1.cid == outside_cid))
  end

  defp add_aoi_item(cid, location, connection_pid) do
    {:ok, pid} =
      AoiManager.add_aoi_item(
        cid,
        0,
        location,
        connection_pid,
        self(),
        %{kind: :player, name: "test-#{cid}"}
      )

    wait_until(fn ->
      case :sys.get_state(pid) do
        %{item_ref: item_ref} when not is_nil(item_ref) -> true
        _ -> false
      end
    end)

    pid
  end

  defp apply_partition_window(aoi_item, route_entries, opts \\ []) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 7)
    center_chunk = Keyword.get(opts, :center_chunk, {0, 0, 0})
    near_radius = Keyword.get(opts, :near_radius, 0)
    halo_radius = Keyword.get(opts, :halo_radius, 1)

    SceneServer.Aoi.AoiItem.update_partition_window(aoi_item, %{
      logical_scene_id: logical_scene_id,
      center_chunk: center_chunk,
      near_radius: near_radius,
      halo_radius: halo_radius,
      route_entries: route_entries
    })

    wait_until(fn ->
      case :sys.get_state(aoi_item).partition_interest do
        %{logical_scene_id: ^logical_scene_id, query_entries: entries} ->
          Enum.sort_by(entries, & &1.chunk_coord) ==
            route_entries
            |> Enum.sort_by(& &1.chunk_coord)
            |> Enum.map(fn entry ->
              %{
                chunk_coord: entry.chunk_coord,
                tier: entry.tier,
                region_id: entry.region_id,
                lease_id: entry.lease_id,
                assigned_scene_node: entry.assigned_scene_node,
                query_scope: if(entry.tier == :near, do: :authoritative, else: :halo_ghost),
                priority_band: if(entry.tier == :near, do: :high, else: :low),
                delivery_interval: if(entry.tier == :near, do: 1, else: 5)
              }
            end)

        _other ->
          false
      end
    end)
  end

  defp cancel_aoi_timer(aoi_item) do
    :sys.replace_state(aoi_item, fn state ->
      if state.aoi_timer != nil do
        Process.cancel_timer(state.aoi_timer)
      end

      %{state | aoi_timer: nil}
    end)
  end

  defp local_route(chunk_coord, opts \\ []) do
    route(chunk_coord, node(), opts)
  end

  defp route(chunk_coord, assigned_scene_node, opts) do
    %{
      chunk_coord: chunk_coord,
      tier: Keyword.get(opts, :tier, :near),
      status: :assigned,
      region_id: Keyword.get(opts, :region_id, 10),
      lease_id: Keyword.get(opts, :lease_id, 100),
      assigned_scene_node: assigned_scene_node
    }
  end

  defp manager_entry_location(cid) do
    case AoiManager.get_entries_with_cids([cid]) do
      [%{location: location}] -> location
      _other -> nil
    end
  end

  defp exit_aoi_item(nil), do: :ok

  defp exit_aoi_item(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :exit)
      wait_until(fn -> not Process.alive?(pid) end)
    end
  end

  defp spawn_connection do
    spawn(fn -> connection_loop() end)
  end

  defp moving_snapshot(cid, tick) do
    %RemoteSnapshot{
      cid: cid,
      server_tick: tick,
      position: {0.0, 0.0, 0.0},
      velocity: {10.0, 0.0, 0.0},
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: :grounded
    }
  end

  defp collect_player_moves(count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_player_moves_loop(count, deadline, [])
  end

  defp collect_player_moves_loop(0, _deadline, acc), do: Enum.reverse(acc)

  defp collect_player_moves_loop(count, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:"$gen_cast", {:player_move, %RemoteSnapshot{} = snapshot}} ->
          collect_player_moves_loop(count - 1, deadline, [snapshot | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp connection_loop do
    receive do
      _ -> connection_loop()
    end
  end

  defp unique_cid do
    System.unique_integer([:positive])
  end

  defp ensure_started(name, spec) do
    case Process.whereis(name) do
      nil -> start_supervised!(spec)
      pid -> pid
    end
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition not met before timeout")
  end
end
