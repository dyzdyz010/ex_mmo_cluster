
defmodule T1Auth do
  def verify_token("valid"), do: {:ok, %{username: "one", cid: 101}}
  def verify_token(_), do: {:error, :mismatch}
  def validate_username(%{username: username}, username), do: :ok
  def validate_username(_, _), do: {:error, :mismatch}
  def authorize_cid(%{cid: cid}, cid), do: :ok
  def authorize_cid(_, _), do: {:error, :cid_mismatch}
  def fetch_authorized_character(%{cid: cid}, cid), do: {:ok, %{id: cid}}
  def fetch_authorized_character(_, _), do: {:error, :cid_mismatch}
end

defmodule T1Route do
  def route(1), do: {:ok, %{scene_ref: Process.whereis(T1Scene), world_ref: :unused, scene_epoch: 7}}
end

defmodule T1Scene do
  use GenServer
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)
  def init(owner), do: {:ok, owner}
  def join(ref, identity, character, sink), do: GenServer.cast(ref, {:join, identity, character, sink})
  def ready(ref, identity, n, r), do: GenServer.cast(ref, {:ready, identity, n, r})
  def input(ref, identity, batch), do: GenServer.cast(ref, {:input, identity, batch})
  def leave(ref, identity), do: GenServer.cast(ref, {:leave, identity})
  def handle_cast(message, owner) do
    send(owner, message)
    {:noreply, owner}
  end
end

defmodule T1TransportTest do
  use ExUnit.Case, async: false

  alias MmoContracts.Session

  setup do
    {:ok, _} = Application.ensure_all_started(:quicer)
    hello = %Session.Hello{protocol_version: 1, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    certs = "/home/dyz/.cache/voxim-m1-t1/certs-v1/"
    start_supervised!({T1Scene, self()})
    listener = start_supervised!({GateServer.Transport.QuicListener,
      [port: 25443, certfile: certs <> "server.pem", keyfile: certs <> "server.key", hello: hello,
       auth_module: T1Auth, route_module: T1Route, scene_module: T1Scene]})
    {:ok, conn} = :quicer.connect(~c"localhost", 25443,
      [alpn: [~c"voxim-m1"], verify: :verify_peer, cacertfile: String.to_charlist(certs <> "ca.pem"),
       peer_bidi_stream_count: 2, datagram_receive_enabled: 1], 5000)
    on_exit(fn -> :quicer.async_shutdown_connection(conn, 0, 0) end)
    %{listener: listener, conn: conn, hello: hello}
  end

  defp control(conn, hello, cid \\ 101) do
    {:ok, stream} = :quicer.start_stream(conn, [{:active, true}])
    {:ok, hello_bytes} = Session.Codec.encode(hello)
    {:ok, join_bytes} = Session.Codec.encode(%Session.Join{request_id: 1, username: "one", token: "valid", cid: cid, scene_id: 1})
    hello_bytes = IO.iodata_to_binary(hello_bytes)
    join_bytes = IO.iodata_to_binary(join_bytes)
    {:ok, _} = :quicer.async_send(stream, <<1, byte_size(hello_bytes)::32, hello_bytes::binary,
      byte_size(join_bytes)::32, join_bytes::binary>>, 0)
    stream
  end

  test "authorized join has Gate identity; wrong cid never reaches Scene", %{conn: conn, hello: hello} do
    control(conn, hello, 202)
    assert_receive {:quic, :shutdown, ^conn, 0x1000D}, 5000
    refute_receive {:join, _, _, _}
  end

  test "voxel sink order survives messages queued before second stream opens", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, %{id: 101}, sink}, 5000
    assert identity.scene_id == 1 and identity.scene_epoch == 7 and identity.session_epoch > 0
    fence = %MmoContracts.Voxel.TimelineFence{identity: identity, server_tick: 10, transaction_seq: 20, collision_revision: 1}
    send(sink, {:mmo_reliable, identity, 2, fence})
    send(sink, {:mmo_reliable, identity, 2, %{fence | server_tick: 11}})
    {:ok, voxel} = :quicer.start_stream(conn, [{:active, true}])
    {:ok, _} = :quicer.async_send(voxel, <<2>>, 0)
    {:ok, first} = MmoContracts.Voxel.Codec.encode_m1(fence)
    {:ok, second} = MmoContracts.Voxel.Codec.encode_m1(%{fence | server_tick: 11})
    first = IO.iodata_to_binary(first)
    second = IO.iodata_to_binary(second)
    expected = <<2, byte_size(first)::32, first::binary, byte_size(second)::32, second::binary>>
    assert receive_bytes(voxel, byte_size(expected), <<>>) == expected
  end

  test "movement datagrams preserve identity and stale epochs never reach Scene", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    frame = %MmoContracts.Movement.InputFrame{input_seq: 1, axis_x: 0, axis_z: 0, yaw: 0, jump_pressed: 0}
    batch = %MmoContracts.Movement.InputBatch{identity: identity, frames: [frame]}
    {:ok, current} = MmoContracts.Movement.Codec.encode(batch)
    {:ok, _} = :quicer.async_send_dgram(conn, IO.iodata_to_binary(current))
    assert_receive {:input, ^identity, ^batch}, 5000
    old = %{batch | identity: %{identity | session_epoch: identity.session_epoch - 1}}
    {:ok, old_bytes} = MmoContracts.Movement.Codec.encode(old)
    {:ok, _} = :quicer.async_send_dgram(conn, IO.iodata_to_binary(old_bytes))
    refute_receive {:input, _, ^old}, 100
    assert GenServer.call(sink, :stats).stale_identity == 1
    state = %Session.State{position: {0.0, 1.0, 0.0}, velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: 0}
    ack = %MmoContracts.Movement.OwnerAck{identity: identity, server_tick: 1, processed_input_seq: 1,
      collision_revision: 1, state: state, substituted_through_seq: 0}
    send(sink, {:mmo_datagram, identity, ack})
    assert_receive {:quic, ack_bytes, ^conn, _} when is_binary(ack_bytes), 5000
    assert {:ok, ^ack} = MmoContracts.Movement.Codec.decode(ack_bytes)
  end

  test "duplicate cid closes old epoch reliably while new join remains isolated", %{conn: conn, hello: hello} do
    old_control = control(conn, hello)
    assert_receive {:join, old, _, old_sink}, 5000
    {:ok, second} = :quicer.connect(~c"localhost", 25443,
      [alpn: [~c"voxim-m1"], verify: :verify_peer,
       cacertfile: ~c"/home/dyz/.cache/voxim-m1-t1/certs-v1/ca.pem", datagram_receive_enabled: 1], 5000)
    on_exit(fn -> :quicer.async_shutdown_connection(second, 0, 0) end)
    control(second, hello)
    assert_receive {:join, fresh, _, fresh_sink}, 5000
    assert fresh.session_epoch > old.session_epoch
    {:ok, hello_bytes} = Session.Codec.encode(hello)
    {:ok, end_bytes} = Session.Codec.encode(%Session.SessionEnd{identity: old, reason: 2})
    hello_bytes = IO.iodata_to_binary(hello_bytes)
    end_bytes = IO.iodata_to_binary(end_bytes)
    expected = <<1, byte_size(hello_bytes)::32, hello_bytes::binary, byte_size(end_bytes)::32, end_bytes::binary>>
    assert receive_bytes(old_control, byte_size(expected), <<>>) == expected
    assert_receive {:leave, ^old}, 5000
    assert Process.alive?(fresh_sink)
    refute Process.alive?(old_sink)
    send(fresh_sink, {:mmo_close, old, 1})
    assert GenServer.call(fresh_sink, :stats).identity == fresh
  end

  defp receive_bytes(_stream, expected, bytes) when byte_size(bytes) >= expected, do: bytes
  defp receive_bytes(stream, expected, bytes) do
    receive do
      {:quic, more, ^stream, _} when is_binary(more) -> receive_bytes(stream, expected, bytes <> more)
    after
      5000 -> flunk("reliable stream incomplete: #{byte_size(bytes)}/#{expected}")
    end
  end

  test "Gate exposes a supervised QUIC listener and connection owner" do
    assert Code.ensure_loaded?(GateServer.Transport.QuicListener)
    assert function_exported?(GateServer.Transport.QuicListener, :start_link, 1)
    assert Code.ensure_loaded?(GateServer.Session.QuicConnection)
    assert function_exported?(GateServer.Session.QuicConnection, :start_link, 1)
  end

  test "two simultaneous native handshakes have armed acceptors" do
    results = 1..2 |> Enum.map(fn _ -> Task.async(fn ->
      :quicer.connect(~c"localhost", 25443, [alpn: [~c"voxim-m1"], verify: :verify_peer,
        cacertfile: ~c"/home/dyz/.cache/voxim-m1-t1/certs-v1/ca.pem", datagram_receive_enabled: 1], 5000)
    end) end) |> Enum.map(&Task.await(&1, 6000))
    assert Enum.all?(results, &match?({:ok, _}, &1))
  end

  test "paused receiver holds reliable data while snapshots replace before native send", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    {:ok, voxel} = :quicer.start_stream(conn, [{:active, false}])
    {:ok, _} = :quicer.async_send(voxel, <<2>>, 0)
    # Force a real flow-control stall: 12 MiB exceeds the receiver stream window.
    large = :binary.copy(<<0xA5>>, 12 * 1024 * 1024)
    send(sink, {:mmo_voxel_bytes, identity, large})
    send(sink, {:mmo_voxel_bytes, identity, <<0x71, 0x19, 0xE3>>})
    Process.sleep(500)
    stalled = GenServer.call(sink, :stats)
    assert stalled.reliable_queued >= 1
    player = %Session.State{position: {0.0, 1.0, 0.0}, velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: 0}
    :ok = :sys.suspend(sink)
    for seq <- 1..100 do
      ack = %MmoContracts.Movement.OwnerAck{identity: identity, server_tick: seq, processed_input_seq: seq,
        collision_revision: 1, state: player, substituted_through_seq: 0}
      send(sink, {:mmo_datagram, identity, ack})
      record = %MmoContracts.Movement.SnapshotRecord{entity_id: 202, entity_epoch: 1,
        interest_generation: 1, collision_revision: 1, state: %{player | yaw: seq}}
      snapshot = %MmoContracts.Movement.Snapshot{identity: identity, server_tick: seq, records: [record]}
      send(sink, {:mmo_datagram, identity, snapshot})
    end
    :ok = :sys.resume(sink)
    assert_receive {:quic, ack_bytes, ^conn, _} when is_binary(ack_bytes), 5000
    assert {:ok, %MmoContracts.Movement.OwnerAck{processed_input_seq: 100}} = MmoContracts.Movement.Codec.decode(ack_bytes)
    assert_receive {:quic, snapshot_bytes, ^conn, _} when is_binary(snapshot_bytes), 5000
    assert {:ok, %MmoContracts.Movement.Snapshot{server_tick: 100, records: [%{entity_id: 202, state: %{yaw: 100}}]}} =
      MmoContracts.Movement.Codec.decode(snapshot_bytes)
    assert GenServer.call(sink, :stats).datagrams_replaced == 198
    :ok = :quicer.setopt(voxel, :active, true)
    expected = <<2, byte_size(large)::32, large::binary, 3::32, 0x71, 0x19, 0xE3>>
    assert receive_bytes(voxel, byte_size(expected), <<>>) == expected
    stats = GenServer.call(sink, :stats)
    assert stats.queue_age_us >= 450_000
    IO.puts("T1_BACKPRESSURE " <> inspect(Map.drop(stats, [:identity]), limit: :infinity))
  end

  test "preauth datagram closes with the specified auth rejection", %{conn: conn} do
    assert {:ok, _} = :quicer.async_send_dgram(conn, <<1>>)
    assert_receive {:quic, :shutdown, ^conn, 0x1000D}, 5000
  end

  test "split control purpose and length preserve Hello while wrong identity closes", %{conn: conn, hello: hello} do
    {:ok, stream} = :quicer.start_stream(conn, [{:active, true}])
    {:ok, bytes} = Session.Codec.encode(%{hello | kernel_id: <<3::256>>})
    bytes = IO.iodata_to_binary(bytes)
    <<head::binary-size(2), tail::binary>> = <<1, byte_size(bytes)::32, bytes::binary>>
    assert {:ok, 2} = :quicer.async_send(stream, head, 0)
    assert {:ok, _} = :quicer.async_send(stream, tail, 0)
    assert_receive {:quic, :shutdown, ^conn, 0x10009}, 5000
  end
end
