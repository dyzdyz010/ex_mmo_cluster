defmodule WorldServer.MovementRouteTest do
  use ExUnit.Case, async: false

  alias GateServer.Session.{Dispatch, Sink}
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.{GeneratedStore, World}

  setup do
    root = Path.join(System.tmp_dir!(), "voxim_w1_route_#{System.unique_integer([:positive])}")
    manifest = Path.expand("../../../../Voxim/Docs/R6/runtime/s4_worldgen_manifest.json", __DIR__)
    opts = [source: GeneratedStore, root: root, manifest_path: manifest]

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

  test "Gate R6 subscription and both edit paths retain the configured world_ref", %{route: route} do
    initial = %{status: :in_scene, cid: 55, sink: Sink.ws(self())}
    sub = %{have_seq: 0, box: {{0, 1000, 0}, {0, 1000, 0}}, coarse_min_level: 1}
    assert {:ok, state} = Dispatch.handle({:voxel_overlay_subscribe, sub}, initial)
    assert state.world_ref == route.world_ref

    request = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 7,
      edits: [{{1, 64_001, 1}, 11}]
    }

    assert {:ok, ^state} = Dispatch.handle({:voxel_batch_edit_intent, request}, state)
    assert World.seq(route.world_ref) == 1
    assert_receive {:voxel_log_transaction_payload, transaction}
    assert {:ok, %{seq: 1}} = Codec.decode_transaction(transaction)

    request = %{
      request_id: 2,
      client_intent_seq: 2,
      logical_scene_id: 7,
      target_world_micro: {8, 512_008, 8},
      material_id: 0
    }

    assert {:ok, ^state} = Dispatch.handle({:voxel_edit_intent, request}, state)
    assert World.seq(route.world_ref) == 2
    assert_receive {:voxel_log_entry_payload, entry}
    assert {:ok, %{seq: 2, material: 0}} = Codec.decode_entry(entry)
    assert World.seq(VoxelRegion.World) == 0
  end
end
