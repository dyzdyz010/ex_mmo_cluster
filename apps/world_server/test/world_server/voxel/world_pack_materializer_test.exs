defmodule WorldServer.Voxel.WorldPackMaterializerTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.WriteTokenStore
  alias DataService.Voxel.ChunkSnapshotStore
  alias WorldServer.Voxel.MapLedger
  alias WorldServer.Voxel.SceneNodeRegistry
  alias WorldServer.Voxel.WorldPackBootstrapper
  alias WorldServer.Voxel.WorldPackMaterializer

  defp unique_scene_id do
    920_000 + System.unique_integer([:positive])
  end

  defp start_ledger_with_registry do
    registry =
      start_supervised!(
        {SceneNodeRegistry,
         name: :"world_pack_materializer_registry_#{System.unique_integer([:positive])}"}
      )

    :ok = SceneNodeRegistry.register_scene_node(registry, node())

    ledger =
      start_supervised!(
        {MapLedger,
         name: :"world_pack_materializer_ledger_#{System.unique_integer([:positive])}",
         write_token_store: WriteTokenStore,
         scene_node_registry: registry}
      )

    {ledger, registry}
  end

  test "builds an inclusive chunk coordinate range" do
    assert WorldPackMaterializer.chunk_range({0, 0, 0}, {1, 1, 1}) == [
             {0, 0, 0},
             {0, 0, 1},
             {0, 1, 0},
             {0, 1, 1},
             {1, 0, 0},
             {1, 0, 1},
             {1, 1, 0},
             {1, 1, 1}
           ]
  end

  test "rejects invalid materialization options without raising" do
    assert {:error, {:missing_required_option, :logical_scene_id}} =
             WorldPackMaterializer.materialize_chunks(chunk_coords: [{0, 0, 0}])

    assert {:error, :invalid_chunk_coords} =
             WorldPackMaterializer.materialize_chunks(
               logical_scene_id: unique_scene_id(),
               chunk_coords: :bad
             )
  end

  test "routes chunks through the ledger and passes world lease fences to the materializer" do
    {ledger, _registry} = start_ledger_with_registry()
    scene_id = unique_scene_id()
    test_pid = self()

    materializer = fn logical_scene_id, chunk_coord, lease ->
      send(test_pid, {:materialize, logical_scene_id, chunk_coord, lease})

      case chunk_coord do
        {0, 0, 0} -> {:ok, :inserted}
        {8, 0, 0} -> {:ok, :updated}
      end
    end

    assert {:ok, summary} =
             WorldPackMaterializer.materialize_chunks(
               logical_scene_id: scene_id,
               chunk_coords: [{8, 0, 0}, {0, 0, 0}, {0, 0, 0}],
               ledger: ledger,
               materializer: materializer
             )

    assert summary.logical_scene_id == scene_id
    assert summary.chunk_count == 2
    assert summary.inserted == 1
    assert summary.updated == 1
    assert summary.unchanged == 0
    assert summary.errors == 0
    assert summary.chunk_errors == []

    assert_receive {:materialize, ^scene_id, {0, 0, 0}, lease_a}
    assert_receive {:materialize, ^scene_id, {8, 0, 0}, lease_b}

    assert lease_a.logical_scene_id == scene_id
    assert lease_b.logical_scene_id == scene_id
    assert lease_a.region_id != lease_b.region_id
    assert lease_a.lease_id != lease_b.lease_id

    assert :ok =
             WriteTokenStore.validate_write(%{
               logical_scene_id: scene_id,
               region_id: lease_a.region_id,
               chunk_coord: {0, 0, 0},
               lease_id: lease_a.lease_id,
               owner_scene_instance_ref: lease_a.owner_scene_instance_ref,
               owner_epoch: lease_a.owner_epoch
             })

    assert :ok =
             WriteTokenStore.validate_write(%{
               logical_scene_id: scene_id,
               region_id: lease_b.region_id,
               chunk_coord: {8, 0, 0},
               lease_id: lease_b.lease_id,
               owner_scene_instance_ref: lease_b.owner_scene_instance_ref,
               owner_epoch: lease_b.owner_epoch
             })
  end

  test "returns a structured failure summary when any chunk materialization fails" do
    {ledger, _registry} = start_ledger_with_registry()
    scene_id = unique_scene_id()

    materializer = fn _logical_scene_id, chunk_coord, _lease ->
      if chunk_coord == {0, 0, 0}, do: {:error, :write_failed}, else: {:ok, :inserted}
    end

    assert {:error, {:world_pack_materialization_failed, summary}} =
             WorldPackMaterializer.materialize_chunks(
               logical_scene_id: scene_id,
               chunk_coords: [{0, 0, 0}, {1, 0, 0}],
               ledger: ledger,
               materializer: materializer
             )

    assert summary.logical_scene_id == scene_id
    assert summary.chunk_count == 2
    assert summary.inserted == 1
    assert summary.errors == 1
    assert [%{chunk_coord: [0, 0, 0], error: ":write_failed"}] = summary.chunk_errors
  end

  test "fails visibly when the ledger cannot assign a scene owner" do
    registry =
      start_supervised!(
        {SceneNodeRegistry,
         name: :"world_pack_materializer_empty_registry_#{System.unique_integer([:positive])}"}
      )

    ledger =
      start_supervised!(
        {MapLedger,
         name: :"world_pack_materializer_empty_ledger_#{System.unique_integer([:positive])}",
         write_token_store: WriteTokenStore,
         scene_node_registry: registry}
      )

    assert {:error, {{0, 0, 0}, :scene_node_unassigned}} =
             WorldPackMaterializer.materialize_chunks(
               logical_scene_id: unique_scene_id(),
               chunk_coords: [{0, 0, 0}],
               ledger: ledger,
               materializer: fn _scene_id, _coord, _lease -> {:ok, :inserted} end
             )
  end

  test "world-pack bootstrapper materializes configured bounds in batches and publishes ready manifest" do
    previous_pack = Application.get_env(:auth_server, :voxel_world_pack, [])
    on_exit(fn -> Application.put_env(:auth_server, :voxel_world_pack, previous_pack) end)

    {ledger, _registry} = start_ledger_with_registry()
    scene_id = unique_scene_id()
    test_pid = self()

    materializer = fn logical_scene_id, chunk_coord, lease ->
      send(test_pid, {:bootstrap_materialize, logical_scene_id, chunk_coord, lease})
      {:ok, :inserted}
    end

    assert {:ok, summary} =
             WorldPackBootstrapper.materialize_once(
               logical_scene_id: scene_id,
               chunk_min: {0, 0, 0},
               chunk_max: {1, 0, 0},
               batch_size: 1,
               max_chunks: 2,
               ledger: ledger,
               materializer: materializer,
               version: "worldgen-test",
               content_version: "worldgen-test@bootstrap"
             )

    assert summary.logical_scene_id == scene_id
    assert summary.chunk_count == 2
    assert summary.batch_count == 2
    assert summary.inserted == 2
    assert summary.errors == 0

    assert_receive {:bootstrap_materialize, ^scene_id, {0, 0, 0}, lease_a}
    assert_receive {:bootstrap_materialize, ^scene_id, {1, 0, 0}, lease_b}
    assert lease_a.logical_scene_id == scene_id
    assert lease_b.logical_scene_id == scene_id

    pack = Application.get_env(:auth_server, :voxel_world_pack)
    assert pack[:status] == :ready
    assert pack[:version] == "worldgen-test"
    assert pack[:content_version] == "worldgen-test@bootstrap"
    assert pack[:generated].chunk_count == 2
    assert pack[:generated].summary.inserted == 2
  end

  test "world-pack bootstrapper refuses oversized ranges before materialization" do
    assert {:error, {:world_pack_chunk_count_exceeds_limit, 3, 2}} =
             WorldPackBootstrapper.materialize_once(
               logical_scene_id: unique_scene_id(),
               chunk_min: "0,0,0",
               chunk_max: "2,0,0",
               max_chunks: "2",
               publish_auth_pack?: false
             )
  end

  test "world-pack bootstrapper writes a real WorldGen snapshot through the default materializer" do
    {ledger, _registry} = start_ledger_with_registry()
    scene_id = unique_scene_id()

    assert {:ok, summary} =
             WorldPackBootstrapper.materialize_once(
               logical_scene_id: scene_id,
               chunk_min: {0, 0, 0},
               chunk_max: {0, 0, 0},
               batch_size: 1,
               max_chunks: 1,
               ledger: ledger,
               publish_auth_pack?: false
             )

    assert summary.inserted == 1
    assert summary.errors == 0

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(scene_id, {0, 0, 0})
    assert snapshot.logical_scene_id == scene_id
    assert snapshot.chunk_coord == {0, 0, 0}
    assert snapshot.chunk_version == 0
    assert byte_size(snapshot.data) > 1_000
    assert byte_size(snapshot.chunk_hash) == 8
  end
end
