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
      assert {:ok, node} = BeaconServer.Client.lookup(:findable_service)
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
      pid = spawn(fn ->
        :ok = BeaconServer.Client.register(:delayed_service)
        send(test_pid, :registered)
        # Stay alive until test completes
        receive do
          :done -> :ok
        end
      end)

      assert {:ok, _node} = BeaconServer.Client.await(:delayed_service, timeout: 5_000, interval: 25)
      send(pid, :done)
    end
  end

  describe "full workflow" do
    test "register then lookup multiple services" do
      :ok = BeaconServer.Client.register(:svc_alpha)
      :ok = BeaconServer.Client.register(:svc_beta)

      assert {:ok, _} = BeaconServer.Client.lookup(:svc_alpha)
      assert {:ok, _} = BeaconServer.Client.lookup(:svc_beta)
      assert :error = BeaconServer.Client.lookup(:svc_gamma)
    end
  end
end
