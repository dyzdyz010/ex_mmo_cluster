defmodule WorldServer.Voxel.MapLedgerSceneNodeAssignTest do
  # async: false because some assertions touch global named processes
  # (the registry instance has to be addressable across the
  # MapLedger ↔ SceneNodeRegistry hop).
  use ExUnit.Case, async: false

  alias WorldServer.Voxel.{MapLedger, SceneNodeRegistry}

  describe "scene_node_registry not configured (legacy / single-node)" do
    test "put_region succeeds with assigned_scene_node = nil" do
      ledger = start_supervised!({MapLedger, name: __MODULE__.NoRegistry.Ledger})

      assert {:ok, assignment} =
               MapLedger.put_region(ledger, %{
                 logical_scene_id: 1,
                 region_id: 9_001,
                 bounds_chunk_min: {0, 0, 0},
                 bounds_chunk_max: {1, 1, 1},
                 owner_scene_instance_ref: 1,
                 owner_epoch: 0
               })

      assert assignment.assigned_scene_node == nil
    end
  end

  describe "scene_node_registry configured (Phase A4-bis-4 段 2c)" do
    setup do
      registry = start_supervised!({SceneNodeRegistry, name: __MODULE__.WithRegistry.Registry})

      ledger =
        start_supervised!(
          {MapLedger,
           name: __MODULE__.WithRegistry.Ledger,
           scene_node_registry: __MODULE__.WithRegistry.Registry}
        )

      %{registry: registry, ledger: ledger}
    end

    test "no scene_nodes registered: put_region succeeds with assigned_scene_node = nil",
         %{ledger: ledger} do
      assert {:ok, assignment} = put_region(ledger, region_id: 9_101)
      assert assignment.assigned_scene_node == nil
    end

    test "single scene_node: put_region pins all regions to that node", %{ledger: ledger} do
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :a@h)

      assert {:ok, a1} =
               put_region(ledger,
                 region_id: 9_201,
                 bounds_chunk_min: {10, 0, 0},
                 bounds_chunk_max: {11, 1, 1}
               )

      assert {:ok, a2} =
               put_region(ledger,
                 region_id: 9_202,
                 bounds_chunk_min: {12, 0, 0},
                 bounds_chunk_max: {13, 1, 1}
               )

      assert a1.assigned_scene_node == :a@h
      assert a2.assigned_scene_node == :a@h
    end

    test "multiple scene_nodes: put_region round-robins via SceneNodeRegistry (D8.B)",
         %{ledger: ledger} do
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :b@h)
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :c@h)

      assert {:ok, a1} =
               put_region(ledger,
                 region_id: 9_301,
                 bounds_chunk_min: {20, 0, 0},
                 bounds_chunk_max: {21, 1, 1}
               )

      assert {:ok, a2} =
               put_region(ledger,
                 region_id: 9_302,
                 bounds_chunk_min: {22, 0, 0},
                 bounds_chunk_max: {23, 1, 1}
               )

      assert {:ok, a3} =
               put_region(ledger,
                 region_id: 9_303,
                 bounds_chunk_min: {24, 0, 0},
                 bounds_chunk_max: {25, 1, 1}
               )

      assert {:ok, a4} =
               put_region(ledger,
                 region_id: 9_304,
                 bounds_chunk_min: {26, 0, 0},
                 bounds_chunk_max: {27, 1, 1}
               )

      assert a1.assigned_scene_node == :a@h
      assert a2.assigned_scene_node == :b@h
      assert a3.assigned_scene_node == :c@h
      # Wraps.
      assert a4.assigned_scene_node == :a@h
    end

    test "re-putting same region_id keeps the original assigned_scene_node (idempotent)",
         %{ledger: ledger} do
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :b@h)

      assert {:ok, first} =
               put_region(ledger,
                 region_id: 9_401,
                 bounds_chunk_min: {30, 0, 0},
                 bounds_chunk_max: {31, 1, 1}
               )

      assert first.assigned_scene_node == :a@h

      # Re-put the SAME region (same bounds, same id). SceneNodeRegistry's
      # assign_region/2 is idempotent — region 9_401 → :"a@h" frozen.
      assert {:ok, second} =
               put_region(ledger,
                 region_id: 9_401,
                 bounds_chunk_min: {30, 0, 0},
                 bounds_chunk_max: {31, 1, 1}
               )

      assert second.assigned_scene_node == :a@h

      # And the next *new* region picks :"b@h" (cursor wasn't advanced
      # by the duplicate put above).
      assert {:ok, third} =
               put_region(ledger,
                 region_id: 9_402,
                 bounds_chunk_min: {32, 0, 0},
                 bounds_chunk_max: {33, 1, 1}
               )

      assert third.assigned_scene_node == :b@h
    end

    test "explicit assigned_scene_node in attrs wins over registry assignment", %{ledger: ledger} do
      :ok = SceneNodeRegistry.register_scene_node(__MODULE__.WithRegistry.Registry, :a@h)

      # Caller pinned a specific scene_node — registry-driven default
      # round-robin must NOT clobber it.
      assert {:ok, assignment} =
               MapLedger.put_region(ledger, %{
                 logical_scene_id: 1,
                 region_id: 9_501,
                 bounds_chunk_min: {40, 0, 0},
                 bounds_chunk_max: {41, 1, 1},
                 owner_scene_instance_ref: 1,
                 owner_epoch: 0,
                 assigned_scene_node: :explicit@h
               })

      assert assignment.assigned_scene_node == :explicit@h
    end
  end

  defp put_region(ledger, opts) do
    region_id = Keyword.fetch!(opts, :region_id)
    bounds_min = Keyword.get(opts, :bounds_chunk_min, {0, 0, 0})
    bounds_max = Keyword.get(opts, :bounds_chunk_max, {1, 1, 1})

    MapLedger.put_region(ledger, %{
      logical_scene_id: 1,
      region_id: region_id,
      bounds_chunk_min: bounds_min,
      bounds_chunk_max: bounds_max,
      owner_scene_instance_ref: 1,
      owner_epoch: 0
    })
  end
end
