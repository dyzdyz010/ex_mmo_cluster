Code.require_file("../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule GateServer.MovementRouteTest do
  use ExUnit.Case, async: false

  alias GateServer.Session.{Dispatch, Sink}
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.World

  setup do
    root = Path.join(System.tmp_dir!(), "voxim_w1_route_#{System.unique_integer([:positive])}")

    # 只测试路由：显式空气数据源保留真实 World/HTTP/Gate 接缝，不依赖发布世界的烘焙版本。
    opts = [source: VoxelRegion.TestSupport.Source, root: root, observer: self()]

    start_supervised!(
      Supervisor.child_spec({World, opts ++ [name: :w1_route_world]}, id: :routed)
    )

    start_supervised!(
      Supervisor.child_spec({World, Keyword.put(opts, :root, root <> "_decoy")}, id: :decoy)
    )

    route = %{
      scene_ref: {:w1_scene, node()},
      world_ref: {:w1_route_world, node()},
      scene_epoch: 9
    }

    config = [
      {:world_server, :movement_routes, %{7 => route}},
      {:gate_server, :voxel_scene_id, 7},
      {:auth_server, :voxel_scene_id, 7},
      {:auth_server, :dev_auto_login, true}
    ]

    previous =
      for {app, key, value} <- config do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      File.rm_rf!(root)
      File.rm_rf!(root <> "_decoy")
    end)

    {:ok, route: route}
  end

  test "explicit named route and Auth HTTP read the nondefault World despite a local decoy", %{
    route: route
  } do
    assert {:ok, ^route} = WorldServer.Movement.route(7)
    assert {:error, :scene_unavailable} = WorldServer.Movement.route(999)
    assert {:ok, 1} = World.apply_edits(route.world_ref, [{{1, 64_001, 1}, 11}])

    request =
      Codec.encode_request(0, [%{level: 0, region: {0, 1000, 0}, have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()

    conn =
      Plug.Test.conn(:post, "/ingame/voxel/regions", request)
      |> AuthServerWeb.IngameController.voxel_regions(%{})

    assert conn.status == 200
    assert {:ok, _, [{:payload, 0, {0, 1000, 0}, bytes}]} = Codec.decode_reply(conn.resp_body)
    assert {:ok, payload} = Payload.decode(bytes)
    assert Payload.material(payload, {2, 2, 2}) == 11
    assert World.seq(VoxelRegion.World) == 0
  end

  # 上下文与 QuicConnection 编辑 worker 收到的相同：world_ref 取自配置路由。原始编辑以会话角色身份交给 World，
  # 由 `VoxelRegion.Access` 拒绝（原始编辑只给运维与创世 NPC）：回 forbidden 帧，不产生任何提交。
  test "player raw edits on both Voxim paths are refused by World authorization", %{route: route} do
    alias GateServer.Voxel.ResultFrame

    state = %{
      status: :in_scene,
      cid: 55,
      voxim_overlay: true,
      world_ref: route.world_ref,
      sink: Sink.quic(self(), :edit)
    }

    batch = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 7,
      edits: [{{1, 64_001, 1}, 11}]
    }

    single = %{
      request_id: 2,
      client_intent_seq: 2,
      logical_scene_id: 7,
      target_world_micro: {8, 512_008, 8},
      material_id: 0
    }

    for {kind, request} <- [voxel_batch_edit_intent: batch, voxel_edit_intent: single] do
      assert {:ok, ^state} = Dispatch.handle({kind, request}, state)
      assert_receive {:mmo_voxel_bytes, :edit, bytes}
      {:ok, expected} = ResultFrame.error(request, :forbidden) |> Codec.encode()
      assert bytes == IO.iodata_to_binary(expected)
    end

    assert World.seq(route.world_ref) == 0
    assert World.seq(VoxelRegion.World) == 0
  end
end
