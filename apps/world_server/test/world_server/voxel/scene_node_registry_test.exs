defmodule WorldServer.Voxel.SceneNodeRegistryTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.SceneNodeRegistry

  defp start_registry!(ctx) do
    name = Module.concat([__MODULE__, ctx.test])
    pid = start_supervised!({SceneNodeRegistry, name: name})
    %{registry: pid, name: name}
  end

  setup ctx, do: start_registry!(ctx)

  describe "join_order tracking" do
    test "empty after start", %{name: name} do
      assert %{join_order: [], region_assignments: %{}} =
               SceneNodeRegistry.snapshot(name)
    end

    test "register appends in first-registration order", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :c@h)

      assert %{join_order: [:a@h, :b@h, :c@h]} =
               SceneNodeRegistry.snapshot(name)
    end

    test "re-registering an existing node preserves position", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)

      assert %{join_order: [:a@h, :b@h]} = SceneNodeRegistry.snapshot(name)
    end

    test "unregister removes from join_order", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      :ok = SceneNodeRegistry.unregister_scene_node(name, :a@h)

      assert %{join_order: [:b@h]} = SceneNodeRegistry.snapshot(name)
    end

    test "unregister of unknown node is a no-op", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.unregister_scene_node(name, :never@h)

      assert %{join_order: [:a@h]} = SceneNodeRegistry.snapshot(name)
    end
  end

  describe "assign_region (D8.B round-robin)" do
    test "no scene_nodes → :no_scene_nodes error", %{name: name} do
      assert {:error, :no_scene_nodes} = SceneNodeRegistry.assign_region(name, 1)
    end

    test "single scene_node → all regions land on it", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)

      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 2)
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 3)
    end

    test "multiple scene_nodes → round-robin in join_order", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :c@h)

      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 100)
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 101)
      assert {:ok, :c@h} = SceneNodeRegistry.assign_region(name, 102)
      # Wraps around.
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 103)
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 104)
    end

    test "re-assigning the same region returns the existing assignment", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)

      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)

      # Even though the round-robin cursor would normally advance to
      # `:"b@h"`, requesting region 1 again returns the original
      # assignment unchanged.
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)

      # And the next *new* region still picks `:"b@h"` (cursor wasn't
      # advanced by the duplicate calls above).
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 2)
    end

    test "newly joined scene_node does not steal existing assignments (D8.B core invariant)",
         %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)

      # Pre-existing assignments before any new scene_node joins.
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 2)

      # New scene_node joins.
      :ok = SceneNodeRegistry.register_scene_node(name, :c@h)

      # Existing region assignments remain unchanged.
      assert {:ok, :a@h} = SceneNodeRegistry.lookup_assignment(name, 1)
      assert {:ok, :b@h} = SceneNodeRegistry.lookup_assignment(name, 2)

      # Backlog regions land on `:"c@h"` next (cursor was at 2, len is now 3).
      assert {:ok, :c@h} = SceneNodeRegistry.assign_region(name, 3)
      # Then wraps to `:"a@h"`.
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 4)
    end
  end

  describe "lookup_assignment" do
    test "miss returns :error", %{name: name} do
      assert :error = SceneNodeRegistry.lookup_assignment(name, 999)
    end

    test "hit returns the assigned node", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)

      assert {:ok, :a@h} = SceneNodeRegistry.lookup_assignment(name, 1)
    end

    test "lookup is read-only (does not assign on miss)", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)

      assert :error = SceneNodeRegistry.lookup_assignment(name, 1)
      assert %{region_assignments: assignments} = SceneNodeRegistry.snapshot(name)
      refute Map.has_key?(assignments, 1)
    end
  end

  describe "unregister + existing regions (D8.B no-failover invariant)" do
    test "unregister keeps existing region assignments pointing at the down node", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 2)

      :ok = SceneNodeRegistry.unregister_scene_node(name, :a@h)

      # Region 1 still points at the (now-down) :"a@h" node — caller
      # must observe BeaconServer separately to discover liveness.
      # MVP per D8.B; Phase 6 HA adds reassignment.
      assert {:ok, :a@h} = SceneNodeRegistry.lookup_assignment(name, 1)
      assert {:ok, :b@h} = SceneNodeRegistry.lookup_assignment(name, 2)

      # Subsequent assigns go only to remaining nodes.
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 3)
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 4)
    end

    test "unregistering all nodes makes assign_region fail without losing existing regions",
         %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)

      :ok = SceneNodeRegistry.unregister_scene_node(name, :a@h)

      assert {:error, :no_scene_nodes} = SceneNodeRegistry.assign_region(name, 2)
      assert {:ok, :a@h} = SceneNodeRegistry.lookup_assignment(name, 1)
    end
  end

  # Phase 3 / S1: the announce/monitor timing-race sweep. SceneNodeMonitor calls
  # reconcile_live_nodes/2 on (re)start to drop entries that disconnected before
  # `:net_kernel.monitor_nodes` was established (e.g. stale rows hydrated from
  # Postgres). Region assignments for swept nodes are intentionally preserved.
  describe "reconcile_live_nodes/2" do
    test "drops registered nodes not in the live set, keeps the live ones", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :c@h)

      assert {:ok, swept} = SceneNodeRegistry.reconcile_live_nodes(name, [:b@h])
      assert Enum.sort(swept) == [:a@h, :c@h]

      assert %{join_order: [:b@h]} = SceneNodeRegistry.snapshot(name)
    end

    test "is a no-op when every registered node is live", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)

      assert {:ok, []} = SceneNodeRegistry.reconcile_live_nodes(name, [:a@h, :b@h, :extra@h])
      assert %{join_order: [:a@h, :b@h]} = SceneNodeRegistry.snapshot(name)
    end

    test "preserves region assignments for swept (no auto-failover)", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)
      assert {:ok, :a@h} = SceneNodeRegistry.assign_region(name, 1)
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 2)

      assert {:ok, [:a@h]} = SceneNodeRegistry.reconcile_live_nodes(name, [:b@h])

      # a@h's frozen assignment survives even though it left the rotation.
      assert {:ok, :a@h} = SceneNodeRegistry.lookup_assignment(name, 1)
      assert {:ok, :b@h} = SceneNodeRegistry.lookup_assignment(name, 2)
      # New regions only route to live nodes now.
      assert {:ok, :b@h} = SceneNodeRegistry.assign_region(name, 3)
    end

    test "empty live set sweeps everything", %{name: name} do
      :ok = SceneNodeRegistry.register_scene_node(name, :a@h)
      :ok = SceneNodeRegistry.register_scene_node(name, :b@h)

      assert {:ok, swept} = SceneNodeRegistry.reconcile_live_nodes(name, [])
      assert Enum.sort(swept) == [:a@h, :b@h]
      assert %{join_order: []} = SceneNodeRegistry.snapshot(name)
    end
  end
end
