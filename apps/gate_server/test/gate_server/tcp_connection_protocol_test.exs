defmodule GateServer.TcpConnectionProtocolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character
  alias GateServer.ChatAdapter
  alias GateServer.Voxel.{ChunkVersionLedger, ClientAckLedger, DeliveryScheduler}
  alias SceneServer.Movement.Ack
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.Storage
  alias WorldServer.Voxel.AuthorityObserve
  alias WorldServer.Voxel.MapLedger

  defmodule FakeInterface do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, Map.new(opts), name: GateServer.Interface)
    end

    def set(attrs) do
      GenServer.call(GateServer.Interface, {:set, Map.new(attrs)})
    end

    @impl true
    def init(attrs) do
      {:ok,
       Map.merge(
         %{auth_server: nil, chat_server: nil, scene_server: nil, world_server: nil},
         attrs
       )}
    end

    @impl true
    def handle_call({:set, attrs}, _from, state) do
      {:reply, :ok, Map.merge(state, attrs)}
    end

    @impl true
    def handle_call(:auth_server, _from, state) do
      {:reply, state.auth_server, state}
    end

    @impl true
    def handle_call(:scene_server, _from, state) do
      {:reply, state.scene_server, state}
    end

    @impl true
    def handle_call(:world_server, _from, state) do
      {:reply, state.world_server, state}
    end

    @impl true
    def handle_call(:chat_server, _from, state) do
      {:reply, state.chat_server, state}
    end
  end

  defmodule FakePlayer do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Map.new(opts))
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         location: Map.get(opts, :location, {1.0, 2.0, 3.0}),
         notify: Map.get(opts, :notify),
         movement_reply_location: Map.get(opts, :movement_reply_location)
       }}
    end

    @impl true
    def handle_call(:get_location, _from, state) do
      {:reply, {:ok, state.location}, state}
    end

    # Audit B-S1 / B-SRV1: tcp_connection now queries this between
    # add_player and EnterSceneResult encoding. Fresh fake player just
    # reports 1.
    @impl true
    def handle_call(:get_next_input_seq, _from, state) do
      {:reply, {:ok, 1}, state}
    end

    @impl true
    def handle_call({:movement_input, frame}, _from, state) do
      authoritative_location = state.movement_reply_location || state.location

      ack = %SceneServer.Movement.Ack{
        cid: 42,
        ack_seq: frame.seq,
        auth_tick: frame.client_tick,
        position: authoritative_location,
        velocity: {0.0, 0.0, 0.0},
        acceleration: {0.0, 0.0, 0.0},
        movement_mode: :grounded,
        correction_flags: 0,
        fixed_dt_ms: 100,
        ground_z: elem(authoritative_location, 2)
      }

      {:reply, {:ok, ack}, %{state | location: authoritative_location}}
    end

    @impl true
    def handle_call({:chat_say, cid, username, text}, _from, state) do
      if state.notify, do: send(state.notify, {:chat_say, cid, username, text})
      {:reply, {:ok, :sent}, state}
    end

    @impl true
    def handle_call({:cast_skill, cast_request}, _from, state) do
      if state.notify, do: send(state.notify, {:cast_skill, cast_request})
      {:reply, {:ok, state.location}, state}
    end

    @impl true
    def handle_call(:exit, _from, state) do
      if state.notify, do: send(state.notify, {:player_exit, self()})
      {:stop, :normal, {:ok, ""}, state}
    end
  end

  defmodule FakePlayerManager do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, Map.new(opts), name: SceneServer.PlayerManager)
    end

    def set(attrs) do
      GenServer.call(SceneServer.PlayerManager, {:set, Map.new(attrs)})
    end

    @impl true
    def init(attrs) do
      {:ok,
       Map.merge(
         %{
           add_player_result: :ok,
           location: {10.0, 20.0, 30.0},
           movement_reply_location: nil,
           notify: nil,
           last_character_profile: nil
         },
         attrs
       )}
    end

    @impl true
    def handle_call({:set, attrs}, _from, state) do
      {:reply, :ok, Map.merge(state, attrs)}
    end

    @impl true
    def handle_call(
          {:add_player, _cid, _connection_pid, _timestamp, character_profile},
          _from,
          state
        ) do
      case state.add_player_result do
        :ok ->
          {:ok, pid} =
            FakePlayer.start_link(
              location: state.location,
              notify: state.notify,
              movement_reply_location: state.movement_reply_location
            )

          {:reply, {:ok, pid}, %{state | last_character_profile: character_profile}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_info({:player_exit, _pid}, state) do
      {:noreply, state}
    end
  end

  defmodule ChatCollector do
    use GenServer

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :tag)},
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Map.new(opts))
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast(message, %{owner: owner, tag: tag} = state) do
      send(owner, {:chat_collector, tag, message})
      {:noreply, state}
    end
  end

  setup_all do
    _ = Application.stop(:gate_server)
    _ = Application.stop(:scene_server)
    _ = Application.stop(:chat_server)
    ensure_name_available(GateServer.Interface)
    ensure_name_available(SceneServer.PlayerManager)
    ensure_name_available(GateServer.FastLaneRegistry)
    ensure_name_available(GateServer.UdpAcceptor)
    ensure_name_available(ChatServer.Runtime)
    ensure_name_available(ChatServer.RuntimeDirectory)
    ensure_name_available(ChatServer.RuntimeShardSup)
    {:ok, _} = Application.ensure_all_started(:auth_server)
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    repo_config = DataService.Repo.config()

    case Ecto.Adapters.Postgres.storage_up(repo_config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, _reason} -> :ok
    end

    ensure_repo_started()

    migrations_path = Path.expand("../../../data_service/priv/repo/migrations", __DIR__)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    _ =
      start_supervised(
        {GateServer.FastLaneRegistry,
         name: GateServer.FastLaneRegistry, session_idle_timeout_ms: 250}
      )

    _ = start_supervised({GateServer.UdpAcceptor, name: GateServer.UdpAcceptor, port: 0})

    _ =
      start_supervised(
        {DynamicSupervisor, strategy: :one_for_one, name: ChatServer.RuntimeShardSup}
      )

    _ =
      start_supervised(
        {ChatServer.RuntimeDirectory,
         name: ChatServer.RuntimeDirectory, runtime_supervisor: ChatServer.RuntimeShardSup}
      )

    _ = start_supervised(FakeInterface)
    _ = start_supervised(FakePlayerManager)
    :ok
  end

  setup do
    ensure_repo_started()
    previous_gate_observe_log = Application.fetch_env(:gate_server, :cli_observe_log)

    Repo.delete_all(Character)
    Repo.delete_all(Account)
    FakeInterface.set(auth_server: nil, chat_server: nil, scene_server: nil, world_server: nil)

    FakePlayerManager.set(
      add_player_result: :ok,
      location: {10.0, 20.0, 30.0},
      movement_reply_location: nil,
      notify: nil
    )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: true, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 4, active: false])
    {:ok, server} = :gen_tcp.accept(listener)
    {:ok, pid} = GateServer.TcpConnection.start_link(server)
    :ok = :gen_tcp.controlling_process(server, pid)
    :ok = :gen_tcp.close(listener)

    on_exit(fn ->
      _ = :gen_tcp.close(client)
      _ = :gen_tcp.close(server)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      restore_env(:gate_server, previous_gate_observe_log)
    end)

    {:ok, client: client, server: server, pid: pid}
  end

  test "unauthenticated enter_scene is rejected with enter-scene error reply", %{
    client: client,
    pid: pid
  } do
    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 1))
    assert {:ok, <<0x84, 1::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)

    assert %{status: :waiting_auth, scene_ref: nil, cid: -1} = :sys.get_state(pid)
  end

  test "movement before auth is rejected with generic error reply", %{client: client, pid: pid} do
    assert :ok = :gen_tcp.send(client, encode_movement_input(2, 10, {1.0, 0.0}))
    assert {:ok, <<0x80, 2::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)

    assert %{status: :waiting_auth, scene_ref: nil} = :sys.get_state(pid)
  end

  test "auth unavailable returns a stable generic error reply", %{client: client, pid: pid} do
    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", "invalid-token", 13))
    assert {:ok, <<0x80, 13::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)

    assert %{status: :waiting_auth, token: nil} = :sys.get_state(pid)
  end

  test "valid auth transitions to authenticated and enter_scene success transitions to in_scene",
       %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())
    claims = AuthServer.AuthWorker.build_session_claims("tester", source: "test")
    token = AuthServer.AuthWorker.issue_token(claims)

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 11))
    assert {:ok, <<0x80, 11::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert %{status: :authenticated, token: ^token, auth_username: "tester"} = :sys.get_state(pid)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 12))

    assert {:ok,
            <<0x84, 12::64-big, 0x00, x::float-64-big, y::float-64-big, z::float-64-big,
              expected_seq::32-big, _protocol_version::16-big>>} =
             :gen_tcp.recv(client, 0, 500)

    assert {x, y, z} == {10.0, 20.0, 30.0}
    assert expected_seq == 1
    assert %{status: :in_scene, cid: 42, agent: %{"active_cid" => 42}} = :sys.get_state(pid)

    assert %{last_character_profile: %{name: "tester-character-42"}} =
             :sys.get_state(SceneServer.PlayerManager)
  end

  test "movement before scene join is rejected after auth", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 21))
    assert {:ok, <<0x80, 21::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_movement_input(22, 100, {1.0, 0.0}))
    assert {:ok, <<0x80, 22::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
    assert %{status: :authenticated, scene_ref: nil} = :sys.get_state(pid)
  end

  test "time_sync is allowed after auth and returns full timing payload", %{
    client: client,
    pid: pid
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 31))
    assert {:ok, <<0x80, 31::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_time_sync(32, 1234))

    assert {:ok,
            <<0x85, 32::64-big, 1234::64-big, server_recv_ts::64-big, server_send_ts::64-big>>} =
             :gen_tcp.recv(client, 0, 500)

    assert server_recv_ts <= server_send_ts
    assert %{status: :authenticated, scene_ref: nil} = :sys.get_state(pid)
  end

  test "scene unavailable after auth returns enter-scene error reply", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: nil)

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 41))
    assert {:ok, <<0x80, 41::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 42))
    assert {:ok, <<0x84, 42::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
    assert %{status: :authenticated, scene_ref: nil} = :sys.get_state(pid)
  end

  test "data-service unavailability fails closed during real character authorization", %{
    client: client,
    pid: pid
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 43))
    assert {:ok, <<0x80, 43::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    # 模拟身份/数据后端不可用:把 auth 节点解析指向一个不可达节点。新架构下 character
    # authorization 经 :rpc.call(auth_node, AuthServer.AuthWorker, :fetch_authorized_character, ...)
    # 触达持有 data_service 的后端,不可达 → :badrpc → gate 映射为 :auth_unavailable →
    # enter-scene 必须 fail closed(错误响应),而非放行带角色数据的成功响应。
    # (旧版用 FakeAuthInterface 让 AuthServer.Interface 的 :data_service 解析返回 nil;Accounts
    #  改为同 BEAM 直调 DataService.Worker 后该解析已不在授权路径上,故改为让后端 rpc 不可达。)
    FakeInterface.set(auth_server: :"data_unavailable@127.0.0.1", scene_server: node())

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 44))
    assert {:ok, <<0x84, 44::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 1000)
    assert %{status: :authenticated, scene_ref: nil} = :sys.get_state(pid)
  end

  test "username mismatch is rejected during auth", %{client: client, pid: pid} do
    FakeInterface.set(auth_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("other-user", token, 51))
    assert {:ok, <<0x80, 51::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
    assert %{status: :waiting_auth, auth_claims: nil} = :sys.get_state(pid)
  end

  test "cid mismatch is rejected when token restricts allowed cid", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims(cid: 42)
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 61))
    assert {:ok, <<0x80, 61::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(77, 62))
    assert {:ok, <<0x84, 62::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
    assert %{status: :authenticated, scene_ref: nil, cid: -1} = :sys.get_state(pid)
  end

  test "cid mismatch is rejected by real character ownership even without cid claim", %{
    client: client
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 66))
    assert {:ok, <<0x80, 66::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(77, 67))
    assert {:ok, <<0x84, 67::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
  end

  test "request-id-aware movement returns authoritative location after scene join", %{
    client: client,
    pid: pid
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())
    FakePlayerManager.set(movement_reply_location: {8.0, 9.0, 10.0})

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 71))
    assert {:ok, <<0x80, 71::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 72))
    assert {:ok, <<0x84, 72::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_movement_input(73, 100, {1.0, 0.0}))

    scene_ref = :sys.get_state(pid).scene_ref
    wait_until(fn -> SceneServer.PlayerCharacter.pending_movement_input_count(scene_ref) == 1 end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 73,
         auth_tick: 100,
         position: {8.0, 9.0, 10.0},
         fixed_dt_ms: 100,
         ground_z: 10.0
       })}
    )

    assert {:ok,
            <<0x8B, 2, 73::32-big, 100::32-big, _server_state_ms_ack1::64-big,
              server_send_ms_ack1::64-big, 42::64-big, 8.0::float-64-big, 9.0::float-64-big,
              10.0::float-64-big, _::binary>>} =
             :gen_tcp.recv(client, 0, 500)

    assert server_send_ms_ack1 > 0
  end

  test "request-id-aware time_sync echoes packet_id after scene join", %{client: client} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 81))
    assert {:ok, <<0x80, 81::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 82))
    assert {:ok, <<0x84, 82::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_time_sync(83, 9999))

    assert {:ok,
            <<0x85, 83::64-big, 9999::64-big, server_recv_ts::64-big, server_send_ts::64-big>>} =
             :gen_tcp.recv(client, 0, 500)

    assert server_recv_ts <= server_send_ts
  end

  test "chat before scene join is rejected with generic error reply", %{client: client} do
    assert :ok = :gen_tcp.send(client, encode_chat_say(84, "hello"))
    assert {:ok, <<0x80, 84::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
  end

  test "chat in_scene is delivered by Chat runtime and not Scene AOI", %{client: client} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())
    FakePlayerManager.set(notify: self())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 85))
    assert {:ok, <<0x80, 85::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 86))
    assert {:ok, <<0x84, 86::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_chat_say(87, "hello world"))
    assert {:ok, <<0x80, 87::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 11::16-big, "hello world">>} =
             :gen_tcp.recv(client, 0, 500)

    refute_receive {:chat_say, 42, "tester", "hello world"}, 100
  end

  test "chat uses server-side character logical scene and does not cross-talk to default scene",
       %{client: client, pid: pid} do
    assert {:ok, _} =
             ChatAdapter.join(%{
               cid: 99,
               username: "default-scene",
               connection_pid: self(),
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    insert_account_and_character("tester", 42,
      position: %{"x" => 10.0, "y" => 20.0, "z" => 30.0, "logical_scene_id" => 77}
    )

    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 188))
    assert {:ok, <<0x80, 188::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 189))
    assert {:ok, <<0x84, 189::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert %{chat_context: %{logical_scene_id: 77}} = :sys.get_state(pid)

    assert :ok = :gen_tcp.send(client, encode_chat_say(190, "scene-77"))
    assert {:ok, <<0x80, 190::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 8::16-big, "scene-77">>} =
             :gen_tcp.recv(client, 0, 500)

    refute_receive {:"$gen_cast", {:chat_message, 42, "tester", "scene-77"}}, 100
  end

  test "scoped region chat over tcp is routed from server partition context",
       %{client: client, pid: pid} do
    logical_scene_id = unique_id()
    context = %{logical_scene_id: logical_scene_id, region_id: 77, chunk_coord: {0, 0, 0}}

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: :in_scene,
          cid: 42,
          auth_username: "tester",
          chat_session_joined?: true,
          chat_context: context,
          partition_context: context
      }
    end)

    same_region = start_supervised!({ChatCollector, owner: self(), tag: :same_region})
    other_region = start_supervised!({ChatCollector, owner: self(), tag: :other_region})

    join_chat_session(pid, 42, "tester", logical_scene_id, 77, {0, 0, 0})
    join_chat_session(same_region, 43, "nearby", logical_scene_id, 77, {1, 0, 0})
    join_chat_session(other_region, 44, "far", logical_scene_id, 88, {4, 0, 0})

    assert :ok = :gen_tcp.send(client, encode_scoped_chat_say(193, :region, "region-tcp"))
    assert {:ok, <<0x80, 193::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 10::16-big, "region-tcp">>} =
             :gen_tcp.recv(client, 0, 500)

    assert_receive {:chat_collector, :same_region, {:chat_message, 42, "tester", "region-tcp"}}

    refute_receive {:chat_collector, :other_region, {:chat_message, 42, "tester", "region-tcp"}},
                   100
  end

  test "scoped local chat over tcp uses server candidates and exact chunk radius",
       %{client: client, pid: pid} do
    logical_scene_id = unique_id()

    context = %{
      logical_scene_id: logical_scene_id,
      region_id: 77,
      chunk_coord: {0, 0, 0},
      candidate_region_ids: [77],
      candidate_region_radius: 1
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: :in_scene,
          cid: 42,
          auth_username: "tester",
          chat_session_joined?: true,
          chat_context: context,
          partition_context: context
      }
    end)

    nearby = start_supervised!({ChatCollector, owner: self(), tag: :nearby})
    far_chunk = start_supervised!({ChatCollector, owner: self(), tag: :far_chunk})
    other_region = start_supervised!({ChatCollector, owner: self(), tag: :other_region})

    join_chat_session(pid, 42, "tester", logical_scene_id, 77, {0, 0, 0})
    join_chat_session(nearby, 43, "nearby", logical_scene_id, 77, {1, 0, 0})
    join_chat_session(far_chunk, 44, "far-chunk", logical_scene_id, 77, {9, 0, 0})
    join_chat_session(other_region, 45, "near-other-region", logical_scene_id, 88, {1, 0, 0})

    assert :ok = :gen_tcp.send(client, encode_scoped_chat_say(194, :local, "local-tcp"))
    assert {:ok, <<0x80, 194::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 9::16-big, "local-tcp">>} =
             :gen_tcp.recv(client, 0, 500)

    assert_receive {:chat_collector, :nearby, {:chat_message, 42, "tester", "local-tcp"}}

    refute_receive {:chat_collector, :far_chunk, {:chat_message, 42, "tester", "local-tcp"}},
                   100

    refute_receive {:chat_collector, :other_region, {:chat_message, 42, "tester", "local-tcp"}},
                   100
  end

  test "scoped local chat over tcp falls back when candidate radius is too small",
       %{client: client, pid: pid} do
    previous_radius = Application.fetch_env(:gate_server, :local_chat_radius)
    Application.put_env(:gate_server, :local_chat_radius, 4)

    try do
      logical_scene_id = unique_id()

      context = %{
        logical_scene_id: logical_scene_id,
        region_id: 77,
        chunk_coord: {0, 0, 0},
        candidate_region_ids: [77],
        candidate_region_radius: 1
      }

      :sys.replace_state(pid, fn state ->
        %{
          state
          | status: :in_scene,
            cid: 42,
            auth_username: "tester",
            chat_session_joined?: true,
            chat_context: context,
            partition_context: context
        }
      end)

      cross_region_near =
        start_supervised!({ChatCollector, owner: self(), tag: :cross_region})

      join_chat_session(pid, 42, "tester", logical_scene_id, 77, {0, 0, 0})

      join_chat_session(
        cross_region_near,
        43,
        "near-cross-region",
        logical_scene_id,
        88,
        {2, 0, 0}
      )

      assert :ok = :gen_tcp.send(client, encode_scoped_chat_say(195, :local, "fallback-tcp"))
      assert {:ok, <<0x80, 195::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

      assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 12::16-big, "fallback-tcp">>} =
               :gen_tcp.recv(client, 0, 500)

      assert_receive {:chat_collector, :cross_region,
                      {:chat_message, 42, "tester", "fallback-tcp"}}
    after
      restore_local_chat_radius(previous_radius)
    end
  end

  test "enter_scene seeds partition and chat region from World route instead of stale character metadata",
       %{client: client, pid: pid} do
    ensure_map_ledger_started()
    logical_scene_id = unique_id()
    region_id = unique_id()
    put_partition_region(logical_scene_id, region_id, {0, 0, 0}, {1, 1, 1}, 90_001)

    insert_account_and_character("tester", 42,
      position: %{
        "x" => 100.0,
        "y" => 100.0,
        "z" => 100.0,
        "logical_scene_id" => logical_scene_id,
        "region_id" => 999_999
      }
    )

    FakeInterface.set(auth_server: node(), scene_server: node(), world_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 191))
    assert {:ok, <<0x80, 191::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 192))
    assert {:ok, <<0x84, 192::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    state_after_enter = :sys.get_state(pid)
    assert state_after_enter.partition_context.region_id == region_id
    assert state_after_enter.chat_context.region_id == region_id
    refute state_after_enter.partition_context.region_id == 999_999
  end

  test "chat_message cast is encoded to the client socket", %{client: client, pid: pid} do
    GenServer.cast(pid, {:chat_message, 42, "tester", "hello world"})

    assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 11::16-big, "hello world">>} =
             :gen_tcp.recv(client, 0, 500)
  end

  test "skill cast in_scene is forwarded to player process and acked", %{client: client} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())
    FakePlayerManager.set(notify: self())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 88))
    assert {:ok, <<0x80, 88::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 89))
    assert {:ok, <<0x84, 89::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_skill_cast(90, 1))
    assert {:ok, <<0x80, 90::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert_receive {:cast_skill,
                    %SceneServer.Combat.CastRequest{skill_id: 1, target_mode: :auto}},
                   500
  end

  test "skill_event cast is encoded to the client socket", %{client: client, pid: pid} do
    GenServer.cast(pid, {:skill_event, 42, 1, {7.0, 8.0, 9.0}})

    assert {:ok,
            <<0x8A, 42::64-big, 1::16-big, 7.0::float-64-big, 8.0::float-64-big,
              9.0::float-64-big>>} = :gen_tcp.recv(client, 0, 500)
  end

  test "player_state and combat_hit casts are encoded to the client socket", %{
    client: client,
    pid: pid
  } do
    GenServer.cast(pid, {:player_state, 42, 75, 100, true})

    assert {:ok, <<0x8C, 42::64-big, 75::16-big, 100::16-big, 1::8>>} =
             :gen_tcp.recv(client, 0, 500)

    GenServer.cast(pid, {:combat_hit, 7, 42, 1, 25, 75, {1.0, 2.0, 3.0}})

    assert {:ok,
            <<0x8D, 7::64-big, 42::64-big, 1::16-big, 25::16-big, 75::16-big, 1.0::float-64-big,
              2.0::float-64-big, 3.0::float-64-big>>} =
             :gen_tcp.recv(client, 0, 500)
  end

  test "fast-lane bootstrap returns udp port and ticket after auth", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 90))
    assert {:ok, <<0x80, 90::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 91::64-big>>)

    assert {:ok,
            <<0x87, 91::64-big, 0x00, udp_port::16-big, tlen::16-big, ticket::binary-size(tlen)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert udp_port == GateServer.UdpAcceptor.port()
    assert is_binary(ticket)
    assert byte_size(ticket) > 0
    assert %{udp_ticket: ^ticket} = :sys.get_state(pid)
  end

  test "udp attach consumes ticket and records peer", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 100))
    assert {:ok, <<0x80, 100::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 101::64-big>>)

    assert {:ok,
            <<0x87, 101::64-big, 0x00, udp_port::16-big, tlen::16-big, ticket::binary-size(tlen)>>} =
             :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client} = :gen_udp.open(0, [:binary, active: false])

    assert :ok =
             :gen_udp.send(
               udp_client,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(102, ticket)
             )

    assert {:ok, {{127, 0, 0, 1}, _port, <<0x88, 102::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    wait_until(fn ->
      match?(
        %{peer: {{127, 0, 0, 1}, _port}},
        GateServer.FastLaneRegistry.session_for_connection(pid)
      )
    end)

    assert %{udp_peer: {{127, 0, 0, 1}, _}} = :sys.get_state(pid)
    :gen_udp.close(udp_client)
  end

  test "attached udp peer can send movement uplink and receive movement_ack", %{
    client: client,
    pid: pid
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())
    FakePlayerManager.set(movement_reply_location: {17.0, 18.0, 19.0})

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 110))
    assert {:ok, <<0x80, 110::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 111))
    assert {:ok, <<0x84, 111::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 112::64-big>>)

    assert {:ok,
            <<0x87, 112::64-big, 0x00, udp_port::16-big, tlen::16-big, ticket::binary-size(tlen)>>} =
             :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client} = :gen_udp.open(0, [:binary, active: false])

    assert :ok =
             :gen_udp.send(
               udp_client,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(113, ticket)
             )

    assert {:ok, {{127, 0, 0, 1}, _port, <<0x88, 113::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    movement = encode_movement_input(114, 200, {1.0, 0.0})

    assert :ok = :gen_udp.send(udp_client, {127, 0, 0, 1}, udp_port, movement)

    scene_ref = :sys.get_state(pid).scene_ref
    wait_until(fn -> SceneServer.PlayerCharacter.pending_movement_input_count(scene_ref) == 1 end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 114,
         auth_tick: 200,
         position: {17.0, 18.0, 19.0},
         fixed_dt_ms: 100,
         ground_z: 19.0
       })}
    )

    assert {:ok,
            {{127, 0, 0, 1}, _port,
             <<0x8B, 2, 114::32-big, 200::32-big, _server_state_ms_udp::64-big,
               server_send_ms_udp::64-big, 42::64-big, 17.0::float-64-big, 18.0::float-64-big,
               19.0::float-64-big, _::binary>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    assert server_send_ms_udp > 0

    :gen_udp.close(udp_client)
  end

  test "movement_ack sends client ACK before refreshing partition and chat presence", %{
    client: client,
    pid: pid
  } do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()
    logical_scene_id = unique_id()
    source_region_id = unique_id()
    target_region_id = unique_id()

    put_partition_region(logical_scene_id, source_region_id, {0, 0, 0}, {1, 1, 1}, 91_001)
    put_partition_region(logical_scene_id, target_region_id, {1, 0, 0}, {2, 1, 1}, 91_002)

    FakeInterface.set(world_server: node(), chat_server: node())

    assert {:ok, _session} =
             ChatAdapter.join(%{
               cid: 42,
               username: "tester",
               connection_pid: pid,
               logical_scene_id: logical_scene_id,
               region_id: source_region_id,
               chunk_coord: {0, 0, 0},
               location: {0.0, 0.0, 0.0}
             })

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        chat_session_joined?: true,
        chat_context: %{
          logical_scene_id: logical_scene_id,
          region_id: source_region_id,
          chunk_coord: {0, 0, 0}
        },
        partition_context: %{
          logical_scene_id: logical_scene_id,
          region_id: source_region_id,
          chunk_coord: {0, 0, 0}
        }
      })
    end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 314,
         auth_tick: 2718,
         position: {1_650.0, 50.0, 0.0}
       })}
    )

    assert {:ok,
            <<0x8B, 2, 314::32-big, 2718::32-big, _server_state_ms_314::64-big,
              _server_send_ms_314::64-big, 42::64-big, 1_650.0::float-64-big, 50.0::float-64-big,
              _z::float-64-big, _::binary>>} =
             :gen_tcp.recv(client, 0, 500)

    wait_until(fn ->
      match?(
        %{chat_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}},
        :sys.get_state(pid)
      )
    end)

    refreshed_state = :sys.get_state(pid)

    assert %{chat_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}} =
             refreshed_state

    assert %{partition_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}} =
             refreshed_state

    assert %{last_partition_refresh: %{subscription_apply_status: :ok}} = refreshed_state
    refute Map.has_key?(refreshed_state, :partition_refresh_pending)
    assert Map.has_key?(refreshed_state.voxel_subscriptions, {logical_scene_id, {1, 0, 0}})
    assert refreshed_state.voxel_subscription_plan.subscribe_count >= 1

    snapshot = ChatServer.RuntimeDirectory.snapshot(ChatServer.RuntimeDirectory)

    assert %{runtime_pid: runtime_pid} =
             Enum.find(snapshot.shards, &(&1.logical_scene_id == logical_scene_id))

    assert %{sessions: [%{region_id: ^target_region_id, chunk_coord: {1, 0, 0}} | _]} =
             ChatServer.Runtime.snapshot(runtime_pid)
  end

  test "movement_ack leaves tcp connection responsive while partition refresh is pending", %{
    client: client,
    pid: pid
  } do
    parent = self()
    refresh_fun = blocking_partition_refresh_fun(parent)

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        chat_session_joined?: true,
        chat_context: %{
          logical_scene_id: 701,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        partition_context: %{
          logical_scene_id: 701,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        partition_refresh_fun: refresh_fun
      })
    end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 515,
         auth_tick: 3_101,
         position: {1_650.0, 50.0, 0.0}
       })}
    )

    assert_receive {:partition_refresh_started, refresh_pid, ^pid, ^pid}, 500

    assert {:ok,
            <<0x8B, 2, 515::32-big, 3101::32-big, _server_state_ms_515::64-big,
              _server_send_ms_515::64-big, 42::64-big, 1_650.0::float-64-big, 50.0::float-64-big,
              _z::float-64-big, _::binary>>} =
             :gen_tcp.recv(client, 0, 500)

    pending_state = :sys.get_state(pid)
    assert pending_state.partition_context.region_id == 10
    assert pending_state.partition_refresh_pending.generation == 1
    assert pending_state.partition_refresh_pending.status == :pending
    assert pending_state.partition_refresh_pending.auth_tick == 3_101

    assert :ok = :gen_tcp.send(client, encode_debug_probe(516, "voxel_transport"))

    assert {:ok, <<0x6F, 516::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert debug_result =~ "partition_refresh_generation=1"
    assert debug_result =~ "partition_refresh_pending_status=pending"
    assert debug_result =~ "partition_refresh_pending_generation=1"
    assert debug_result =~ "partition_refresh_pending_auth_tick=3101"

    send(refresh_pid, :release_partition_refresh)
  end

  test "partition refresh completion with mismatched auth_tick is dropped by tcp owner process",
       %{
         pid: pid
       } do
    parent = self()

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        partition_refresh_generation: 1,
        partition_refresh_pending: %{status: :pending, generation: 1, auth_tick: 4_101},
        partition_context: %{
          logical_scene_id: 701,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        chat_context: %{
          logical_scene_id: 701,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        partition_refresh_apply_fun: fn current_state, _decision, _opts ->
          send(parent, :mismatched_auth_tick_apply_called)
          {:ok, current_state, %{status: :applied_by_wrong_tick}}
        end
      })
    end)

    send(
      pid,
      {:partition_refresh_completed, 1, 4_100,
       {:ok,
        %{
          kind: :last_refresh,
          status: :ok,
          outcome: %{status: :updated, boundary_kind: :region, region_id: 20}
        }}}
    )

    Process.sleep(50)
    refute_received :mismatched_auth_tick_apply_called

    state = :sys.get_state(pid)
    assert state.partition_refresh_pending.auth_tick == 4_101
    assert state.last_partition_refresh == nil
  end

  test "scoped region chat after movement boundary uses refreshed chat context", %{
    client: client,
    pid: pid
  } do
    ensure_map_ledger_started()
    logical_scene_id = unique_id()
    source_region_id = unique_id()
    target_region_id = unique_id()

    put_partition_region(logical_scene_id, source_region_id, {0, 0, 0}, {1, 1, 1}, 92_001)
    put_partition_region(logical_scene_id, target_region_id, {1, 0, 0}, {2, 1, 1}, 92_002)

    FakeInterface.set(world_server: node(), chat_server: node(), scene_server: nil)

    target_peer = start_supervised!({ChatCollector, owner: self(), tag: :target_region})
    source_peer = start_supervised!({ChatCollector, owner: self(), tag: :source_region})

    join_chat_session(pid, 42, "tester", logical_scene_id, source_region_id, {0, 0, 0})

    join_chat_session(
      target_peer,
      43,
      "target-peer",
      logical_scene_id,
      target_region_id,
      {1, 0, 0}
    )

    join_chat_session(
      source_peer,
      44,
      "source-peer",
      logical_scene_id,
      source_region_id,
      {0, 0, 0}
    )

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        status: :in_scene,
        cid: 42,
        auth_username: "tester",
        chat_session_joined?: true,
        chat_context: %{
          logical_scene_id: logical_scene_id,
          region_id: source_region_id,
          chunk_coord: {0, 0, 0}
        },
        partition_context: %{
          logical_scene_id: logical_scene_id,
          region_id: source_region_id,
          chunk_coord: {0, 0, 0}
        }
      })
    end)

    GenServer.cast(
      pid,
      {:movement_ack,
       ack(%{
         cid: 42,
         ack_seq: 414,
         auth_tick: 3718,
         position: {1_650.0, 50.0, 0.0}
       })}
    )

    assert {:ok,
            <<0x8B, 2, 414::32-big, 3718::32-big, _server_state_ms_414::64-big,
              _server_send_ms_414::64-big, 42::64-big, 1_650.0::float-64-big, 50.0::float-64-big,
              _z::float-64-big, _::binary>>} =
             :gen_tcp.recv(client, 0, 500)

    wait_until(fn ->
      match?(
        %{chat_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}},
        :sys.get_state(pid)
      )
    end)

    assert %{chat_context: %{region_id: ^target_region_id, chunk_coord: {1, 0, 0}}} =
             :sys.get_state(pid)

    assert :ok =
             :gen_tcp.send(
               client,
               encode_scoped_chat_say(196, :region, "after-boundary-region")
             )

    assert {:ok, <<0x80, 196::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert {:ok, <<0x89, 42::64-big, 6::16-big, "tester", 21::16-big, "after-boundary-region">>} =
             :gen_tcp.recv(client, 0, 500)

    assert_receive {:chat_collector, :target_region,
                    {:chat_message, 42, "tester", "after-boundary-region"}}

    refute_receive {:chat_collector, :source_region,
                    {:chat_message, 42, "tester", "after-boundary-region"}},
                   100
  end

  test "attached udp peer receives player_move downlink over udp instead of tcp", %{
    client: client,
    pid: pid
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 120))
    assert {:ok, <<0x80, 120::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 121))
    assert {:ok, <<0x84, 121::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 122::64-big>>)

    assert {:ok,
            <<0x87, 122::64-big, 0x00, udp_port::16-big, tlen::16-big, ticket::binary-size(tlen)>>} =
             :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client} = :gen_udp.open(0, [:binary, active: false])

    assert :ok =
             :gen_udp.send(
               udp_client,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(123, ticket)
             )

    assert {:ok, {{127, 0, 0, 1}, _port, <<0x88, 123::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    snapshot = %SceneServer.Movement.RemoteSnapshot{
      cid: 77,
      server_tick: 9,
      position: {11.0, 12.0, 13.0},
      velocity: {1.0, 2.0, 3.0},
      acceleration: {0.1, 0.2, 0.3},
      movement_mode: :grounded
    }

    GenServer.cast(pid, {:player_move, snapshot})

    assert {:ok,
            {{127, 0, 0, 1}, _port,
             <<0x83, 2, 77::64-big, 9::32-big, _server_state_ms_pm1::64-big,
               _server_send_ms_pm1::64-big, 11.0::float-64-big, 12.0::float-64-big,
               13.0::float-64-big, 1.0::float-64-big, 2.0::float-64-big, 3.0::float-64-big,
               0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big, 0::8>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 100)

    :gen_udp.close(udp_client)
  end

  test "reattaching fast lane replaces the previous udp peer", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 130))
    assert {:ok, <<0x80, 130::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 131))
    assert {:ok, <<0x84, 131::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 132::64-big>>)

    assert {:ok,
            <<0x87, 132::64-big, 0x00, udp_port::16-big, tlen::16-big,
              ticket1::binary-size(tlen)>>} = :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client1} = :gen_udp.open(0, [:binary, active: false])
    {:ok, client1_port} = :inet.port(udp_client1)

    assert :ok =
             :gen_udp.send(
               udp_client1,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(133, ticket1)
             )

    assert {:ok, {{127, 0, 0, 1}, _port1, <<0x88, 133::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client1, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 134::64-big>>)

    assert {:ok,
            <<0x87, 134::64-big, 0x00, ^udp_port::16-big, tlen2::16-big,
              ticket2::binary-size(tlen2)>>} = :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client2} = :gen_udp.open(0, [:binary, active: false])
    {:ok, client2_port} = :inet.port(udp_client2)

    assert :ok =
             :gen_udp.send(
               udp_client2,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(135, ticket2)
             )

    assert {:ok, {{127, 0, 0, 1}, port2, <<0x88, 135::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client2, 0, 500)

    refute client1_port == client2_port

    wait_until(fn ->
      match?(
        %{peer: {{127, 0, 0, 1}, ^client2_port}},
        GateServer.FastLaneRegistry.session_for_connection(pid)
      )
    end)

    GenServer.cast(
      pid,
      {:player_move,
       %SceneServer.Movement.RemoteSnapshot{
         cid: 77,
         server_tick: 10,
         position: {21.0, 22.0, 23.0},
         velocity: {1.0, 0.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    assert {:ok,
            {{127, 0, 0, 1}, ^port2,
             <<0x83, 2, 77::64-big, 10::32-big, _server_state_ms_pm2::64-big,
               _server_send_ms_pm2::64-big, 21.0::float-64-big, 22.0::float-64-big,
               23.0::float-64-big, 1.0::float-64-big, +0.0::float-64-big, +0.0::float-64-big,
               +0.0::float-64-big, +0.0::float-64-big, +0.0::float-64-big, 0::8>>}} =
             :gen_udp.recv(udp_client2, 0, 500)

    assert {:error, :timeout} = :gen_udp.recv(udp_client1, 0, 100)
    assert %{udp_peer: {{127, 0, 0, 1}, ^client2_port}} = :sys.get_state(pid)

    :gen_udp.close(udp_client1)
    :gen_udp.close(udp_client2)
  end

  test "idle udp sessions expire and downlink falls back to tcp", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 140))
    assert {:ok, <<0x80, 140::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 141))
    assert {:ok, <<0x84, 141::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 142::64-big>>)

    assert {:ok,
            <<0x87, 142::64-big, 0x00, udp_port::16-big, tlen::16-big, ticket::binary-size(tlen)>>} =
             :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client} = :gen_udp.open(0, [:binary, active: false])

    assert :ok =
             :gen_udp.send(
               udp_client,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(143, ticket)
             )

    assert {:ok, {{127, 0, 0, 1}, _port, <<0x88, 143::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    Process.sleep(350)
    assert nil == GateServer.FastLaneRegistry.session_for_connection(pid)
    wait_until(fn -> is_nil(:sys.get_state(pid).udp_peer) end)

    GenServer.cast(
      pid,
      {:player_move,
       %SceneServer.Movement.RemoteSnapshot{
         cid: 88,
         server_tick: 3,
         position: {31.0, 32.0, 33.0},
         velocity: {0.0, 1.0, 0.0},
         acceleration: {0.0, 0.0, 0.0},
         movement_mode: :grounded
       }}
    )

    assert {:ok,
            <<0x83, 2, 88::64-big, 3::32-big, _server_state_ms_pm3::64-big,
              _server_send_ms_pm3::64-big, 31.0::float-64-big, 32.0::float-64-big,
              33.0::float-64-big, +0.0::float-64-big, 1.0::float-64-big, +0.0::float-64-big,
              +0.0::float-64-big, +0.0::float-64-big, +0.0::float-64-big, 0::8>>} =
             :gen_tcp.recv(client, 0, 500)

    assert {:error, :timeout} = :gen_udp.recv(udp_client, 0, 100)
    :gen_udp.close(udp_client)
  end

  test "closing the tcp session clears the attached udp mapping", %{client: client, pid: pid} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 150))
    assert {:ok, <<0x80, 150::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 151))
    assert {:ok, <<0x84, 151::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, <<0x06, 152::64-big>>)

    assert {:ok,
            <<0x87, 152::64-big, 0x00, udp_port::16-big, tlen::16-big, ticket::binary-size(tlen)>>} =
             :gen_tcp.recv(client, 0, 500)

    {:ok, udp_client} = :gen_udp.open(0, [:binary, active: false])

    assert :ok =
             :gen_udp.send(
               udp_client,
               {127, 0, 0, 1},
               udp_port,
               encode_fast_lane_attach(153, ticket)
             )

    assert {:ok, {{127, 0, 0, 1}, _port, <<0x88, 153::64-big, 0x00>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    monitor = Process.monitor(pid)
    assert :ok = :gen_tcp.close(client)
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 500
    assert reason in [:normal, :noproc]

    wait_until(fn -> GateServer.FastLaneRegistry.session_for_connection(pid) == nil end)
    assert {:error, :timeout} = :gen_udp.recv(udp_client, 0, 100)

    :gen_udp.close(udp_client)
  end

  test "voxel subscription over tcp forwards initial snapshot then ChunkDelta on impact", %{
    client: client,
    pid: pid
  } do
    observe_path = observe_path("tcp_chunk_subscribe_scene_envelope.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()
    put_voxel_region(881, region_id: System.unique_integer([:positive, :monotonic]))

    FakeInterface.set(scene_server: node(), world_server: node())
    put_connection_in_scene(pid)

    assert :ok = :gen_tcp.send(client, encode_chunk_subscribe(201, 881, {0, 0, 0}))

    assert {:ok, <<0x62, initial_payload::binary>>} = :gen_tcp.recv(client, 0, 500)
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.request_id == 201
    assert initial.storage.chunk_version == 0

    assert %{voxel_subscriptions: subscriptions} = :sys.get_state(pid)
    assert Map.has_key?(subscriptions, {881, {0, 0, 0}})

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 881) ==
             %{{0, 0, 0} => 0}

    assert :ok = :gen_tcp.send(client, encode_voxel_impact(202, 301, 881, {8, 16, 24}))

    assert {:ok,
            <<0x68, 202::64-big, 301::32-big, 881::64-big, 0::8, 1::64-big, 0::16-big, 2::16-big,
              "ok">>} = :gen_tcp.recv(client, 0, 500)

    assert {:ok, <<0x63, delta_payload::binary>>} = :gen_tcp.recv(client, 0, 500)
    assert {:ok, delta} = SceneVoxelCodec.decode_chunk_delta_payload(delta_payload)
    assert delta.logical_scene_id == 881
    assert delta.chunk_coord == {0, 0, 0}
    assert delta.base_chunk_version == 0
    assert delta.new_chunk_version == 1
    assert [%{delta_kind: 1, cell_version: 1}] = delta.ops

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 881) ==
             %{{0, 0, 0} => 1}

    GateServer.CliObserve.flush()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_live_delivery_scheduled")
    assert observe_log =~ "frame_kind: :delta"
    assert observe_log =~ "metadata_source: :envelope"
    assert observe_log =~ "payload_decode_used: false"

    assert :ok = :gen_tcp.send(client, encode_debug_probe(203, "voxel_transport"))

    assert {:ok, <<0x6F, 203::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert debug_result =~ "forwarded_chunk_versions=[{881, {0, 0, 0}, 1}]"
  end

  test "voxel chunk ACK over tcp records retained client versions", %{
    client: client,
    pid: pid
  } do
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :forwarded_chunk_versions,
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(893, {0, 0, 0}, 7)
      )
    end)

    assert :ok = :gen_tcp.send(client, encode_chunk_ack(206, 893, [{{0, 0, 0}, 7}]))
    assert {:ok, <<0x80, 206::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 893) ==
             %{{0, 0, 0} => 7}

    assert :ok = :gen_tcp.send(client, encode_debug_probe(207, "voxel_transport"))

    assert {:ok, <<0x6F, 207::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert debug_result =~ "client_ack_versions=[{893, {0, 0, 0}, 7}]"

    assert :ok = :gen_tcp.send(client, encode_chunk_ack(208, 893, [{{0, 0, 0}, 8}]))
    assert {:ok, <<0x80, 208::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 893) ==
             %{{0, 0, 0} => 7}
  end

  test "voxel chunk ACK over tcp ignores chunks with no forwarded cache entry", %{
    client: client,
    pid: pid
  } do
    put_connection_in_scene(pid)

    assert :ok = :gen_tcp.send(client, encode_chunk_ack(209, 893, [{{0, 0, 0}, 0}]))
    assert {:ok, <<0x80, 209::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 893) == %{}
  end

  test "migration cutover invalidate automatically rebinds tcp voxel subscriptions", %{
    client: client,
    pid: pid
  } do
    logical_scene_id = unique_id()
    observe_path = observe_path("tcp_chunk_subscribe_auto_rebind.log")
    File.rm(observe_path)

    {:ok, gate_route} = GateServer.CliObserve.register_route(logical_scene_id, observe_path)
    {:ok, world_route} = WorldServer.CliObserve.register_route(logical_scene_id, observe_path)
    {:ok, scene_route} = SceneServer.CliObserve.register_route(logical_scene_id, observe_path)

    on_exit(fn ->
      GateServer.CliObserve.flush()
      WorldServer.CliObserve.flush()
      SceneServer.CliObserve.flush_path(observe_path)
      configure_map_ledger_scene_invalidator(nil)
      GateServer.CliObserve.unregister_route(logical_scene_id, gate_route)
      WorldServer.CliObserve.unregister_route(logical_scene_id, world_route)
      SceneServer.CliObserve.unregister_route(logical_scene_id, scene_route)
    end)

    ensure_scene_voxel_started()

    ensure_map_ledger_started(
      scene_invalidator:
        AuthorityObserve.scene_directory_invalidator(SceneServer.Voxel.ChunkDirectory)
    )

    region_id = unique_id()
    put_voxel_region(logical_scene_id, region_id: region_id, owner_scene_instance_ref: 7_101)

    FakeInterface.set(scene_server: node(), world_server: node())
    put_connection_in_scene(pid)

    assert :ok = :gen_tcp.send(client, encode_chunk_subscribe(211, logical_scene_id, {0, 0, 0}))

    assert {:ok, <<0x62, initial_payload::binary>>} = :gen_tcp.recv(client, 0, 500)
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.request_id == 211

    assert {:ok, lease_v2} =
             MapLedger.migrate_region(MapLedger, region_id, 8_101,
               lease_id: 91_881,
               owner_epoch: 2,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: unique_id(),
               target_scene_node: node()
             )

    assert {:ok, <<0x69, invalidate_payload::binary>>} = :gen_tcp.recv(client, 0, 500)
    assert {:ok, invalidate} = SceneVoxelCodec.decode_chunk_invalidate_payload(invalidate_payload)
    assert invalidate.reason_name == :migration_cutover
    assert invalidate.logical_scene_id == logical_scene_id
    assert invalidate.chunk_coord == {0, 0, 0}

    assert {:ok, <<0x62, rebound_payload::binary>>} = :gen_tcp.recv(client, 0, 500)
    assert {:ok, rebound} = SceneVoxelCodec.decode_chunk_snapshot_payload(rebound_payload)
    assert rebound.request_id == 211

    assert %{voxel_subscriptions: subscriptions_after} = :sys.get_state(pid)

    assert %{
             region_id: ^region_id,
             lease_id: 91_881,
             owner_scene_instance_ref: 8_101,
             owner_epoch: 2
           } = Map.fetch!(subscriptions_after, {logical_scene_id, {0, 0, 0}})

    assert lease_v2.lease_id == 91_881

    GateServer.CliObserve.flush()
    WorldServer.CliObserve.flush()
    SceneServer.CliObserve.flush_path(observe_path)
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_migration_cutover_invalidate_emitted")
    assert observe_log =~ ~s(event="voxel_chunk_invalidate_forwarded")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_requested")
    assert observe_log =~ ~s(reason: :migration_cutover_invalidate)
    assert observe_log =~ ~s(event="voxel_subscription_rebind_subscribed_new")
    assert observe_log =~ ~s(event="voxel_subscription_rebind_completed")
  end

  test "voxel chunk invalidate clears the forwarded version cache over tcp", %{
    client: client,
    pid: pid
  } do
    put_connection_in_scene(pid)

    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(882, {0, 0, 0}, 7)

    {client_acks, %{status: :ok}} =
      ClientAckLedger.record_known_versions(ClientAckLedger.new(), forwarded, 882, [
        {{0, 0, 0}, 7}
      ])

    :sys.replace_state(pid, fn state ->
      Map.merge(state, %{
        forwarded_chunk_versions: forwarded,
        client_ack_versions: client_acks
      })
    end)

    payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 882,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    send(pid, {:voxel_chunk_invalidate_payload, payload})

    assert {:ok, <<0x69, ^payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 882) ==
             %{}

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 882) == %{}
  end

  test "tcp live voxel delivery queues over-budget snapshots without advancing forwarded versions",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(886, {0, 0, 0}, 1)
    second_payload = snapshot_payload(886, {1, 0, 0}, 1)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_chunk_snapshot_payload, second_payload})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    state = :sys.get_state(pid)

    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 886) ==
             %{{0, 0, 0} => 1}

    assert DeliveryScheduler.summary(state.voxel_delivery).queued_count == 1

    assert :ok = :gen_tcp.send(client, encode_debug_probe(205, "voxel_transport"))

    assert {:ok, <<0x6F, 205::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert debug_result =~ "voxel_delivery_queue_count=1"
    assert debug_result =~ "voxel_delivery_deferred_count=1"
  end

  test "tcp live voxel delivery drains queued data on the real scheduler timer",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(888, {0, 0, 0}, 1)
    second_payload = snapshot_payload(888, {1, 0, 0}, 1)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128,
          window_interval_ms: 20
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_chunk_snapshot_payload, second_payload})
    assert {:ok, <<0x62, ^second_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    state = :sys.get_state(pid)

    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 888) == %{
             {0, 0, 0} => 1,
             {1, 0, 0} => 1
           }

    assert DeliveryScheduler.summary(state.voxel_delivery).queued_count == 0
    assert state.voxel_delivery_timer_ref == nil
  end

  test "tcp object state deltas bypass field backlog as event traffic",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(889, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(889, {0, 0, 0}, 44, 3)

    object_payload =
      object_state_delta_payload(889,
        object_id: 501,
        object_version: 2,
        affected_chunks: [{0, 0, 0}]
      )

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_field_region_snapshot_payload, field_payload})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    send(pid, {:voxel_object_state_delta_payload, object_payload})
    assert {:ok, <<0x6C, ^object_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1
  end

  test "tcp delivery envelopes enter the same live voxel send window",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(892, {0, 0, 0}, 1)
    opaque_field_payload = <<1, 2, 3>>

    :sys.replace_state(pid, fn state ->
      state
      |> put_voxel_test_subscription(892, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
      |> Map.put(
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(opaque_field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_delivery_envelope, field_region_envelope(892, opaque_field_payload)})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    send(pid, :voxel_delivery_window)
    assert {:ok, ^opaque_field_payload} = :gen_tcp.recv(client, 0, 500)
  end

  test "tcp delivery invalidate envelopes forward and clear retained chunk ledgers",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 893,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    :sys.replace_state(pid, fn state ->
      state
      |> put_voxel_test_subscription(893, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
      |> Map.put(
        :forwarded_chunk_versions,
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(893, {0, 0, 0}, 7)
      )
      |> Map.put(
        :client_ack_versions,
        record_test_client_ack(893, {0, 0, 0}, 7)
      )
    end)

    send(pid, {:voxel_delivery_envelope, invalidate_envelope(893, payload)})

    assert {:ok, <<0x69, ^payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    state = :sys.get_state(pid)
    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 893) == %{}
    assert ClientAckLedger.known_versions(state.client_ack_versions, 893) == %{}
    assert DeliveryScheduler.summary(state.voxel_delivery).control_sent_count == 1
  end

  test "tcp rejects delivery envelopes whose lease no longer matches the subscription",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      put_voxel_test_subscription(state, 894, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
    end)

    payload = <<1, 2, 3>>

    send(
      pid,
      {:voxel_delivery_envelope,
       field_region_envelope(894, payload, lease_id: 999, owner_epoch: 2)}
    )

    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    summary = DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "tcp rejects delivery envelopes whose owner epoch no longer matches the subscription",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      put_voxel_test_subscription(state, 895, {0, 0, 0}, lease_id: 101, owner_epoch: 2)
    end)

    payload = <<1, 2, 3>>

    send(
      pid,
      {:voxel_delivery_envelope,
       field_region_envelope(895, payload, lease_id: 101, owner_epoch: 9)}
    )

    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    summary = DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "tcp rejects delivery envelopes whose region no longer matches the subscription",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      put_voxel_test_subscription(state, 896, {0, 0, 0},
        region_id: 45,
        lease_id: 101,
        owner_epoch: 2
      )
    end)

    payload = <<1, 2, 3>>

    send(
      pid,
      {:voxel_delivery_envelope,
       field_region_envelope(896, payload, lease_id: 101, owner_epoch: 2)}
    )

    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    summary = DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "tcp field region snapshots are queued and destroyed messages prune them",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(890, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(890, {0, 0, 0}, 44, 3)
    destroyed_payload = field_region_destroyed_payload(890, {0, 0, 0}, 44)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_field_region_snapshot_payload, field_payload})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    send(pid, {:voxel_field_region_destroyed_payload, destroyed_payload})
    assert {:ok, ^destroyed_payload} = :gen_tcp.recv(client, 0, 500)

    send(pid, :voxel_delivery_window)
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 0
  end

  test "tcp malformed field region destroyed is rejected and does not prune queued snapshots",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(891, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(891, {0, 0, 0}, 44, 3)
    malformed_destroyed_payload = field_region_destroyed_payload(891, {0, 0, 0}, 44) <> <<0xFF>>

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_field_region_snapshot_payload, field_payload})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    send(pid, {:voxel_field_region_destroyed_payload, malformed_destroyed_payload})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    send(pid, :voxel_delivery_window)
    assert {:ok, ^field_payload} = :gen_tcp.recv(client, 0, 500)
  end

  test "tcp chunk invalidate bypasses budget and drops queued live data for the same chunk",
       %{
         client: client,
         pid: pid
       } do
    put_connection_in_scene(pid)

    first_payload = snapshot_payload(887, {0, 0, 0}, 1)

    queued_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 887,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 1,
        new_chunk_version: 2,
        ops: []
      })

    invalidate_payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 887,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :voxel_delivery,
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(queued_payload) + 128,
          window_interval_ms: 1_000
        )
      )
    end)

    send(pid, {:voxel_chunk_snapshot_payload, first_payload})
    assert {:ok, <<0x62, ^first_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, {:voxel_chunk_delta_payload, queued_payload})
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    send(pid, {:voxel_chunk_invalidate_payload, invalidate_payload})
    assert {:ok, <<0x69, ^invalidate_payload::binary>>} = :gen_tcp.recv(client, 0, 500)

    send(pid, :voxel_delivery_window)
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 50)

    state = :sys.get_state(pid)
    assert DeliveryScheduler.summary(state.voxel_delivery).queued_count == 0
    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 887) == %{}
  end

  test "tcp chunk invalidate logs forwarded only after socket send succeeds", %{
    pid: pid
  } do
    observe_path = observe_path("tcp_invalidate_send_failure.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    put_connection_in_scene(pid)

    payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 892,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    :sys.replace_state(pid, fn state ->
      forwarded =
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(892, {0, 0, 0}, 7)

      {client_acks, %{status: :ok}} =
        ClientAckLedger.record_known_versions(ClientAckLedger.new(), forwarded, 892, [
          {{0, 0, 0}, 7}
        ])

      %{
        state
        | socket: :not_a_tcp_socket,
          forwarded_chunk_versions: forwarded,
          client_ack_versions: client_acks,
          voxel_delivery: %{
            DeliveryScheduler.new()
            | resync_required_chunks: MapSet.new([{892, {0, 0, 0}}])
          }
      }
    end)

    send(pid, {:voxel_chunk_invalidate_payload, payload})

    eventually(fn ->
      log = File.read!(observe_path)
      assert log =~ ~s(event="voxel_live_delivery_send_failed")
      refute log =~ ~s(event="voxel_chunk_invalidate_forwarded")
    end)

    assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 892) ==
             %{{0, 0, 0} => 7}

    assert ClientAckLedger.known_versions(:sys.get_state(pid).client_ack_versions, 892) ==
             %{{0, 0, 0} => 7}

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).resync_required_count ==
             1
  end

  test "voxel chunk unsubscribe clears the forwarded version cache over tcp", %{
    client: client,
    pid: pid
  } do
    state =
      :sys.replace_state(pid, fn state ->
        Map.merge(state, %{
          status: :in_scene,
          cid: 42,
          forwarded_chunk_versions:
            ChunkVersionLedger.new()
            |> ChunkVersionLedger.record_version!(884, {0, 0, 0}, 7),
          voxel_subscriptions: %{
            {884, {0, 0, 0}} => %{
              logical_scene_id: 884,
              chunk_coord: {0, 0, 0},
              scene_node: node()
            }
          }
        })
      end)

    assert ChunkVersionLedger.known_versions(state.forwarded_chunk_versions, 884) ==
             %{{0, 0, 0} => 7}

    first_payload = snapshot_payload(884, {0, 0, 0}, 8)

    queued_payload =
      SceneVoxelCodec.encode_chunk_delta_payload(%{
        logical_scene_id: 884,
        chunk_coord: {0, 0, 0},
        base_chunk_version: 8,
        new_chunk_version: 9,
        ops: []
      })

    :sys.replace_state(pid, fn state ->
      scheduler =
        DeliveryScheduler.new(
          max_window_bytes: byte_size(first_payload) + 1,
          max_queue_items: 8,
          max_queue_bytes: byte_size(first_payload) + byte_size(queued_payload) + 128,
          window_interval_ms: 1_000
        )

      {scheduler, %{action: :send_now}} =
        DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

      {scheduler, %{action: :queued}} =
        DeliveryScheduler.offer(scheduler, :delta, queued_payload)

      Map.put(state, :voxel_delivery, scheduler)
    end)

    assert DeliveryScheduler.summary(:sys.get_state(pid).voxel_delivery).queued_count == 1

    assert :ok = :gen_tcp.send(client, encode_chunk_unsubscribe(204, 884, [{0, 0, 0}]))

    assert {:ok, <<0x80, 204::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    next_state = :sys.get_state(pid)

    assert ChunkVersionLedger.known_versions(next_state.forwarded_chunk_versions, 884) ==
             %{}

    assert DeliveryScheduler.summary(next_state.voxel_delivery).queued_count == 0
  end

  test "malformed voxel payloads still forward unchanged and keep tcp cache unchanged", %{
    client: client,
    pid: pid
  } do
    observe_path = observe_path("tcp_malformed_voxel_forwarding.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    put_connection_in_scene(pid)

    :sys.replace_state(pid, fn state ->
      Map.put(
        state,
        :forwarded_chunk_versions,
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(885, {0, 0, 0}, 7)
      )
    end)

    expected = %{{0, 0, 0} => 7}

    for {opcode, message} <- [
          {0x62, {:voxel_chunk_snapshot_payload, <<1, 2, 3>>}},
          {0x63, {:voxel_chunk_delta_payload, <<4, 5, 6>>}},
          {0x69, {:voxel_chunk_invalidate_payload, <<7, 8, 9>>}}
        ] do
      send(pid, message)
      assert {:ok, <<^opcode, _payload::binary>>} = :gen_tcp.recv(client, 0, 500)

      assert ChunkVersionLedger.known_versions(:sys.get_state(pid).forwarded_chunk_versions, 885) ==
               expected
    end

    GateServer.CliObserve.flush()
    observe_log = File.read!(observe_path)
    assert observe_log =~ "status: :decode_failed"
    assert observe_log =~ "frame_kind: :snapshot"
    assert observe_log =~ "frame_kind: :delta"
    assert observe_log =~ "frame_kind: :invalidate"
  end

  test "voxel subscription over tcp skips missing halo chunks", %{
    client: client,
    pid: pid
  } do
    observe_path = observe_path("tcp_chunk_subscribe_partition_window.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    ensure_scene_voxel_started()
    put_voxel_region(882, region_id: System.unique_integer([:positive, :monotonic]))

    FakeInterface.set(scene_server: node(), world_server: node())
    put_connection_in_scene(pid)

    assert :ok = :gen_tcp.send(client, encode_chunk_subscribe(211, 882, {0, 0, 0}, 1))

    assert {:ok, <<0x62, initial_payload::binary>>} = :gen_tcp.recv(client, 0, 500)
    assert {:ok, initial} = SceneVoxelCodec.decode_chunk_snapshot_payload(initial_payload)
    assert initial.request_id == 211
    assert initial.storage.logical_scene_id == 882
    assert initial.storage.chunk_coord == {0, 0, 0}

    assert %{voxel_subscriptions: subscriptions, voxel_subscription_plan: plan} =
             :sys.get_state(pid)

    assert Map.keys(subscriptions) == [{882, {0, 0, 0}}]
    assert plan.subscribe_count == 1
    assert plan.missing_chunk_count == 26

    GateServer.CliObserve.flush()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_subscription_window_planned")
    assert observe_log =~ "requested_chunk_count: 27"
    assert observe_log =~ "near_radius: 0"
    assert observe_log =~ "halo_radius: 1"
    assert observe_log =~ "near_vertical_radius: 0"
    assert observe_log =~ "halo_vertical_radius: 1"
    assert observe_log =~ "subscribe_count: 1"
    assert observe_log =~ "subscribed_chunk_count: 1"
    assert observe_log =~ "missing_chunk_count: 26"

    assert :ok = :gen_tcp.send(client, encode_debug_probe(213, "voxel_transport"))

    assert {:ok, <<0x6F, 213::64-big, debug_len::16-big, debug_result::binary-size(debug_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert debug_result =~ "voxel_subscription_plan_center_chunk={0, 0, 0}"
    assert debug_result =~ "voxel_subscription_plan_near_radius=0"
    assert debug_result =~ "voxel_subscription_plan_halo_radius=1"
    assert debug_result =~ "voxel_subscription_plan_near_vertical_radius=0"
    assert debug_result =~ "voxel_subscription_plan_halo_vertical_radius=1"
  end

  test "voxel subscription over tcp rejects a client scene outside the authoritative partition context",
       %{
         client: client,
         pid: pid
       } do
    ensure_map_ledger_started()
    ensure_scene_voxel_started()

    allowed_scene_id = unique_id()
    forged_scene_id = unique_id()
    allowed_region_id = unique_id()
    forged_region_id = unique_id()

    put_partition_region(allowed_scene_id, allowed_region_id, {0, 0, 0}, {1, 1, 1}, 80_001)
    put_partition_region(forged_scene_id, forged_region_id, {0, 0, 0}, {1, 1, 1}, 80_002)

    FakeInterface.set(scene_server: node(), world_server: node())

    :sys.replace_state(pid, fn state ->
      %{
        state
        | status: :in_scene,
          cid: 42,
          partition_context: %{
            logical_scene_id: allowed_scene_id,
            region_id: allowed_region_id,
            chunk_coord: {0, 0, 0}
          }
      }
    end)

    _ = :sys.get_state(pid)

    assert :ok = :gen_tcp.send(client, encode_chunk_subscribe(214, forged_scene_id, {0, 0, 0}))

    assert {:ok,
            <<0x68, 214::64-big, 0::32-big, got_scene_id::64-big, 2::8, 0::64-big, 0::16-big,
              reason_len::16-big, reason::binary-size(reason_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert got_scene_id == forged_scene_id
    assert reason == ":unauthorized_voxel_target"
  end

  test "missing center subscription over tcp still logs the plan", %{
    client: client,
    pid: pid
  } do
    observe_path = observe_path("tcp_chunk_subscribe_missing_center_plan.log")
    File.rm(observe_path)
    Application.put_env(:gate_server, :cli_observe_log, observe_path)

    ensure_map_ledger_started()
    FakeInterface.set(scene_server: node(), world_server: node())
    put_connection_in_scene(pid)

    assert :ok = :gen_tcp.send(client, encode_chunk_subscribe(212, 883, {1234, 0, 0}, 0))

    assert {:ok,
            <<0x68, 212::64-big, 0::32-big, 883::64-big, 2::8, 0::64-big, 0::16-big,
              reason_len::16-big, reason::binary-size(reason_len)>>} =
             :gen_tcp.recv(client, 0, 500)

    assert reason == ":unassigned_chunk"

    GateServer.CliObserve.flush()
    observe_log = File.read!(observe_path)
    assert observe_log =~ ~s(event="voxel_subscription_window_planned")
    assert observe_log =~ "requested_chunk_count: 1"
    assert observe_log =~ "missing_chunk_count: 1"
    assert observe_log =~ "skipped_count: 1"
  end

  test "malformed payload fails closed with generic error reply", %{client: client} do
    log =
      capture_log([level: :warning], fn ->
        assert :ok = :gen_tcp.send(client, <<0xFF>>)
        assert {:ok, <<0x80, 0::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
      end)

    assert log == ""
  end

  test "tcp_error before scene join terminates cleanly", %{pid: pid, server: server} do
    log =
      capture_log([level: :warning], fn ->
        monitor = Process.monitor(pid)
        send(pid, {:tcp_error, server, :econnreset})

        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
      end)

    assert log == ""
  end

  defp encode_auth_request(username, code, request_id) do
    <<0x05, request_id::64-big, byte_size(username)::16-big, username::binary,
      byte_size(code)::16-big, code::binary>>
  end

  defp encode_enter_scene(cid, request_id) do
    <<0x02, request_id::64-big, cid::64-big>>
  end

  defp encode_movement_input(
         seq,
         client_tick,
         {dir_x, dir_y},
         dt_ms \\ 100,
         speed_scale \\ 1.0,
         movement_flags \\ 0
       ) do
    <<0x01, 2, seq::32-big, client_tick::32-big, dt_ms::16-big, dir_x::float-32-big,
      dir_y::float-32-big, speed_scale::float-32-big, movement_flags::16-big>>
  end

  defp encode_time_sync(request_id, client_send_ts) do
    <<0x03, request_id::64-big, client_send_ts::64-big>>
  end

  defp encode_chat_say(request_id, text) do
    <<0x08, request_id::64-big, byte_size(text)::16-big, text::binary>>
  end

  defp encode_scoped_chat_say(request_id, scope, text) do
    <<0x0A, request_id::64-big, encode_chat_scope(scope)::8, byte_size(text)::16-big,
      text::binary>>
  end

  defp encode_chat_scope(:world), do: 0
  defp encode_chat_scope(:region), do: 1
  defp encode_chat_scope(:local), do: 2

  defp restore_local_chat_radius({:ok, value}),
    do: Application.put_env(:gate_server, :local_chat_radius, value)

  defp restore_local_chat_radius(:error),
    do: Application.delete_env(:gate_server, :local_chat_radius)

  defp encode_skill_cast(request_id, skill_id) do
    <<0x09, request_id::64-big, skill_id::16-big, 0::8, -1::64-big-signed, 0.0::float-64-big,
      0.0::float-64-big, 0.0::float-64-big>>
  end

  defp encode_fast_lane_attach(request_id, ticket) do
    <<0x07, request_id::64-big, byte_size(ticket)::16-big, ticket::binary>>
  end

  defp encode_chunk_subscribe(request_id, logical_scene_id, {cx, cy, cz}, radius \\ 0) do
    <<0x60, request_id::64-big, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed,
      cz::32-big-signed, radius::8, 1::8, 0::16-big>>
  end

  defp encode_chunk_unsubscribe(request_id, logical_scene_id, chunks) do
    coords =
      Enum.map(chunks, fn {cx, cy, cz} ->
        <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed>>
      end)

    [<<0x61, request_id::64-big, logical_scene_id::64-big, length(chunks)::16-big>>, coords]
  end

  defp encode_debug_probe(request_id, command) do
    <<0x6F, request_id::64-big, byte_size(command)::16-big, command::binary>>
  end

  defp encode_chunk_ack(request_id, logical_scene_id, acks) do
    [
      <<0x76, request_id::64-big, logical_scene_id::64-big, length(acks)::16-big>>,
      Enum.map(acks, fn {{cx, cy, cz}, chunk_version} ->
        <<cx::32-big-signed, cy::32-big-signed, cz::32-big-signed, chunk_version::64-big>>
      end)
    ]
  end

  defp encode_voxel_impact(request_id, client_intent_seq, logical_scene_id, {x, y, z}) do
    <<0x64, request_id::64-big, client_intent_seq::32-big, logical_scene_id::64-big, 1::32-big,
      x::64-big-signed, y::64-big-signed, z::64-big-signed, 2::16-big, 0::64-big>>
  end

  defp snapshot_payload(logical_scene_id, chunk_coord, chunk_version) do
    storage = Storage.empty(logical_scene_id, chunk_coord, chunk_version: chunk_version)
    SceneVoxelCodec.encode_chunk_snapshot_payload(%{request_id: 101, storage: storage})
  end

  defp object_state_delta_payload(logical_scene_id, opts) do
    SceneVoxelCodec.encode_voxel_object_state_delta_payload(%{
      logical_scene_id: logical_scene_id,
      object_id: Keyword.fetch!(opts, :object_id),
      object_version: Keyword.fetch!(opts, :object_version),
      state_flags: Keyword.get(opts, :state_flags, 0x01),
      affected_chunks: Keyword.fetch!(opts, :affected_chunks)
    })
  end

  defp field_region_snapshot_payload(logical_scene_id, {cx, cy, cz}, region_id, tick_count) do
    <<0x73, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed, cz::32-big-signed,
      region_id::64-big, tick_count::32-big, 0::8, 0::16-big>>
  end

  defp field_region_envelope(logical_scene_id, payload, opts \\ []) do
    %{
      frame_kind: :field_region_snapshot,
      logical_scene_id: logical_scene_id,
      chunk_coord: {0, 0, 0},
      region_id: 44,
      tick_count: 3,
      tier: :halo,
      stream_class: :field_state,
      byte_size: byte_size(payload),
      server_version: 12,
      lease_id: Keyword.get(opts, :lease_id, 101),
      owner_epoch: Keyword.get(opts, :owner_epoch, 2),
      payload: payload
    }
  end

  defp invalidate_envelope(logical_scene_id, payload) do
    %{
      frame_kind: :invalidate,
      logical_scene_id: logical_scene_id,
      chunk_coord: {0, 0, 0},
      tier: :near,
      stream_class: :reliable_control,
      byte_size: byte_size(payload),
      server_version: 8,
      lease_id: 101,
      owner_epoch: 2,
      reason: 0x01,
      reason_name: :lease_revoked,
      payload: payload
    }
  end

  defp put_voxel_test_subscription(state, logical_scene_id, chunk_coord, opts) do
    Map.update!(state, :voxel_subscriptions, fn subscriptions ->
      Map.put(subscriptions, {logical_scene_id, chunk_coord}, %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        region_id: Keyword.get(opts, :region_id, 44),
        lease_id: Keyword.fetch!(opts, :lease_id),
        owner_epoch: Keyword.fetch!(opts, :owner_epoch),
        tier: Keyword.get(opts, :tier, :halo),
        scene_node: node()
      })
    end)
  end

  defp record_test_client_ack(logical_scene_id, chunk_coord, version) do
    forwarded =
      ChunkVersionLedger.new()
      |> ChunkVersionLedger.record_version!(logical_scene_id, chunk_coord, version)

    {:ok, ledger, _event} =
      ClientAckLedger.record_ack(
        ClientAckLedger.new(),
        forwarded,
        logical_scene_id,
        chunk_coord,
        version
      )

    ledger
  end

  defp field_region_destroyed_payload(logical_scene_id, {cx, cy, cz}, region_id) do
    <<0x74, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed, cz::32-big-signed,
      region_id::64-big, 0::8>>
  end

  defp put_connection_in_scene(pid) do
    :sys.replace_state(pid, fn state -> %{state | status: :in_scene, cid: 42} end)
    _ = :sys.get_state(pid)
    :ok
  end

  defp join_chat_session(connection_pid, cid, username, logical_scene_id, region_id, chunk_coord) do
    assert {:ok, _} =
             ChatAdapter.join(%{
               cid: cid,
               username: username,
               connection_pid: connection_pid,
               logical_scene_id: logical_scene_id,
               region_id: region_id,
               chunk_coord: chunk_coord,
               location: {0.0, 0.0, 0.0}
             })
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError, File.Error] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        eventually(fun, attempts - 1)
      end
  end

  defp observe_path(name) do
    dir = Path.expand("../../../../.demo/observe", __DIR__)
    File.mkdir_p!(dir)
    Path.join(dir, name)
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)

  defp ensure_map_ledger_started(opts \\ []) do
    ensure_data_voxel_started()

    case Process.whereis(MapLedger) do
      nil ->
        start_supervised!(
          {MapLedger, name: MapLedger, write_token_store: DataService.Voxel.WriteTokenStore}
        )

      _pid ->
        :ok
    end

    configure_map_ledger_scene_invalidator(Keyword.get(opts, :scene_invalidator))
  end

  defp configure_map_ledger_scene_invalidator(invalidator)
       when is_nil(invalidator) or is_function(invalidator, 1) do
    case Process.whereis(MapLedger) do
      nil ->
        :ok

      pid ->
        :sys.replace_state(pid, fn state -> %{state | scene_invalidator: invalidator} end)
        :ok
    end
  end

  defp ensure_scene_voxel_started do
    ensure_data_voxel_started()

    if is_nil(Process.whereis(SceneServer.CliObserve.Manager)) do
      start_supervised!({SceneServer.CliObserve.Manager, []})
    end

    # 阶段3.1：`mix test --no-start` 下 :scene_server application 不启动，全局
    # chunk 进程身份注册表需在此显式拉起，否则 ChunkDirectory 经 ChunkRegistry.lookup
    # 解析 pid 时会 `unknown registry`。必须早于 VoxelChunkSup。
    if is_nil(Process.whereis(SceneServer.Voxel.ChunkRegistry)) do
      start_supervised!(
        {Registry, keys: :unique, name: SceneServer.Voxel.ChunkRegistry},
        id: SceneServer.Voxel.ChunkRegistry
      )
    end

    if is_nil(Process.whereis(SceneServer.VoxelChunkSup)) do
      start_supervised!({SceneServer.VoxelChunkSup, name: SceneServer.VoxelChunkSup})
    end

    if is_nil(Process.whereis(SceneServer.Voxel.ChunkDirectory)) do
      start_supervised!(
        {SceneServer.Voxel.ChunkDirectory,
         name: SceneServer.Voxel.ChunkDirectory, chunk_sup: SceneServer.VoxelChunkSup}
      )
    end

    :ok
  end

  defp put_voxel_region(logical_scene_id, opts) do
    region_id = Keyword.fetch!(opts, :region_id)
    owner_scene_instance_ref = Keyword.get(opts, :owner_scene_instance_ref, 7_001)

    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: owner_scene_instance_ref,
               owner_epoch: 0,
               assigned_scene_node: Keyword.get(opts, :assigned_scene_node, node())
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, owner_scene_instance_ref,
               lease_id: System.unique_integer([:positive, :monotonic]),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: System.unique_integer([:positive, :monotonic])
             )
  end

  defp put_partition_region(logical_scene_id, region_id, bounds_min, bounds_max, owner_ref) do
    assert {:ok, _assignment} =
             MapLedger.put_region(MapLedger, %{
               region_id: region_id,
               logical_scene_id: logical_scene_id,
               bounds_chunk_min: bounds_min,
               bounds_chunk_max: bounds_max,
               owner_scene_instance_ref: owner_ref,
               owner_epoch: 0,
               assigned_scene_node: node()
             })

    assert {:ok, _lease} =
             MapLedger.issue_lease(MapLedger, region_id, owner_ref,
               lease_id: unique_id(),
               owner_epoch: 1,
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: unique_id()
             )
  end

  defp ack(overrides) do
    attrs =
      Map.merge(
        %{
          cid: 42,
          ack_seq: 1,
          auth_tick: 1,
          position: {0.0, 0.0, 0.0},
          velocity: {0.0, 0.0, 0.0},
          acceleration: {0.0, 0.0, 0.0},
          movement_mode: :grounded,
          correction_flags: 0,
          fixed_dt_ms: 50,
          ground_z: 0.0
        },
        overrides
      )

    struct!(Ack, attrs)
  end

  defp blocking_partition_refresh_fun(parent) do
    fn _state, ack, opts ->
      connection_pid = Keyword.fetch!(opts, :connection_pid)
      subscriber = Keyword.fetch!(opts, :subscriber)
      send(parent, {:partition_refresh_started, self(), connection_pid, subscriber})

      receive do
        :release_partition_refresh ->
          outcome = %{
            status: :updated,
            cid: ack.cid,
            logical_scene_id: 701,
            boundary_kind: :region,
            previous_region_id: 10,
            region_id: 20,
            previous_chunk_coord: {0, 0, 0},
            chunk_coord: {1, 0, 0},
            auth_tick: ack.auth_tick,
            ack_seq: ack.ack_seq,
            subscription_apply_status: :ok
          }

          {:ok, %{kind: :last_refresh, outcome: outcome, status: :ok}}
      end
    end
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp ensure_data_voxel_started do
    if is_nil(Process.whereis(DataService.Voxel.WriteTokenStore)) do
      start_supervised!(
        {DataService.Voxel.WriteTokenStore, name: DataService.Voxel.WriteTokenStore}
      )
    end

    # Phase 1d: ChunkSnapshotStore is a stateless module backed by
    # `DataService.Repo`; the test_helper boots the Repo, so there is
    # nothing else to start here.

    :ok
  end

  defp ensure_repo_started do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    wait_until(fn -> is_pid(Process.whereis(DataService.Repo)) end, 100)
  end

  defp ensure_name_available(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        wait_until_unregistered(name, 20)
    end
  end

  defp wait_until_unregistered(_name, 0), do: :ok

  defp wait_until_unregistered(name, attempts) do
    case Process.whereis(name) do
      nil ->
        :ok

      _pid ->
        Process.sleep(10)
        wait_until_unregistered(name, attempts - 1)
    end
  end

  defp wait_until(fun, attempts \\ 30)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp insert_account_and_character(username, cid, opts \\ []) do
    position = Keyword.get(opts, :position, %{"x" => 10.0, "y" => 20.0, "z" => 30.0})

    {:ok, account} =
      Repo.insert(%Account{
        id: System.unique_integer([:positive]),
        username: username,
        password: "pw",
        salt: "salt"
      })

    {:ok, _character} =
      Repo.insert(%Character{
        id: cid,
        account: account.id,
        name: "#{username}-character-#{cid}",
        position: position
      })
  end
end
