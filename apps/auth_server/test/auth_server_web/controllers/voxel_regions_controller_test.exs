defmodule AuthServerWeb.VoxelRegionsControllerTest do
  use AuthServerWeb.ConnCase, async: false

  alias MmoContracts.Voxel.Codec, as: RegionCodec

  @content_version 0x5F84_4009_CA44_A605

  setup do
    {:ok, _auth_started} = Application.ensure_all_started(:auth_server)

    previous_auto_login = Application.get_env(:auth_server, :dev_auto_login, false)
    previous_routes = Application.fetch_env(:world_server, :movement_routes)
    previous_scene = Application.fetch_env(:auth_server, :voxel_scene_id)

    root = Path.join(System.tmp_dir!(), "voxim_regions_test_#{System.unique_integer([:positive])}")
    world = Path.join(root, Base.encode16(<<@content_version::64>>, case: :lower))
    File.mkdir_p!(Path.join(world, "L1"))
    File.mkdir_p!(Path.join(world, "L0"))

    payload = RegionCodec.encode_payload(1, {0, 1, 0}, 0, @content_version, :binary.copy(<<7, 0>>, 66 * 66 * 66))
    File.write!(Path.join([world, "L1", "r_0_1_0.vxr"]), payload)
    # 头对不上路径的文件：按 missing 处理，不吐脏数据。
    File.write!(Path.join([world, "L0", "r_5_5_5.vxr"]), RegionCodec.encode_payload(1, {0, 1, 0}, 0, @content_version, "x"))

    Application.put_env(:auth_server, :dev_auto_login, true)
    start_supervised!({VoxelRegion.World, root: root, name: :voxim_http_regions_test})
    Application.put_env(:auth_server, :voxel_scene_id, 7)
    Application.put_env(:world_server, :movement_routes, %{
      7 => %{scene_ref: {:voxim_http_scene, node()}, world_ref: {:voxim_http_regions_test, node()}, scene_epoch: 1}
    })

    on_exit(fn ->
      Application.put_env(:auth_server, :dev_auto_login, previous_auto_login)
      for {app, key, value} <- [{:world_server, :movement_routes, previous_routes}, {:auth_server, :voxel_scene_id, previous_scene}] do
        case value do
          {:ok, old} -> Application.put_env(app, key, old)
          :error -> Application.delete_env(app, key)
        end
      end
      File.rm_rf!(root)
    end)

    {:ok, payload: payload}
  end

  defp request(items, content_version) do
    body =
      Enum.map(items, fn {level, {x, y, z}, have_seq, have_hash} ->
        <<level::8, x::32-little-signed, y::32-little-signed, z::32-little-signed, have_seq::64-little, have_hash::64-little>>
      end)

    IO.iodata_to_binary([<<"VXRQ", 1::32-little, content_version::64-little, length(items)::32-little>> | body])
  end

  defp post_regions(conn, bytes) do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> post(~p"/ingame/voxel/regions", bytes)
  end

  test "first fetch returns the payload file byte for byte, unknown regions are missing", %{conn: conn, payload: payload} do
    conn = post_regions(conn, request([{1, {0, 1, 0}, 0, 0}, {1, {9, 9, 9}, 0, 0}, {0, {5, 5, 5}, 0, 0}], 0))
    assert conn.status == 200
    assert {:ok, @content_version, items} = RegionCodec.decode_reply(conn.resp_body)
    assert [{:payload, 1, {0, 1, 0}, ^payload}, {:missing, 1, {9, 9, 9}}, {:missing, 0, {5, 5, 5}}] = items
  end

  test "matching (seq, hash) under the same content_version is unchanged; anything else is a payload", %{conn: conn, payload: payload} do
    {:ok, header} = RegionCodec.decode_payload_header(payload)

    conn1 = post_regions(conn, request([{1, {0, 1, 0}, header.seq, header.hash}], @content_version))
    assert {:ok, _, [{:unchanged, 1, {0, 1, 0}}]} = RegionCodec.decode_reply(conn1.resp_body)

    conn2 = post_regions(conn, request([{1, {0, 1, 0}, header.seq, header.hash + 1}], @content_version))
    assert {:ok, _, [{:payload, 1, {0, 1, 0}, ^payload}]} = RegionCodec.decode_reply(conn2.resp_body)

    # 客户端拿着别的 content_version 的副本：hash 再对也要重发。
    conn3 = post_regions(conn, request([{1, {0, 1, 0}, header.seq, header.hash}], 42))
    assert {:ok, _, [{:payload, 1, {0, 1, 0}, ^payload}]} = RegionCodec.decode_reply(conn3.resp_body)
  end

  test "bad frames are 400 and the endpoint is gated by dev_auto_login", %{conn: conn} do
    assert post_regions(conn, "garbage").status == 400

    Application.put_env(:auth_server, :dev_auto_login, false)
    conn = post_regions(conn, request([], 0))
    assert conn.status == 403
  end

  test "payload header round-trips through the codec", %{payload: payload} do
    assert {:ok, header} = RegionCodec.decode_payload_header(payload)
    assert header.level == 1
    assert header.region == {0, 1, 0}
    assert header.content_version == @content_version
    assert header.encoding == 1
    assert header.raw_bytes == 2 * 66 * 66 * 66
    assert byte_size(payload) == RegionCodec.payload_header_bytes() + header.body_bytes
  end
end
