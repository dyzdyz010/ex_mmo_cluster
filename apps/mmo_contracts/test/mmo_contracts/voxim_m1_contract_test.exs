defmodule MmoContracts.VoximM1ContractTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Session.Codec
  alias MmoContracts.{Session, Movement, Voxel}
  @root Path.expand("../../../../../Voxim/Docs/M1", __DIR__)
  Code.require_file(Path.join(@root, "tools/capture_movement_wire.exs"))
  @fixtures Path.join(@root, "fixtures/movement-wire")

  defp replace(bytes, offset, value) do
    <<prefix::binary-size(^offset), _::binary-size(byte_size(^value)), rest::binary>> = bytes
    prefix <> value <> rest
  end

  defp packet(name) do
    {_, domain, value} = Enum.find(VoximM1Vectors.vectors(), &(elem(&1, 0) == name))
    {:ok, bytes} = VoximM1Vectors.encode(domain, value)
    {domain, value, bytes}
  end

  test "M1 rejects an unsupported envelope version at the network boundary" do
    assert Codec.decode(<<255, 0, 2, 1, 6, 0, 0, 0, 16, 0::128>>) ==
             {:error, :invalid_m1_message}
  end

  test "fixed slot scenarios share decoded data with S1 without a contracts slot runtime" do
    scenarios = Jason.decode!(File.read!(Path.join(@fixtures, "input-slot-scenarios.json")))
    assert scenarios["origin_tick"] == 100

    for scenario <- scenarios["scenarios"], event <- scenario["events"] do
      case event do
        %{"packet" => name} ->
          assert {:ok, %Movement.InputBatch{} = batch} =
                   Movement.Codec.decode(File.read!(Path.join(@fixtures, "elixir_#{name}.bin")))

          if name == "input_old_epoch" do
            assert batch.identity.session_epoch != VoximM1Vectors.identity().session_epoch
          else
            assert batch.identity == VoximM1Vectors.identity()
          end

        %{"ack" => name} ->
          assert {:ok, %Movement.OwnerAck{} = ack} =
                   Movement.Codec.decode(File.read!(Path.join(@fixtures, "elixir_#{name}.bin")))

          assert ack.server_tick == event["server_tick"]
          assert ack.processed_input_seq == event["expected_processed_input_seq"]
          assert ack.substituted_through_seq == event["expected_substituted_through_seq"]
      end
    end
  end

  test "profile identity helper exists before consumers implement identity" do
    assert byte_size(Codec.encode_profile(VoximM1Vectors.profile())) == 122

    assert Base.encode16(
             Codec.profile_id(VoximM1Vectors.profile(), VoximM1Vectors.blocking_hash()),
             case: :lower
           ) ==
             "83dc05376b0d77aa8d985969e33872cd1acc13c16b568460b76d0f29c05adc71"
  end

  test "all domain messages consume actual both-endpoint golden bytes and encode identically" do
    for {name, domain, value} <- VoximM1Vectors.vectors(), producer <- ["elixir", "ue"] do
      golden = File.read!(Path.join(@fixtures, "#{producer}_#{name}.bin"))
      assert {:ok, ^value} = VoximM1Vectors.decode(domain, golden)
      assert {:ok, ^golden} = VoximM1Vectors.encode(domain, value)
    end
  end

  test "every envelope rejects truncation extra bytes and wrong framing fields" do
    for {_name, domain, value} <- VoximM1Vectors.vectors() do
      {:ok, bytes} = VoximM1Vectors.encode(domain, value)

      for invalid <- [
            binary_part(bytes, 0, byte_size(bytes) - 1),
            bytes <> <<0>>,
            replace(bytes, 1, <<0, 2>>),
            replace(bytes, 3, <<4>>),
            replace(bytes, 4, <<255>>),
            replace(bytes, 5, <<0xFFFFFFFF::32>>)
          ] do
        assert {:error, :invalid_m1_message} = VoximM1Vectors.decode(domain, invalid)
      end
    end
  end

  test "state admits finite negative values and preserves both zero signs while all network f64 reject nonfinite" do
    {1, value, bytes} = packet("session_start")
    assert {:ok, ^value} = Codec.decode(bytes)
    assert binary_part(bytes, 121, 8) == <<0x8000000000000000::64>>
    assert binary_part(bytes, 129, 8) == <<0::64>>

    for offset <- Enum.map(0..5, &(89 + 8 * &1)) ++ Enum.map(0..14, &(140 + 8 * &1)),
        bad <- [0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000001] do
      assert {:error, :invalid_m1_message} = Codec.decode(replace(bytes, offset, <<bad::64>>))
    end

    {3, _, bootstrap} = packet("canonical_bootstrap")

    for offset <- Enum.map(0..5, &(81 + 8 * &1)) do
      assert {:error, :invalid_m1_message} =
               Voxel.Codec.decode_m1(replace(bootstrap, offset, <<0x7FF0000000000000::64>>))
    end

    assert {:error, :invalid_m1_message} = Codec.decode(replace(bytes, 137, <<2>>))
  end

  test "profile export normalizes signed zero but receive rejects noncanonical profile zero and wrong hz" do
    {1, _, bytes} = packet("session_start")
    profile = %{VoximM1Vectors.profile() | radius: -0.0}
    assert binary_part(Codec.encode_profile(profile), 0, 8) == <<0::64>>

    assert Codec.profile_id(profile, VoximM1Vectors.blocking_hash()) ==
             Codec.profile_id(%{profile | radius: 0.0}, VoximM1Vectors.blocking_hash())

    for offset <- Enum.map(0..14, &(140 + 8 * &1)) do
      assert {:error, :invalid_m1_message} =
               Codec.decode(replace(bytes, offset, <<0x8000000000000000::64>>))
    end

    assert {:error, :invalid_m1_message} = Codec.decode(replace(bytes, 260, <<59::16>>))
    {1, value, order} = packet("profile_order")
    assert {:ok, ^value} = Codec.decode(order)

    assert binary_part(order, 140, 122) ==
             IO.iodata_to_binary([for(i <- 1..15, do: <<i + 0.125::float-64>>), <<60::16>>])
  end

  test "input frame authority is only seq axes yaw jump and finite normalized axes" do
    {2, value, bytes} = packet("input_seq1")
    assert byte_size(bytes) == 9 + 24 + 1 + 11
    assert {:ok, ^value} = Movement.Codec.decode(bytes)
    {x, z} = Movement.Codec.axes(hd(value.frames))
    assert_in_delta x, -:math.sqrt(0.5), 1.0e-15
    assert_in_delta z, :math.sqrt(0.5), 1.0e-15

    for {offset, bad} <- [
          {38, <<-32768::signed-16>>},
          {40, <<-32768::signed-16>>},
          {44, <<2>>},
          {34, <<0::32>>},
          {33, <<0>>},
          {33, <<7>>}
        ] do
      assert {:error, :invalid_m1_message} = Movement.Codec.decode(replace(bytes, offset, bad))
    end

    for extra <- [<<1.0::float-64>>, <<1.0::float-64, 2.0::float-64, 3.0::float-64>>] do
      injected = replace(bytes <> extra, 5, <<byte_size(bytes) - 9 + byte_size(extra)::32>>)
      assert {:error, :invalid_m1_message} = Movement.Codec.decode(injected)
    end
  end

  test "ordered unique arrays reject duplicate and reversed sequences entities and chunks" do
    {2, input, _} = packet("input_gap")
    {2, snapshot, _} = packet("snapshot")
    {3, collision, _} = packet("collision_applied")

    for {domain, value} <- [
          {2, %{input | frames: Enum.reverse(input.frames)}},
          {2, %{input | frames: [hd(input.frames), hd(input.frames)]}},
          {2, %{snapshot | records: Enum.reverse(snapshot.records)}},
          {2, %{snapshot | records: [hd(snapshot.records), hd(snapshot.records)]}},
          {3, %{collision | changed_chunks: Enum.reverse(collision.changed_chunks)}},
          {3,
           %{
             collision
             | changed_chunks: [hd(collision.changed_chunks), hd(collision.changed_chunks)]
           }}
        ] do
      {:ok, bytes} = VoximM1Vectors.encode(domain, value)
      assert {:error, :invalid_m1_message} = VoximM1Vectors.decode(domain, bytes)
    end
  end

  test "bootstrap requires complete ordered box exact nested header N content coordinate and full length" do
    value = VoximM1Vectors.bootstrap()
    [{coord, payload} | tail] = value.regions
    {:ok, original, raw} = Voxel.Codec.decode_payload_body(payload)

    bad_payloads = [
      Voxel.Codec.encode_payload(0, coord, value.transaction_seq - 1, value.content_version, raw),
      Voxel.Codec.encode_payload(0, coord, value.transaction_seq, value.content_version + 1, raw),
      Voxel.Codec.encode_payload(1, coord, value.transaction_seq, value.content_version, raw),
      Voxel.Codec.encode_payload(0, {9, 8, 7}, value.transaction_seq, value.content_version, raw),
      binary_part(payload, 0, byte_size(payload) - 1),
      payload <> <<0>>,
      replace(payload, 45, <<2>>),
      replace(payload, 46, <<original.raw_bytes + 1::little-32>>)
    ]

    invalid = [
      %{value | regions: tail},
      %{value | regions: Enum.reverse(value.regions)},
      %{value | regions: [{coord, payload}, {coord, payload} | tl(tail)]}
    ]

    invalid = invalid ++ Enum.map(bad_payloads, &%{value | regions: [{coord, &1} | tail]})

    for bad <- invalid do
      {:ok, bytes} = Voxel.Codec.encode_m1(bad)
      assert {:error, :invalid_m1_message} = Voxel.Codec.decode_m1(bytes)
    end
  end

  test "InputStart uses fresh anchor A plus thirty fixed ticks and protocol constants" do
    {1, _, bytes} = packet("input_start")

    for {offset, invalid} <- [{108, <<241::64>>}, {116, <<2::32>>}, {120, <<7::16>>}] do
      assert {:error, :invalid_m1_message} = Codec.decode(replace(bytes, offset, invalid))
    end
  end

  test "yaw quarter turns and positive exact half turn have canonical Y-up semantics" do
    for {yaw, {x, z}} <- [{0, {1, 0}}, {16384, {0, 1}}, {32768, {-1, 0}}, {49152, {0, -1}}] do
      {fx, fy, fz} = Codec.yaw_forward(yaw)
      assert fy == 0.0
      assert_in_delta fx, x, 1.0e-15
      assert_in_delta fz, z, 1.0e-15
    end

    assert Codec.yaw_delta(0, 32768) == 32768
    assert Codec.yaw_delta(32768, 0) == 32768
    assert Codec.yaw_delta(65535, 0) == 1
  end

  test "reasons have exact authenticated and pre-auth representation and reserve unknown values" do
    for reason <- 1..12 do
      value = %Session.SessionEnd{identity: VoximM1Vectors.identity(), reason: reason}
      assert {:ok, bytes} = Codec.encode(value)
      assert {:ok, ^value} = Codec.decode(bytes)
      assert Codec.pre_auth_close(reason) == 0x10000 + reason
    end

    assert Codec.pre_auth_close(13) == 0x1000D
    {1, _, bytes} = packet("session_end_1")

    for bad <- [0, 13, 65535],
        do: assert({:error, :invalid_m1_message} = Codec.decode(replace(bytes, 33, <<bad::16>>)))

    {1, _, hello} = packet("hello")
    assert {:error, :invalid_m1_message} = Codec.decode(replace(hello, 9, <<2::16>>))
    {1, _, join} = packet("join")
    assert {:error, :invalid_m1_message} = Codec.decode(replace(join, 19, <<255>>))
  end

  test "canonical snapshot delta and occupancy are immutable value structs without runtime ownership" do
    chunk = %Voxel.ChunkOccupancy{
      coord: {-4, 28, -3},
      n: 16,
      scale_m: 1.0,
      origin_m: {-64.0, 448.0, -48.0},
      cells: :binary.copy(<<0>>, 16 * 16 * 16)
    }

    snapshot = %Voxel.CanonicalSnapshot{
      content_version: 3,
      transaction_seq: 99,
      l0_min: {-1, 7, -1},
      l0_max_exclusive: {1, 9, 1},
      regions: [],
      chunks: [chunk]
    }

    delta = %Voxel.CanonicalDelta{
      transaction_seq: 100,
      transaction: %{seq: 100, entries: [], coarse: []},
      chunks: [
        %{chunk | cells: <<1, binary_part(chunk.cells, 1, byte_size(chunk.cells) - 1)::binary>>}
      ]
    }

    assert hd(snapshot.chunks).cells != hd(delta.chunks).cells
    assert :binary.at(hd(snapshot.chunks).cells, 0) == 0

    assert Map.keys(delta) |> Enum.sort() == [
             :__struct__,
             :chunks,
             :transaction,
             :transaction_seq
           ]
  end

  test "nested R6 body rejects zero map extent, wrong field extent and ignored trailing bytes" do
    bootstrap = VoximM1Vectors.bootstrap()
    [{coord, payload} | tail] = bootstrap.regions
    {:ok, _, raw} = Voxel.Codec.decode_payload_body(payload)
    extent_offset = 4 + Voxel.Payload.extent() ** 3 * 2

    for bad_raw <- [
          raw <> <<0>>,
          replace(raw, extent_offset, <<-1::little-signed-32>>),
          replace(raw, extent_offset + 12, <<0::32>>)
        ] do
      bad_payload =
        Voxel.Codec.encode_payload(
          0,
          coord,
          bootstrap.transaction_seq,
          bootstrap.content_version,
          bad_raw
        )

      {:ok, bytes} = Voxel.Codec.encode_m1(%{bootstrap | regions: [{coord, bad_payload} | tail]})
      assert {:error, :invalid_m1_message} = Voxel.Codec.decode_m1(bytes)
    end
  end
end
