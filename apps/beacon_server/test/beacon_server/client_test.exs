defmodule BeaconServer.ClientTest do
  use ExUnit.Case, async: false

  setup_all do
    # Horde registry started in test_helper.exs
    {:ok, _} = BeaconServer.Beacon.start_link(name: BeaconServer.Beacon)
    :ok
  end

  describe "join_cluster/0" do
    test "returns :error when no cluster peers (non-distributed node)" do
      # In test environment without distributed Erlang, no peers exist
      assert BeaconServer.Client.join_cluster() == :error
    end
  end

  describe "register/4" do
    test "registers a resource with the beacon" do
      assert :ok == BeaconServer.Client.register(node(), __MODULE__, :test_service, [])
    end

    test "registers a resource with requirements" do
      assert :ok == BeaconServer.Client.register(node(), __MODULE__, :dependent_service, [:test_service])
    end
  end

  describe "get_requirements/1" do
    test "returns {:ok, []} for node with no requirements" do
      test_node = :"no_req_node@test"
      BeaconServer.Client.register(test_node, __MODULE__, :no_req_service, [])
      assert {:ok, []} = BeaconServer.Client.get_requirements(test_node)
    end

    test "returns {:ok, resources} when requirements are met" do
      # Register a provider
      BeaconServer.Client.register(:"provider@test", SomeModule, :needed_service, [])
      # Register a consumer that needs :needed_service
      BeaconServer.Client.register(:"consumer@test", OtherModule, :consumer, [:needed_service])

      assert {:ok, resources} = BeaconServer.Client.get_requirements(:"consumer@test")
      assert length(resources) > 0
      assert Enum.any?(resources, fn r -> r.name == :needed_service end)
    end
  end
end
