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
         notify: Map.get(opts, :notify)
       }}
    end

    @impl true
    def handle_call(:get_location, _from, state) do
      {:reply, {:ok, state.location}, state}
    end

    @impl true
    def handle_call({:movement, _timestamp, location, _velocity, _acceleration}, _from, state) do
      {:reply, {:ok, ""}, %{state | location: location}}
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
           location: {10.0, 20.0, 30.0}
         },
         attrs
       )}
    end

    @impl true
    def handle_call({:set, attrs}, _from, state) do
      {:reply, :ok, Map.merge(state, attrs)}
    end

    @impl true
    def handle_call({:add_player, _cid, _connection_pid, _timestamp}, _from, state) do
      case state.add_player_result do
        :ok ->
          {:ok, pid} = FakePlayer.start_link(location: state.location, notify: self())
          {:reply, {:ok, pid}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
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
    end

    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    migrations_path = Path.expand("../../../../data_service/priv/repo/migrations", __DIR__)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    _ = start_supervised({GateServer.FastLaneRegistry, name: GateServer.FastLaneRegistry})
    _ = start_supervised({GateServer.UdpAcceptor, name: GateServer.UdpAcceptor, port: 0})
    _ = start_supervised(FakeInterface)
    _ = start_supervised(FakePlayerManager)
    :ok
  end

  setup do
    case DataService.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Repo.delete_all(Character)
    Repo.delete_all(Account)
    FakeInterface.set(auth_server: nil, scene_server: nil)
    FakePlayerManager.set(add_player_result: :ok, location: {10.0, 20.0, 30.0})

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
    assert :ok = :gen_tcp.send(client, encode_request_movement(2, 42, 100, {1.0, 2.0, 3.0}))
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

    assert :ok = :gen_tcp.send(client, encode_request_movement(22, 42, 100, {1.0, 2.0, 3.0}))
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

    sup = Process.whereis(DataService.DispatcherSup)
    assert is_pid(sup)
    Process.exit(sup, :kill)
    Process.sleep(50)

    on_exit(fn ->
      case DataService.DispatcherSup.start_link(name: DataService.DispatcherSup) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

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

  test "request-id-aware movement echoes packet_id after scene join", %{client: client} do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

    token =
      "tester"
      |> AuthServer.AuthWorker.build_session_claims()
      |> AuthServer.AuthWorker.issue_token()

    assert :ok = :gen_tcp.send(client, encode_auth_request("tester", token, 71))
    assert {:ok, <<0x80, 71::64-big, 0x00>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_enter_scene(42, 72))
    assert {:ok, <<0x84, 72::64-big, 0x00, _::binary>>} = :gen_tcp.recv(client, 0, 500)

    assert :ok = :gen_tcp.send(client, encode_request_movement(73, 42, 100, {4.0, 5.0, 6.0}))

    assert {:ok,
            <<0x80, 73::64-big, 0x00, 42::64-big, 4.0::float-64-big, 5.0::float-64-big,
              6.0::float-64-big>>} = :gen_tcp.recv(client, 0, 500)
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

  test "attached udp peer can send movement uplink and receive movement_result ack", %{
    client: client
  } do
    insert_account_and_character("tester", 42)
    FakeInterface.set(auth_server: node(), scene_server: node())

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

    movement =
      <<0x01, 114::64-big, 42::64-big, 200::64-big, 7.0::float-64-big, 8.0::float-64-big,
        9.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
        0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big>>

    assert :ok = :gen_udp.send(udp_client, {127, 0, 0, 1}, udp_port, movement)

    assert {:ok,
            {{127, 0, 0, 1}, _port,
             <<0x80, 114::64-big, 0x00, 42::64-big, 7.0::float-64-big, 8.0::float-64-big,
               9.0::float-64-big>>}} = :gen_udp.recv(udp_client, 0, 500)

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

  defp encode_request_movement(request_id, cid, timestamp, {x, y, z}) do
    <<0x01, request_id::64-big, cid::64-big, timestamp::64-big, x::float-64-big, y::float-64-big,
      z::float-64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big, 0.0::float-64-big,
      0.0::float-64-big, 0.0::float-64-big>>
  end

  defp encode_time_sync(request_id, client_send_ts) do
    <<0x03, request_id::64-big, client_send_ts::64-big>>
  end

  defp encode_fast_lane_attach(request_id, ticket) do
    <<0x07, request_id::64-big, byte_size(ticket)::16-big, ticket::binary>>
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
        name: "#{username}-character-#{cid}"
      })
  end
end
