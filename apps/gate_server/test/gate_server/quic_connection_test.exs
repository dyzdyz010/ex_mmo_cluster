
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
  def join(ref, identity, character, sink) do
    GenServer.cast(ref, {:join, identity, character, sink})
    {:ok, ref}
  end
  def ready(ref, identity, n, r), do: GenServer.cast(ref, {:ready, identity, n, r})
  def input(ref, identity, batch), do: GenServer.cast(ref, {:input, identity, batch})
  def leave(ref, identity, _reason \\ 1), do: GenServer.cast(ref, {:leave, identity})
  def handle_cast(message, owner) do
    send(owner, message)
    {:noreply, owner}
  end
end

defmodule T1TransportTest do
  use ExUnit.Case, async: false

  alias MmoContracts.Session
  alias MmoContracts.Movement

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
    old_monitor = Process.monitor(old_sink)
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
    assert_receive {:DOWN, ^old_monitor, :process, ^old_sink, _}, 5000
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
    control_stream = control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    {:ok, voxel} = :quicer.start_stream(conn, [{:active, false}])
    {:ok, _} = :quicer.async_send(voxel, <<2>>, 0)
    # 12 MiB 超出接收窗口；暂停期间字节由 MsQuic 持有，不能依赖 Gate 队列长度判断背压。
    large = :binary.copy(<<0xA5>>, 12 * 1024 * 1024)
    send(sink, {:mmo_voxel_bytes, identity, large})
    send(sink, {:mmo_voxel_bytes, identity, <<0x71, 0x19, 0xE3>>})
    Process.sleep(500)
    stalled = GenServer.call(sink, :stats)
    assert stalled.bytes_out >= byte_size(large)
    # 已向 native 提交完整大包，但对端暂停使实际流发送尚未完成。
    {:ok, stalled_quic} = stalled.quic
    {_, stream_sent} = List.keyfind(stalled_quic, ~c"Send.TotalStreamBytes", 0)
    assert stream_sent < byte_size(large)
    IO.puts("T1_NATIVE_STALL submitted=#{stalled.bytes_out} stream_sent=#{stream_sent}")
    reply = %Session.TimeReply{request_id: 777, client_send_us: 1, server_receive_us: 2, server_send_us: 3, server_tick: 4}
    send(sink, {:mmo_reliable, identity, 1, reply})
    {:ok, hello_bytes} = Session.Codec.encode(hello)
    {:ok, reply_bytes} = Session.Codec.encode(reply)
    hello_bytes = IO.iodata_to_binary(hello_bytes)
    reply_bytes = IO.iodata_to_binary(reply_bytes)
    control_bytes = <<1, byte_size(hello_bytes)::32, hello_bytes::binary, byte_size(reply_bytes)::32, reply_bytes::binary>>
    assert receive_bytes(control_stream, byte_size(control_bytes), <<>>) == control_bytes
    IO.puts("T1_CONTROL_PROGRESS reliable TimeReply received before paused voxel resumes")
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
    assert stats.reliable_queued == 0
    IO.puts("T1_BACKPRESSURE " <> inspect(Map.drop(stats, [:identity]), limit: :infinity))
  end

  test "preauth datagram closes with the specified auth rejection", %{conn: conn} do
    assert {:ok, _} = :quicer.async_send_dgram(conn, <<1>>)
    assert_receive {:quic, :shutdown, ^conn, 0x1000D}, 5000
  end

  @tag :batching
  test "snapshots fill the byte limit and retain the next record", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    records = Enum.map(201..203, &snapshot_record/1)
    snapshot = %Movement.Snapshot{identity: identity, server_tick: 40, records: records}
    limit = byte_size(movement_bytes(%{snapshot | records: Enum.take(records, 2)}))
    send_bounded_snapshot(sink, snapshot, limit)

    {first, bytes} = receive_movement(conn)
    assert first == %{snapshot | records: Enum.take(records, 2)}
    assert byte_size(bytes) == limit
    assert {last, _} = receive_movement(conn)
    assert last == %{snapshot | records: Enum.drop(records, 2)}
    stats = GenServer.call(sink, :stats)
    assert stats.datagrams_sent == 2
    assert stats.snapshot_records_sent == 3
    assert stats.snapshot_datagrams_sent == 2
    assert stats.snapshot_bytes_sent == byte_size(bytes) + byte_size(movement_bytes(last))
  end

  @tag :batching
  test "a single record fits exactly and one byte less splits a pair", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    [a, b] = Enum.map(201..202, &snapshot_record/1)
    snapshot = %Movement.Snapshot{identity: identity, server_tick: 41, records: [a, b]}
    limit = byte_size(movement_bytes(snapshot)) - 1
    send_bounded_snapshot(sink, snapshot, limit)
    assert {first, _} = receive_movement(conn)
    assert first.records == [a]
    assert {second, _} = receive_movement(conn)
    assert second.records == [b]

    single = %{snapshot | server_tick: 42, records: [a]}
    limit = byte_size(movement_bytes(single))
    send_bounded_snapshot(sink, single, limit)
    assert {^single, bytes} = receive_movement(conn)
    assert byte_size(bytes) == limit
  end

  @tag :batching
  test "replacements batch by real tick and preserve generations while ACK progresses first", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    [a, b, c] = Enum.map(201..203, &snapshot_record/1)
    old = %Movement.Snapshot{identity: identity, server_tick: 50, records: [a, b, c]}
    fresh_a = %{a | entity_epoch: 2, interest_generation: 3, collision_revision: 7}
    fresh_b = %{b | collision_revision: 6}
    ack = %Movement.OwnerAck{identity: identity, server_tick: 52, processed_input_seq: 10,
      collision_revision: 7, state: a.state, substituted_through_seq: 0, simulation_tick: 51}
    :ok = :sys.suspend(sink)
    send(sink, {:mmo_datagram, identity, old})
    send(sink, {:mmo_datagram, identity, %{old | server_tick: 51, records: [fresh_a]}})
    send(sink, {:mmo_datagram, identity, %{old | server_tick: 51, records: [fresh_b]}})
    send(sink, {:mmo_datagram, identity, ack})
    stale = %{identity | session_epoch: identity.session_epoch - 1}
    send(sink, {:mmo_datagram, stale, %{old | identity: stale}})
    :ok = :sys.resume(sink)

    assert {^ack, _} = receive_movement(conn)
    assert {first, _} = receive_movement(conn)
    assert first == %{old | server_tick: 51, records: [fresh_a, fresh_b]}
    assert {second, _} = receive_movement(conn)
    assert second == %{old | records: [c]}
    assert GenServer.call(sink, :stats).datagrams_replaced == 2
  end

  @tag :batching
  test "FIFO service order is sorted only inside a compatible encoded packet", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    records = Enum.map(201..203, &snapshot_record/1)
    snapshot = %Movement.Snapshot{identity: identity, server_tick: 99, records: records}
    :ok = :sys.suspend(sink)
    send(sink, {:mmo_datagram, identity, %{snapshot | records: [List.last(records)]}})
    send(sink, {:mmo_datagram, identity, %{snapshot | records: Enum.take(records, 2)}})
    :ok = :sys.resume(sink)
    assert {^snapshot, _} = receive_movement(conn)
  end

  @tag :batching
  test "replacement preserves each entity's send turn while newer ticks keep arriving", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    records = Enum.map(201..206, &snapshot_record/1)
    snapshot = %Movement.Snapshot{identity: identity, server_tick: 100, records: records}
    limit = byte_size(movement_bytes(%{snapshot | records: Enum.take(records, 2)}))
    # Hold the owner's mailbox so each real native completion releases exactly one
    # send opportunity, followed by the next 20 Hz producer update before another.
    :ok = :sys.suspend(sink)
    try do
      delivered = for round <- 0..2 do
        tick = 100 + round * 3
        fresh = %{snapshot | server_tick: tick, records: Enum.map(records, fn r ->
          %{r | collision_revision: round + 1, state: %{r.state | yaw: tick}}
        end)}
        ack = %Movement.OwnerAck{identity: identity, server_tick: tick, processed_input_seq: tick,
          collision_revision: round + 1, state: hd(records).state, substituted_through_seq: 0}
        controlled_native_send(sink, [fresh, ack], limit)
        assert {^ack, _} = receive_movement(conn)
        controlled_native_send(sink, [], limit)
        {received, bytes} = receive_movement(conn)
        assert received.server_tick == tick
        assert byte_size(bytes) == limit
        assert Enum.all?(received.records, &(&1.collision_revision == round + 1 and &1.state.yaw == tick))
        Enum.map(received.records, & &1.entity_id)
      end
      assert List.flatten(delivered) |> Enum.sort() == Enum.to_list(201..206)
      IO.puts("M3_GATE_FAIR_REPLACEMENT delivered=#{inspect(delivered)}")
    after
      :ok = :sys.resume(sink)
    end
  end

  @tag :batching
  test "negotiated datagram size is not capped at 1200 bytes", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, _, _, sink}, 5000
    server_conn = :sys.get_state(sink).conn
    send(sink, {:quic, :dgram_state_changed, server_conn, %{dgram_send_enabled: true, dgram_max_len: 1380}})
    assert GenServer.call(sink, :stats).max_datagram == 1380
  end

  @tag :batching
  test "real negotiated datagrams carry all records and expose sent byte counters", %{conn: conn, hello: hello} do
    control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    limit = GenServer.call(sink, :stats).max_datagram
    snapshot = %Movement.Snapshot{identity: identity, server_tick: 60,
      records: Enum.map(201..232, &snapshot_record/1)}
    send(sink, {:mmo_datagram, identity, snapshot})
    packets = receive_snapshot_records(conn, 32, [])
    stats = GenServer.call(sink, :stats)
    # 本机 PMTU 探测会在握手后提升上限；不能把发送前的一次观测当成固定协商值。
    upper_limit = max(limit, stats.max_datagram)
    assert Enum.flat_map(packets, fn {message, _} -> message.records end) == snapshot.records
    assert length(packets) < 32
    for {message, bytes} <- packets do
      assert message.identity == identity and message.server_tick == 60
      assert byte_size(bytes) <= upper_limit
    end
    assert stats.snapshot_records_sent == 32
    assert stats.snapshot_datagrams_sent == length(packets)
    assert stats.snapshot_bytes_sent == Enum.sum(Enum.map(packets, fn {_, bytes} -> byte_size(bytes) end))
    IO.puts("M3_GATE_BATCH negotiated_before=#{limit} negotiated_after=#{stats.max_datagram} records=32 datagrams=#{length(packets)} bytes=#{stats.snapshot_bytes_sent}")
  end

  @tag :batching
  test "reliable leave and reenter retain order while the queued generation is replaced", %{conn: conn, hello: hello} do
    stream = control(conn, hello)
    assert_receive {:join, identity, _, sink}, 5000
    old = snapshot_record(201)
    fresh = %{old | entity_epoch: 2, interest_generation: 3}
    enter = %Session.EntityEnter{identity: identity, entity_id: old.entity_id,
      entity_epoch: old.entity_epoch, interest_generation: old.interest_generation,
      server_tick: 69, state: old.state}
    leave = %Session.EntityLeave{identity: identity, entity_id: old.entity_id,
      entity_epoch: old.entity_epoch, interest_generation: old.interest_generation, server_tick: 70}
    reenter = %{enter | entity_epoch: fresh.entity_epoch, interest_generation: fresh.interest_generation,
      server_tick: 71}
    snapshot = %Movement.Snapshot{identity: identity, server_tick: 69, records: [old]}
    :ok = :sys.suspend(sink)
    send(sink, {:mmo_reliable, identity, 1, enter})
    send(sink, {:mmo_datagram, identity, snapshot})
    send(sink, {:mmo_reliable, identity, 1, leave})
    send(sink, {:mmo_reliable, identity, 1, reenter})
    send(sink, {:mmo_datagram, identity, %{snapshot | server_tick: 71, records: [fresh, snapshot_record(202)]}})
    :ok = :sys.resume(sink)
    expected = IO.iodata_to_binary([<<1>> | Enum.map([hello, enter, leave, reenter], fn message ->
      {:ok, encoded} = Session.Codec.encode(message)
      bytes = IO.iodata_to_binary(encoded)
      <<byte_size(bytes)::32, bytes::binary>>
    end)])
    assert receive_bytes(stream, byte_size(expected), <<>>) == expected
    assert {received, _} = receive_movement(conn)
    assert received == %{snapshot | server_tick: 71, records: [fresh, snapshot_record(202)]}
  end

  defp receive_snapshot_records(_conn, 0, packets), do: Enum.reverse(packets)
  defp receive_snapshot_records(conn, remaining, packets) do
    {message, _} = packet = receive_movement(conn)
    assert length(message.records) <= remaining
    receive_snapshot_records(conn, remaining - length(message.records), [packet | packets])
  end

  defp send_bounded_snapshot(sink, snapshot, limit) do
    # 在连接 owner 中原子注入一个传输上限并首次发送，隔离真实 PMTU 更新的竞争；仍走真实 native QUIC。
    :sys.replace_state(sink, fn state ->
      alias GateServer.Session.QuicConnection
      {:noreply, state} = QuicConnection.handle_info(
        {:quic, :dgram_state_changed, state.conn, %{dgram_send_enabled: true, dgram_max_len: limit}}, state)
      {:noreply, state} = QuicConnection.handle_info({:mmo_datagram, snapshot.identity, snapshot}, state)
      {:noreply, state} = QuicConnection.handle_info(:flush_datagrams, state)
      state
    end)
  end

  defp controlled_native_send(sink, messages, limit) do
    :sys.replace_state(sink, fn state ->
      alias GateServer.Session.QuicConnection
      state = if state.datagram_busy do
        conn = state.conn
        receive do
          {:quic, :dgram_send_state, ^conn, %{state: :dgram_send_sent}} = completion ->
            {:noreply, released} = QuicConnection.handle_info(completion, state)
            released
        after
          5000 -> flunk("native send completion was not delivered")
        end
      else
        state
      end
      state = Enum.reduce(messages, %{state | max_datagram: limit}, fn message, acc ->
        {:noreply, queued} = QuicConnection.handle_info({:mmo_datagram, acc.identity, message}, acc)
        queued
      end)
      {:noreply, sent} = QuicConnection.handle_info(:flush_datagrams, state)
      sent
    end)
  end

  defp snapshot_record(id) do
    %Movement.SnapshotRecord{entity_id: id, entity_epoch: 1, interest_generation: 1,
      collision_revision: 1, state: %Session.State{position: {0.0, 1.0, 0.0},
        velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: id}}
  end

  defp movement_bytes(message) do
    {:ok, bytes} = Movement.Codec.encode(message)
    IO.iodata_to_binary(bytes)
  end

  defp receive_movement(conn) do
    assert_receive {:quic, bytes, ^conn, _} when is_binary(bytes), 5000
    assert {:ok, message} = Movement.Codec.decode(bytes)
    {message, bytes}
  end

  test "server rejects downlink-only TimeReply received from client", %{conn: conn, hello: hello} do
    stream = control(conn, hello)
    assert_receive {:join, identity, _, _}, 5000
    wrong = %Session.TimeReply{request_id: 1, client_send_us: 1, server_receive_us: 2, server_send_us: 3, server_tick: 4}
    {:ok, bytes} = Session.Codec.encode(wrong)
    bytes = IO.iodata_to_binary(bytes)
    {:ok, _} = :quicer.async_send(stream, <<byte_size(bytes)::32, bytes::binary>>, 0)
    {:ok, echoed} = Session.Codec.encode(hello)
    {:ok, ending} = Session.Codec.encode(%Session.SessionEnd{identity: identity, reason: 8})
    echoed = IO.iodata_to_binary(echoed)
    ending = IO.iodata_to_binary(ending)
    expected = <<1, byte_size(echoed)::32, echoed::binary, byte_size(ending)::32, ending::binary>>
    assert receive_bytes(stream, byte_size(expected), <<>>) == expected
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
defmodule M4aGateTransferTest do
  use ExUnit.Case, async: true
  @moduletag :m4a_transfer
  alias GateServer.Session.QuicConnection
  alias GateServer.Transport.QuicListener
  alias MmoContracts.{Session, Movement}

  defmodule BlockingEditStore do
    def ensure(owner, 0, _) do
      send(owner, {:edit_preparing, self()})
      receive do: (:continue -> :ok)
    end
    def ensure(_, _, _), do: :ok
  end

  defmodule EditWorld do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, {owner, 0}}
    def handle_call(:source, _, {owner, _} = state), do: {:reply, {BlockingEditStore, owner}, state}
    def handle_call({:apply_edits, edits}, _, {owner, seq}) do
      send(owner, {:world_edit, edits})
      {:reply, {:ok, seq + 1}, {owner, seq + 1}}
    end
  end

  # 只替代 QUIC 的传输资源；实际帧解码、Dispatch、World.prepare 和结果 Sink 原样执行。
  defp edit_gate(state, owner) do
    receive do
      {:inspect_state, owner} -> send(owner, {:gate_state, state}); edit_gate(state, owner)
      event ->
        {:noreply, state} = QuicConnection.handle_info(event, state)
        if match?({:mmo_edit_finished, _, _, _}, event), do: send(owner, {:gate_edit_completed, state.edit_completed, state})
        edit_gate(state, owner)
    end
  end

  defp batch_event(scene, request, x) do
    bytes = <<0x78, request::64, request::32, scene::64, 1::32, x::signed-32, 1::signed-32, 1::signed-32, 11::16>>
    {:quic, <<byte_size(bytes)::32, bytes::binary>>, :voxel_stream, %{}}
  end

  test "cold edits preserve Gate input and transfer progress, FIFO and connection result ownership" do
    owner = self()
    world = start_supervised!({EditWorld, owner})
    listener = spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:commit_transfer, _, _, 101}} -> GenServer.reply(from, :ok)
      end
    end)
    initial = pending_state()
    initial = %{initial | listener: listener, voxim_overlay: true,
      bounds: {{0, 0, 0}, {16, 16, 16}}, route: %{scene_ref: :source_scene, world_ref: world},
      streams: %{voxel_stream: %{purpose: 2, buffer: <<>>, started: true},
        control_stream: %{purpose: 1, buffer: <<>>, started: true}}}
    gate = spawn(fn -> edit_gate(initial, owner) end)
    on_exit(fn -> Process.exit(gate, :kill) end)
    send(gate, batch_event(1, 1, 1))
    assert_receive {:edit_preparing, first}, 2_000
    send(gate, batch_event(1, 2, 2))
    send(gate, {:inspect_state, owner})
    assert_receive {:gate_state, queued}, 500
    assert queued.edit_pending == 2
    refute_receive {:edit_preparing, _}, 20

    fresh = initial.pending_transfer.identity
    batch = %Movement.InputBatch{identity: initial.identity, frames: [%Movement.InputFrame{
      input_seq: 31, axis_x: 1, axis_z: 0, yaw: 0, jump_pressed: 0}]}
    {:ok, bytes} = Movement.Codec.encode(batch)
    send(gate, {:quic, IO.iodata_to_binary(bytes), :connection, %{}})
    assert_receive {:"$gen_cast", {:input, ^fresh, _}}, 500
    {:ok, bytes} = Session.Codec.encode(%Session.Ready{identity: fresh,
      baseline_transaction_seq: 20, collision_revision: 3})
    bytes = IO.iodata_to_binary(bytes)
    send(gate, {:quic, <<byte_size(bytes)::32, bytes::binary>>, :control_stream, %{}})
    send(gate, {:inspect_state, owner})
    assert_receive {:gate_state, transferred}, 500
    assert transferred.identity == fresh
    assert transferred.edit_ref == queued.edit_ref

    send(first, :continue)
    assert_receive {:world_edit, [{{1, 1, 1}, 11}]}, 2_000
    assert_receive {:edit_preparing, second}, 2_000
    send(second, :continue)
    assert_receive {:world_edit, [{{2, 1, 1}, 11}]}, 2_000
    # 来自worker的结果与完成事件保持同一发送者顺序，取到两次完成再观察队列。
    assert_receive {:gate_edit_completed, 2, completed}, 2_000
    assert completed.identity == fresh and completed.edit_pending == 0
    assert completed.edit_worker_us > 0 and completed.edit_queue_wait_us > 0
    results = for {bytes, _, _} <- :queue.to_list(completed.reliable[2]) do
      <<0x68, request::64, _intent::32, 1::64, _result::8, seq::64, _::binary>> = bytes
      {request, seq}
    end
    assert results == [{1, 1}, {2, 2}]
    {:ok, other} = QuicConnection.init(conn: :connection, listener: owner, hello: nil)
    {:noreply, ^other} = QuicConnection.handle_info({:mmo_voxel_bytes, completed.edit_ref, <<1>>}, other)
    closing = %{completed | closing: true}
    {:noreply, ^closing} = QuicConnection.handle_info({:mmo_voxel_bytes, completed.edit_ref, <<1>>}, closing)
    {:noreply, ^completed} = QuicConnection.handle_info({:mmo_voxel_bytes, initial.identity, <<1>>}, completed)
    monitor = Process.monitor(completed.edit_worker)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1_000
  end

  test "voxel stream accepts pending and previous Scene tags while rejecting unrelated or out of bounds edits" do
    initial = pending_state()
    initial = %{initial | voxim_overlay: true, edit_worker: self(),
      bounds: {{0, 0, 0}, {16, 16, 16}}, route: %{scene_ref: :source_scene, world_ref: :shared_world},
      pending_transfer: %{initial.pending_transfer | route: %{scene_ref: :target_scene, world_ref: :shared_world}},
      streams: %{voxel_stream: %{purpose: 2, buffer: <<>>, started: true}}}
    {:noreply, state} = QuicConnection.handle_info(batch_event(2, 1, 1), initial)
    refute state.closing
    assert_receive {{:voxel_batch_edit_intent, %{logical_scene_id: 2}}, %{world_ref: :shared_world}, _}
    listener = spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:commit_transfer, _, _, 101}} -> GenServer.reply(from, :ok)
      end
    end)
    fresh = state.pending_transfer.identity
    committed = ready(%{state | listener: listener}, fresh)
    assert committed.previous_scene_id == 1
    {:noreply, late} = QuicConnection.handle_info(batch_event(1, 2, 2), committed)
    refute late.closing
    assert_receive {{:voxel_batch_edit_intent, %{logical_scene_id: 1}}, %{world_ref: :shared_world}, _}
    for {scene, x} <- [{3, 1}, {1, 16}] do
      {:noreply, rejected} = QuicConnection.handle_info(batch_event(scene, 3, x), committed)
      assert rejected.closing and rejected.edit_pending == committed.edit_pending
      refute_receive {{:voxel_batch_edit_intent, _}, _, _}
    end
    {:ok, reconnected} = QuicConnection.init(conn: :connection, listener: self(), hello: nil)
    assert reconnected.previous_scene_id == nil
    new = %{reconnected | identity: fresh, route: committed.route, bounds: committed.bounds,
      voxim_overlay: true, streams: initial.streams}
    {:noreply, rejected} = QuicConnection.handle_info(batch_event(1, 4, 1), new)
    assert rejected.closing and rejected.edit_worker == nil
  end

  defmodule Router do
    def route(2), do: {:ok, %{scene_ref: :target_scene, scene_epoch: 8, world_ref: :shared_world}}
    def prepare_transfer(old, fresh, artifact, gate) do
      send(gate, {:prepared, old, fresh, artifact})
      {:ok, gate}
    end
    def commit_transfer(old, fresh) do
      send(self(), {:committed, old, fresh})
      :ok
    end
  end

  defp identities do
    old = %Session.Identity{session_epoch: 10, scene_id: 1, scene_epoch: 7}
    {old, %{old | session_epoch: 11, scene_id: 2, scene_epoch: 8}}
  end

  defp pending_state do
    {old, fresh} = identities()
    {:ok, state} = QuicConnection.init(conn: :connection, listener: self(), hello: nil)
    pending = %{identity: fresh, route: %{scene_ref: :target_scene}, player: self(), cid: 101,
      transaction_seq: 20, collision_revision: 3, cut_tick: 60, processed_input_seq: 30,
      started_us: System.monotonic_time(:microsecond), input_batches: 0}
    %{state | identity: old, route: %{scene_ref: :source_scene}, player: :sealed_source,
      pending_transfer: pending}
  end

  defp input(state, identity, transport) do
    batch = %Movement.InputBatch{identity: identity, frames: [%Movement.InputFrame{
      input_seq: 31, axis_x: 1, axis_z: 0, yaw: 0, jump_pressed: 0}]}
    {:ok, bytes} = Movement.Codec.encode(batch)
    bytes = IO.iodata_to_binary(bytes)
    {event, state} = case transport do
      :datagram -> {{:quic, bytes, state.conn, %{}}, state}
      :control ->
        stream = :control_stream
        state = put_in(state.streams[stream], %{purpose: 1, buffer: <<>>, started: true})
        {{:quic, <<byte_size(bytes)::32, bytes::binary>>, stream, %{}}, state}
    end
    {:noreply, state} = QuicConnection.handle_info(event, state)
    {state, batch}
  end

  defp ready(state, identity, seq \\ 20, revision \\ 3) do
    {:ok, bytes} = Session.Codec.encode(%Session.Ready{identity: identity,
      baseline_transaction_seq: seq, collision_revision: revision})
    bytes = IO.iodata_to_binary(bytes)
    state = put_in(state.streams[:control_stream], %{purpose: 1, buffer: <<>>, started: true})
    {:noreply, state} = QuicConnection.handle_info(
      {:quic, <<byte_size(bytes)::32, bytes::binary>>, :control_stream, %{}}, state)
    state
  end

  test "pending old and new inputs reach only passive target on both transports" do
    initial = pending_state()
    for transport <- [:datagram, :control], identity <- [initial.identity, initial.pending_transfer.identity] do
      {state, batch} = input(initial, identity, transport)
      fresh = initial.pending_transfer.identity
      rebound = %{batch | identity: fresh}
      assert_receive {:"$gen_cast", {:input, ^fresh, ^rebound}}
      assert state.identity == initial.identity
      assert state.pending_transfer.input_batches == 1
      refute state.closing
    end
    refute_receive {:committed, _, _}
  end

  test "pending unrelated input is isolated without closing either transport" do
    initial = pending_state()
    for transport <- [:datagram, :control] do
      {state, _} = input(initial, %{initial.identity | session_epoch: 9}, transport)
      assert state.stale_identity == 1
      refute state.closing
      refute_receive {:"$gen_cast", {:input, _, _}}
    end
  end

  test "Gate seals the source before preparing and keeps old fence output until Ready" do
    {old, fresh} = identities()
    owner = self()
    value = %Session.State{position: {41.5, 1.0, 0.0}, velocity: {1.0, 0.0, 0.0}, grounded: 1, yaw: 0}
    artifact = %{id: 101, state: value, transaction_seq: 20, simulation_revision: 3,
      simulation_tick: 60, slots: %{processed_input_seq: 30}}
    source = spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:seal, ^old}} ->
          send(owner, :source_sealed)
          GenServer.reply(from, {:ok, artifact})
      end
    end)
    listener = spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:prepare_transfer, ^old, 2, ^artifact}} ->
          send(owner, :target_prepared)
          GenServer.reply(from, {:ok, fresh, %{scene_ref: :target_scene}, owner})
      end
    end)
    {:ok, initial} = QuicConnection.init(conn: :connection, listener: listener, hello: nil)
    initial = %{initial | identity: old, player: source, route: %{scene_ref: :source_scene}}
    {:noreply, state} = QuicConnection.handle_info({:mmo_transfer_request, old, source, 2}, initial)
    assert_receive :source_sealed
    assert_receive :target_prepared
    assert state.identity == old and state.player == source
    assert state.pending_transfer.identity == fresh
    assert state.transfer_prepared == 1 and state.transfer_committed == 0
    [{bytes, _, _}] = :queue.to_list(state.reliable[1])
    assert {:ok, %Session.Transfer{identity: ^old, next_identity: ^fresh, cut_tick: 60,
      processed_input_seq: 30, transaction_seq: 20, collision_revision: 3, state: ^value}} =
      Session.Codec.decode(bytes)
    fence = %MmoContracts.Voxel.TimelineFence{identity: old, server_tick: 60,
      transaction_seq: 20, collision_revision: 3}
    {:noreply, state} = QuicConnection.handle_info({:mmo_reliable, old, 2, fence}, state)
    assert :queue.len(state.reliable[2]) == 1
    {:noreply, ^state} = QuicConnection.handle_info({:mmo_transfer_request, old, source, 2}, state)
  end

  test "old or incorrect Ready cannot commit a pending transfer" do
    state = pending_state()
    assert ready(state, state.identity).closing
    assert ready(state, state.pending_transfer.identity, 21).closing
    assert ready(state, state.pending_transfer.identity, 20, 4).closing
    refute_receive {:"$gen_call", _, {:commit_transfer, _, _, _}}
    refute_receive {:"$gen_cast", {:ready, _, _, _}}
  end

  test "matching Ready commits once and drops queued old datagrams without releasing native send" do
    initial = pending_state()
    owner = self()
    listener = spawn_link(fn ->
      receive do
        {:"$gen_call", from, request} ->
          send(owner, request)
          GenServer.reply(from, :ok)
      end
    end)
    state = %{initial | listener: listener, datagram_busy: true,
      pending_datagrams: :gb_trees.enter(:owner, :old_packet, :gb_trees.empty()),
      snapshot_keys: %{101 => {0, 101}}}
    fresh = state.pending_transfer.identity
    state = ready(state, fresh)
    old = initial.identity
    assert_receive {:commit_transfer, ^old, ^fresh, 101}
    assert state.identity == fresh and state.player == self()
    assert state.pending_transfer == nil
    assert state.transfer_committed == 1
    assert state.datagram_busy
    assert :gb_trees.is_empty(state.pending_datagrams)
    assert state.snapshot_keys == %{}
    {:noreply, ^state} = QuicConnection.handle_info({:mmo_voxel_bytes, old, <<1>>}, state)
    {:noreply, ^state} = QuicConnection.handle_info({:mmo_reliable, old, 1, :ignored}, state)
    {:noreply, ^state} = QuicConnection.handle_info({:mmo_datagram, old, :ignored}, state)
    assert ready(state, fresh).closing
    assert ready(state, old).closing
    refute_receive {:"$gen_cast", {:ready, _, _, _}}
    {state, _} = input(state, old, :datagram)
    assert state.stale_identity == 1
  end

  test "listener reserves epoch while old owner stays authoritative until commit" do
    {old, fresh} = identities()
    owner = %{identity: old, pid: self(), scene_ref: :source_scene}
    state = %{characters: %{101 => owner}, next_epoch: 11, opts: [route_module: Router]}
    artifact = %{id: 101}
    assert {:reply, {:ok, ^fresh, route, target}, prepared} =
      QuicListener.handle_call({:prepare_transfer, old, 2, artifact}, {self(), make_ref()}, state)
    assert target == self() and route.scene_ref == :target_scene
    assert prepared.next_epoch == 12
    assert prepared.characters[101] == owner
    assert_receive {:prepared, ^old, ^fresh, ^artifact}
    refute_receive {:committed, _, _}
    assert {:reply, :ok, committed} = QuicListener.handle_call(
      {:commit_transfer, old, fresh, 101}, {self(), make_ref()}, prepared)
    assert committed.characters[101].identity == fresh
    assert committed.characters[101].scene_ref == :target_scene
    assert_receive {:committed, ^old, ^fresh}
  end

  test "a duplicate claim makes old Gate prepare and commit fail the owner CAS" do
    {old, fresh} = identities()
    replacement = %{fresh | session_epoch: 12}
    state = %{characters: %{101 => %{identity: replacement, pid: self(), scene_ref: :replacement}},
      next_epoch: 13, opts: [route_module: Router]}
    assert {:reply, {:error, :stale_owner}, ^state} = QuicListener.handle_call(
      {:prepare_transfer, old, 2, %{id: 101}}, {self(), make_ref()}, state)
    assert {:reply, {:error, :stale_owner}, ^state} = QuicListener.handle_call(
      {:commit_transfer, old, fresh, 101}, {self(), make_ref()}, state)
    refute_receive {:prepared, _, _, _}
    refute_receive {:committed, _, _}
  end

  test "matching identity cannot prepare or commit from another Gate PID" do
    {old, fresh} = identities()
    state = %{characters: %{101 => %{identity: old, pid: self(), scene_ref: :source_scene}},
      next_epoch: 11, opts: [route_module: Router]}
    other = spawn(fn -> :ok end)
    assert {:reply, {:error, :stale_owner}, ^state} = QuicListener.handle_call(
      {:prepare_transfer, old, 2, %{id: 101}}, {other, make_ref()}, state)
    assert {:reply, {:error, :stale_owner}, ^state} = QuicListener.handle_call(
      {:commit_transfer, old, fresh, 101}, {other, make_ref()}, state)
    refute_receive {:prepared, _, _, _}
    refute_receive {:committed, _, _}
  end
end
