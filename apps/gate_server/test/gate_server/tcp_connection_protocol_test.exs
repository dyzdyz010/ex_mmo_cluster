defmodule GateServer.TcpConnectionProtocolTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.Account
  alias DataService.Schema.Character

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
      {:ok, Map.merge(%{auth_server: nil, scene_server: nil}, attrs)}
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
        correction_flags: 0
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

  defmodule FakeAuthInterface do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, Map.new(opts), name: AuthServer.Interface)
    end

    @impl true
    def init(attrs) do
      {:ok, Map.merge(%{data_service: nil}, attrs)}
    end

    @impl true
    def handle_call(:data_service, _from, state) do
      {:reply, state.data_service, state}
    end
  end

  setup_all do
    _ = Application.stop(:gate_server)
    _ = Application.stop(:scene_server)
    ensure_name_available(GateServer.Interface)
    ensure_name_available(SceneServer.PlayerManager)
    ensure_name_available(GateServer.FastLaneRegistry)
    ensure_name_available(GateServer.UdpAcceptor)
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

    migrations_path = Path.expand("../../../../data_service/priv/repo/migrations", __DIR__)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    ensure_dispatcher_sup()

    _ =
      start_supervised(
        {GateServer.FastLaneRegistry,
         name: GateServer.FastLaneRegistry, session_idle_timeout_ms: 250}
      )

    _ = start_supervised({GateServer.UdpAcceptor, name: GateServer.UdpAcceptor, port: 0})
    _ = start_supervised(FakeInterface)
    _ = start_supervised(FakePlayerManager)
    :ok
  end

  setup do
    ensure_repo_started()
    ensure_dispatcher_sup()

    Repo.delete_all(Character)
    Repo.delete_all(Account)
    FakeInterface.set(auth_server: nil, scene_server: nil)

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

    assert {:ok, <<0x84, 12::64-big, 0x00, x::float-64-big, y::float-64-big, z::float-64-big>>} =
             :gen_tcp.recv(client, 0, 500)

    assert {x, y, z} == {10.0, 20.0, 30.0}
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

    _ = start_supervised(FakeAuthInterface)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 44))
    assert {:ok, <<0x84, 44::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
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
    client: client
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

    assert {:ok,
            <<0x8B, 73::32-big, 100::32-big, 42::64-big, 8.0::float-64-big, 9.0::float-64-big,
              10.0::float-64-big, _::binary>>} = :gen_tcp.recv(client, 0, 500)
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

  test "chat in_scene is forwarded to player process and acked", %{client: client} do
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
    assert_receive {:chat_say, 42, "tester", "hello world"}, 500
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
    client: client
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

    assert {:ok,
            {{127, 0, 0, 1}, _port,
             <<0x8B, 114::32-big, 200::32-big, 42::64-big, 17.0::float-64-big, 18.0::float-64-big,
               19.0::float-64-big, _::binary>>}} =
             :gen_udp.recv(udp_client, 0, 500)

    :gen_udp.close(udp_client)
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
             <<0x83, 77::64-big, 9::32-big, 11.0::float-64-big, 12.0::float-64-big,
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
             <<0x83, 77::64-big, 10::32-big, 21.0::float-64-big, 22.0::float-64-big,
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
            <<0x83, 88::64-big, 3::32-big, 31.0::float-64-big, 32.0::float-64-big,
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
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500

    wait_until(fn -> GateServer.FastLaneRegistry.session_for_connection(pid) == nil end)
    assert {:error, :timeout} = :gen_udp.recv(udp_client, 0, 100)

    :gen_udp.close(udp_client)
  end

  test "malformed payload fails closed with generic error reply", %{client: client} do
    assert :ok = :gen_tcp.send(client, <<0xFF>>)
    assert {:ok, <<0x80, 0::64-big, 0x01>>} = :gen_tcp.recv(client, 0, 500)
  end

  test "tcp_error before scene join terminates cleanly", %{pid: pid, server: server} do
    monitor = Process.monitor(pid)
    send(pid, {:tcp_error, server, :econnreset})

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
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
    <<0x01, seq::32-big, client_tick::32-big, dt_ms::16-big, dir_x::float-32-big,
      dir_y::float-32-big, speed_scale::float-32-big, movement_flags::16-big>>
  end

  defp encode_time_sync(request_id, client_send_ts) do
    <<0x03, request_id::64-big, client_send_ts::64-big>>
  end

  defp encode_chat_say(request_id, text) do
    <<0x08, request_id::64-big, byte_size(text)::16-big, text::binary>>
  end

  defp encode_skill_cast(request_id, skill_id) do
    <<0x09, request_id::64-big, skill_id::16-big, 0::8, -1::64-big-signed, 0.0::float-64-big,
      0.0::float-64-big, 0.0::float-64-big>>
  end

  defp encode_fast_lane_attach(request_id, ticket) do
    <<0x07, request_id::64-big, byte_size(ticket)::16-big, ticket::binary>>
  end

  defp ensure_repo_started do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    wait_until(fn -> is_pid(Process.whereis(DataService.Repo)) end, 100)
  end

  defp ensure_dispatcher_sup do
    case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    wait_until(fn -> is_pid(Process.whereis(DataService.Dispatcher)) end, 100)
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

  defp insert_account_and_character(username, cid) do
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
        position: %{"x" => 10.0, "y" => 20.0, "z" => 30.0}
      })
  end
end
