# G0 在抽取前直接加载原 codec；不为测试给纯合同 app 增加运行时依赖。
unless Process.whereis(ExUnit.Server), do: ExUnit.start()

for {module, path} <- [
      {VoxelRegion.Reducer, "../../../voxel_region/lib/voxel_region/reducer.ex"},
      {VoxelRegion.Codec, "../../../voxel_region/lib/voxel_region/codec.ex"},
      {VoxelRegion.Payload, "../../../voxel_region/lib/voxel_region/payload.ex"},
      {GateServer.Codec, "../../../gate_server/lib/gate_server/codec.ex"}
    ] do
  unless Code.ensure_loaded?(module), do: Code.require_file(Path.expand(path, __DIR__))
end

defmodule MmoContracts.VoximCurrentWireVectors do
  @moduledoc false
  @rid 0x0102030405060708
  @seq 0x1122334455667788
  @cv 0x8877665544332211
  @stale_cv 0x7766554433221109
  def root,
    do:
      System.get_env("VOXIM_CURRENT_WIRE") ||
        Path.expand("../../../../../Voxim/Docs/M1/fixtures/current-wire", __DIR__)

  def fixture(name), do: File.read!(Path.join(root(), name <> ".bin"))

  def skins(ext),
    do:
      {ext,
       List.to_tuple(
         for f <- 0..5,
             do:
               {f + 1,
                if(ext == 1,
                  do: nil,
                  else: :binary.list_to_bin(for t <- 0..(ext * ext - 1), do: rem(t + f, 7))
                )}
       )}

  def coarse(ext),
    do: %{
      level: if(ext == 1, do: 3, else: div(ext, 2)),
      cell: {-17, 3, -65},
      material: 2,
      skins: skins(ext)
    }

  def cell,
    do: %{seq: @seq, coord: {-129, -2, 65}, material: 3, coarse: Enum.map([1, 2, 4], &coarse/1)}

  def payload do
    p =
      struct(VoxelRegion.Payload,
        level: 1,
        region: {-2, 3, -4},
        map_extent: 2,
        cells: :binary.copy(<<2::16-little>>, 66 * 66 * 66)
      )

    VoxelRegion.Payload.encode(p, %{{1, 2, 3} => {3, skins(2)}}, @seq, @cv)
  end

  def transaction,
    do: %{
      seq: @seq,
      entries: [%{cell() | coarse: []}, %{seq: @seq, payload: payload()}],
      coarse: Enum.map([1, 2, 4], &coarse/1)
    }

  def requests,
    do: [
      %{level: 0, region: {-2, 3, -4}, have_seq: @seq, have_hash: 0x1020304050607080},
      %{level: 3, region: {5, -6, 7}, have_seq: 0, have_hash: 0}
    ]

  def replies,
    do: [
      {:unchanged, 0, {-2, 3, -4}},
      {:missing, 3, {5, -6, 7}},
      {:payload, 1, {-2, 3, -4}, payload()},
      {:entries, 0, {-3, -2, -1}, [transaction()]}
    ]

  def mismatch_requests,
    do: [%{level: 1, region: {-2, 3, -4}, have_seq: @seq, have_hash: 0x3E9050FD6AD2607D}]

  # World.serve_item 的两个增量分支都要求版本相等；旧非零版本即使 seq/hash 命中也返回完整载荷。
  def mismatch do
    %{
      "region_request_stale_nonzero" =>
        IO.iodata_to_binary(VoxelRegion.Codec.encode_request(@stale_cv, mismatch_requests())),
      "region_reply_stale_full_payload" =>
        IO.iodata_to_binary(
          VoxelRegion.Codec.encode_reply(@cv, [{:payload, 1, {-2, 3, -4}, payload()}])
        )
    }
  end

  def intent_result(code, rid \\ @rid),
    do:
      {:voxel_intent_result,
       %{
         request_id: rid,
         client_intent_seq: 0x12345678,
         logical_scene_id: 0x1020304050607080,
         result_code: code,
         result_ref: @seq,
         authoritative: [],
         reason: if(code == :accepted, do: "", else: "denied")
       }}

  def gate(message) do
    {:ok, bytes} = GateServer.Codec.encode(message)
    IO.iodata_to_binary(bytes)
  end

  def server do
    basic = %{
      "auth_ok" => gate({:result, :ok, @rid}),
      "auth_error" => gate({:result, :error, @rid}),
      "enter_ok" => gate({:enter_scene_result, :ok, @rid, {-125.5, 256.25, -3.75}, 0x12345678}),
      "enter_error" => gate({:enter_scene_result, :error, @rid}),
      "heartbeat_reply" => gate({:heartbeat_reply, @seq}),
      "batch_result" => gate(intent_result(:accepted, @rid + 1)),
      "log_cell" => IO.iodata_to_binary(VoxelRegion.Codec.encode_entry(cell())),
      "log_region" =>
        IO.iodata_to_binary(VoxelRegion.Codec.encode_entry(%{seq: @seq, payload: payload()})),
      "transaction" => IO.iodata_to_binary(VoxelRegion.Codec.encode_transaction(transaction())),
      "region_payload" => payload(),
      "region_request" => IO.iodata_to_binary(VoxelRegion.Codec.encode_request(@cv, requests())),
      "region_request_unknown" =>
        IO.iodata_to_binary(VoxelRegion.Codec.encode_request(0, requests())),
      "region_reply" => IO.iodata_to_binary(VoxelRegion.Codec.encode_reply(@cv, replies()))
    }

    {:ok, _, raw} = VoxelRegion.Codec.decode_payload_body(basic["region_payload"])

    basic =
      Map.merge(basic, %{
        "region_body" => raw,
        "gate_log_cell" => gate({:voxel_log_entry_payload, basic["log_cell"]}),
        "gate_log_region" => gate({:voxel_log_entry_payload, basic["log_region"]}),
        "gate_transaction" => gate({:voxel_log_transaction_payload, basic["transaction"]})
      })

    Enum.reduce([:accepted, :deferred, :rejected, :stale], basic, fn code, acc ->
      Map.put(acc, "intent_#{code}", gate(intent_result(code)))
    end)
  end
end

if capture = System.get_env("M1_CAPTURE_SERVER") do
  File.mkdir_p!(capture)

  for {name, bytes} <- MmoContracts.VoximCurrentWireVectors.server(),
      do: File.write!(Path.join(capture, name <> ".bin"), bytes, [:exclusive])
end

if capture = System.get_env("M1_CAPTURE_MISMATCH") do
  for {name, bytes} <- MmoContracts.VoximCurrentWireVectors.mismatch(),
      do: File.write!(Path.join(capture, name <> ".bin"), bytes, [:exclusive])
end

defmodule MmoContracts.VoximCurrentWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.VoximCurrentWireVectors, as: V
  @rid 0x0102030405060708
  @seq 0x1122334455667788
  @cv 0x8877665544332211
  @stale_cv 0x7766554433221109

  test "pre-extraction server serializers equal frozen bytes" do
    for {name, bytes} <- V.server(), do: assert(bytes == V.fixture(name), name)
  end

  test "UE session captures decode to independent values" do
    assert GateServer.Codec.decode(V.fixture("auth_request")) ==
             {:ok, {:auth_request, "golden-体素", "token-\u00e9", @rid}}

    assert GateServer.Codec.decode(V.fixture("enter_request")) ==
             {:ok, {:enter_scene, 0x1020304050607080, @rid}}

    assert GateServer.Codec.decode(V.fixture("heartbeat_request")) == {:ok, {:heartbeat, @seq}}
  end

  test "UE edit captures preserve signed micro versus macro and every fixed field" do
    for {name, material, action} <- [{"edit_place", 3, 1}, {"edit_remove", 0, 0}] do
      assert GateServer.Codec.decode(V.fixture(name)) ==
               {:ok,
                {:voxel_edit_intent,
                 %{
                   request_id: @rid,
                   client_intent_seq: 0x12345678,
                   logical_scene_id: 0x1020304050607080,
                   action: action,
                   target_granularity: 0,
                   target_world_micro: {-1028, -12, 524},
                   face_normal: {0, 1, 0},
                   material_id: material,
                   blueprint_ref: 0,
                   object_ref: 0,
                   part_ref: 0,
                   attribute_patch_ref: 0,
                   expected_chunk_version: 0xFFFFFFFFFFFFFFFF,
                   expected_cell_hash: 0,
                   client_hint_hash: 0
                 }}}
    end

    assert GateServer.Codec.decode(V.fixture("batch_edit")) ==
             {:ok,
              {:voxel_batch_edit_intent,
               %{
                 request_id: @rid + 1,
                 client_intent_seq: 0x12345678,
                 logical_scene_id: 0x1020304050607080,
                 edits: [{{-129, -2, 65}, 3}, {{17, -33, -1}, 0}]
               }}}

    assert GateServer.Codec.decode(V.fixture("subscribe")) ==
             {:ok,
              {:voxel_overlay_subscribe,
               %{have_seq: @seq, box: {{-130, -66, -2}, {64, 128, 192}}, coarse_min_level: 3}}}
  end

  test "frozen little endian logs and HTTP preserve versions and skins" do
    for {name, bytes} <- V.mismatch(), do: assert(bytes == V.fixture(name), name)

    assert VoxelRegion.Codec.decode_request(V.fixture("region_request_stale_nonzero")) ==
             {:ok, @stale_cv, V.mismatch_requests()}

    {:ok, server_cv, [{:payload, 1, {-2, 3, -4}, full_payload}]} =
      VoxelRegion.Codec.decode_reply(V.fixture("region_reply_stale_full_payload"))

    assert server_cv == @cv
    assert @stale_cv != 0 and server_cv != @stale_cv
    assert full_payload == V.fixture("region_payload")
    {:ok, header, body} = VoxelRegion.Codec.decode_payload_body(full_payload)

    assert {header.content_version, header.seq, header.hash} ==
             {@cv, @seq, hd(V.mismatch_requests()).have_hash}

    assert body == V.fixture("region_body")

    assert VoxelRegion.Codec.decode_entry(V.fixture("log_cell")) == {:ok, V.cell()}

    assert VoxelRegion.Codec.decode_transaction(V.fixture("transaction")) ==
             {:ok, V.transaction()}

    assert VoxelRegion.Codec.decode_request(V.fixture("region_request")) ==
             {:ok, @cv, V.requests()}

    assert VoxelRegion.Codec.decode_request(V.fixture("region_request_unknown")) ==
             {:ok, 0, V.requests()}

    assert VoxelRegion.Codec.decode_reply(V.fixture("region_reply")) == {:ok, @cv, V.replies()}

    for name <- ["region_payload", "ue_region_payload"] do
      {:ok, _, raw} = VoxelRegion.Codec.decode_payload_body(V.fixture(name))
      assert raw == V.fixture("region_body")
      {:ok, p} = VoxelRegion.Payload.decode(V.fixture(name))
      assert {p.level, p.region, p.seq, p.content_version} == {1, {-2, 3, -4}, @seq, @cv}
      assert VoxelRegion.Payload.value(p, {1, 2, 3}) == {3, V.skins(2)}
      assert VoxelRegion.Payload.material(p, {0, 0, 0}) == 2
    end
  end
end
