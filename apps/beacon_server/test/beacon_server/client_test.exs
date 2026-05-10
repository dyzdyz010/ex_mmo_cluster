defmodule BeaconServer.ClientTest do
  use ExUnit.Case, async: false

  describe "join_cluster/0" do
    test "returns :error when no cluster peers (non-distributed node)" do
      assert BeaconServer.Client.join_cluster() == :error
    end
  end

  describe "register/1" do
    test "registers a service in the distributed registry" do
      assert :ok = BeaconServer.Client.register(:test_service_a)
    end

    test "re-registering the same service is idempotent" do
      :ok = BeaconServer.Client.register(:idempotent_svc)
      assert :ok = BeaconServer.Client.register(:idempotent_svc)
    end
  end

  describe "lookup/1" do
    test "finds a registered service" do
      :ok = BeaconServer.Client.register(:findable_service)

      assert {:ok, node} =
               BeaconServer.Client.await(:findable_service, timeout: 1_000, interval: 10)

      assert node == node()
    end

    test "returns :error for unregistered service" do
      assert :error = BeaconServer.Client.lookup(:nonexistent_service)
    end
  end

  describe "await/2" do
    test "returns immediately if service already registered" do
      :ok = BeaconServer.Client.register(:already_here)
      assert {:ok, node} = BeaconServer.Client.await(:already_here, timeout: 1_000)
      assert node == node()
    end

    test "returns :timeout if service never appears" do
      assert :timeout = BeaconServer.Client.await(:never_coming, timeout: 100, interval: 50)
    end

    test "finds service registered by another process" do
      test_pid = self()

      # Spawn a long-lived process that registers and stays alive
      pid =
        spawn(fn ->
          :ok = BeaconServer.Client.register(:delayed_service)
          send(test_pid, :registered)
          # Stay alive until test completes
          receive do
            :done -> :ok
          end
        end)

      assert {:ok, _node} =
               BeaconServer.Client.await(:delayed_service, timeout: 5_000, interval: 25)

      send(pid, :done)
    end
  end

  describe "full workflow" do
    test "register then lookup multiple services" do
      :ok = BeaconServer.Client.register(:svc_alpha)
      :ok = BeaconServer.Client.register(:svc_beta)

      assert {:ok, _} = BeaconServer.Client.await(:svc_alpha, timeout: 1_000, interval: 10)
      assert {:ok, _} = BeaconServer.Client.await(:svc_beta, timeout: 1_000, interval: 10)
      assert :error = BeaconServer.Client.lookup(:svc_gamma)
    end
  end

  # A4-bis-1: term key paths (tuples for parameterized resources, e.g.
  # {:voxel_region_scene_node, region_id}). Atom path remains the common
  # case for module-level singletons; both must work.
  describe "term key (tuple) resources" do
    test "register / lookup / await round-trip with tuple key" do
      key = {:voxel_region_scene_node, 42}
      assert :ok = BeaconServer.Client.register(key)
      assert {:ok, node} = BeaconServer.Client.lookup(key)
      assert node == node()
      assert {:ok, ^node} = BeaconServer.Client.await(key, timeout: 1_000, interval: 10)
    end

    test "tuple key is namespaced from atom of the same shape" do
      atom_key = :region_alpha
      tuple_key = {:region_alpha, 1}

      :ok = BeaconServer.Client.register(atom_key)
      :ok = BeaconServer.Client.register(tuple_key)

      assert {:ok, _} = BeaconServer.Client.lookup(atom_key)
      assert {:ok, _} = BeaconServer.Client.lookup(tuple_key)
    end

    test "lookup returns :error for an unregistered tuple key" do
      assert :error = BeaconServer.Client.lookup({:voxel_region_scene_node, 999})
    end

    test "re-registering the same tuple key is idempotent" do
      key = {:voxel_region_chunk_directory, 7}
      :ok = BeaconServer.Client.register(key)
      assert :ok = BeaconServer.Client.register(key)
    end

    test "await :timeout for a never-registered tuple key" do
      assert :timeout =
               BeaconServer.Client.await({:never, :coming, 0}, timeout: 100, interval: 50)
    end
  end
end
