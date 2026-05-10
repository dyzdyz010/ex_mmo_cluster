defmodule WorldServer.WorldSupResolverTest do
  # async: false because each test starts an isolated MapLedger +
  # SceneNodeRegistry pair under unique names. We pass them into the
  # resolver via the 2-arity `default_scene_opts_resolver/2` instead
  # of trying to shim the production `WorldServer.Voxel.MapLedger`
  # global name (which `mix test` already starts via the world_server
  # application).
  use ExUnit.Case, async: false

  alias WorldServer.Voxel.{MapLedger, SceneNodeRegistry}

  setup ctx do
    ledger_name = Module.concat([__MODULE__, ctx.test, Ledger])
    registry_name = Module.concat([__MODULE__, ctx.test, Registry])

    start_supervised!({SceneNodeRegistry, name: registry_name})

    start_supervised!({MapLedger, name: ledger_name, scene_node_registry: registry_name})

    %{ledger: ledger_name, registry: registry_name}
  end

  defp put_region(ledger, opts) do
    region_id = Keyword.fetch!(opts, :region_id)
    bounds_min = Keyword.get(opts, :bounds_chunk_min, {0, 0, 0})
    bounds_max = Keyword.get(opts, :bounds_chunk_max, {1, 1, 1})

    {:ok, _} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: 1,
        region_id: region_id,
        bounds_chunk_min: bounds_min,
        bounds_chunk_max: bounds_max,
        owner_scene_instance_ref: 1,
        owner_epoch: 0
      })
  end

  defp participant(region_id, lease_id) do
    %WorldServer.Voxel.TransactionParticipant{
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: 1,
      owner_epoch: 0,
      affected_chunks: []
    }
  end

  describe "default_scene_opts_resolver/2 (Phase A4-bis-4 段 2d)" do
    test "single participant, region assigned → resolved scene_node tuple", %{
      ledger: ledger,
      registry: registry
    } do
      :ok = SceneNodeRegistry.register_scene_node(registry, :a@h)
      put_region(ledger, region_id: 7_001)

      assert {:ok, [scene_opts_by_participant: opts]} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_001, 100)],
                 ledger: ledger
               )

      assert opts == %{
               {7_001, 100} => [chunk_directory: {SceneServer.Voxel.ChunkDirectory, :a@h}]
             }
    end

    test "multiple participants, different regions → each routed to its own scene_node",
         %{ledger: ledger, registry: registry} do
      :ok = SceneNodeRegistry.register_scene_node(registry, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(registry, :b@h)

      put_region(ledger,
        region_id: 7_101,
        bounds_chunk_min: {0, 0, 0},
        bounds_chunk_max: {1, 1, 1}
      )

      put_region(ledger,
        region_id: 7_102,
        bounds_chunk_min: {2, 0, 0},
        bounds_chunk_max: {3, 1, 1}
      )

      assert {:ok, [scene_opts_by_participant: opts]} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_101, 200), participant(7_102, 201)],
                 ledger: ledger
               )

      assert opts[{7_101, 200}] == [
               chunk_directory: {SceneServer.Voxel.ChunkDirectory, :a@h}
             ]

      assert opts[{7_102, 201}] == [
               chunk_directory: {SceneServer.Voxel.ChunkDirectory, :b@h}
             ]
    end

    test "all participants unresolved → :scene_unavailable", %{ledger: ledger} do
      # No scene_nodes registered; put_region succeeds but assigned_scene_node = nil.
      put_region(ledger, region_id: 7_201)

      assert {:error, :scene_unavailable} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_201, 300)],
                 ledger: ledger
               )
    end

    test "partial resolution: assigned + unassigned → returns assigned only, drops the rest",
         %{ledger: ledger, registry: registry} do
      :ok = SceneNodeRegistry.register_scene_node(registry, :a@h)

      put_region(ledger,
        region_id: 7_301,
        bounds_chunk_min: {6, 0, 0},
        bounds_chunk_max: {7, 1, 1}
      )

      :ok = SceneNodeRegistry.unregister_scene_node(registry, :a@h)

      put_region(ledger,
        region_id: 7_302,
        bounds_chunk_min: {8, 0, 0},
        bounds_chunk_max: {9, 1, 1}
      )

      assert {:ok, [scene_opts_by_participant: opts]} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_301, 400), participant(7_302, 401)],
                 ledger: ledger
               )

      assert Map.has_key?(opts, {7_301, 400})
      refute Map.has_key?(opts, {7_302, 401})
    end

    test "unknown region (never put) is treated as unresolved", %{ledger: ledger} do
      assert {:error, :scene_unavailable} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(99_999, 500)],
                 ledger: ledger
               )
    end
  end
end
