defmodule SceneServer.InterfaceAnnounceTest do
  # async: false — touches BeaconServer.DistributedRegistry singleton
  # and `WorldServer.Voxel.SceneNodeRegistry` global names; serialise.
  use ExUnit.Case, async: false

  # `WorldServer.Voxel.SceneNodeRegistry` lives in world_server, but
  # scene_server intentionally does NOT depend on world_server in its
  # mix.exs. We reference it by atom literal here for the same reason
  # `SceneServer.Interface` does — Elixir compiler doesn't check that
  # the module exists when used as a bare atom.
  @scene_node_registry_module :"Elixir.WorldServer.Voxel.SceneNodeRegistry"

  setup ctx do
    # Each test uses a freshly-named registry to avoid bleeding state
    # across tests on the same singleton process. Use a `via` tuple
    # name so we don't clash with the production-default name in case
    # other tests somehow start it.
    registry_name =
      Module.concat([__MODULE__, ctx.test, Registry])

    start_supervised!({@scene_node_registry_module, name: registry_name})

    # Each test also picks a unique BeaconServer key so concurrent
    # tests in the same module file (although async: false here, this
    # also defends against later turning async on) don't collide.
    world_key = Module.concat([__MODULE__, ctx.test, World])

    on_exit(fn -> BeaconServer.Client.unregister(world_key) end)

    %{registry_name: registry_name, world_key: world_key}
  end

  test "same-BEAM announce: World registered → registry receives node()", %{
    registry_name: registry_name,
    world_key: world_key
  } do
    # Pretend "World node" is *us* (single-BEAM dev / mix test mode).
    :ok = BeaconServer.Client.register(world_key)

    assert :ok =
             SceneServer.Interface.announce_to_world(
               world_resource: world_key,
               registry_module: @scene_node_registry_module,
               registry_name: registry_name,
               # Allow Horde CRDT to settle the World registration.
               await_timeout_ms: 1_000,
               rpc_timeout_ms: 1_000
             )

    # SceneNodeRegistry on this BEAM should have received `node()`.
    snapshot = apply(@scene_node_registry_module, :snapshot, [registry_name])
    assert node() in snapshot.join_order
  end

  test "World unavailable → soft-fail with :timeout, no crash, no register", %{
    registry_name: registry_name,
    world_key: world_key
  } do
    # Don't register `world_key` in BeaconServer — await will time out.
    assert :ok =
             SceneServer.Interface.announce_to_world(
               world_resource: world_key,
               registry_module: @scene_node_registry_module,
               registry_name: registry_name,
               await_timeout_ms: 100,
               rpc_timeout_ms: 1_000
             )

    snapshot = apply(@scene_node_registry_module, :snapshot, [registry_name])
    assert snapshot.join_order == []
  end
end
